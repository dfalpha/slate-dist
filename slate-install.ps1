<#
.SYNOPSIS
    Slate server installer for Windows 11 - the one-liner bootstrap.

        irm https://get.slatepanel.app/windows | iex

    in an ELEVATED PowerShell 7 (pwsh). With options:

        & ([scriptblock]::Create((irm https://get.slatepanel.app/windows))) -DryRun

.DESCRIPTION
    Slate's supported Windows shape is "WSL2 distro in mirrored networking
    mode + native Docker inside it" - NOT Docker Desktop, whose engine lives
    in its own VM behind NAT and hears nothing on the LAN (measured: 1 mDNS
    responder against 34 from a native container in a mirrored distro). Five
    subsystems need real LAN presence - Cast, Hue, Lutron and Ecobee HAP
    discovery are mDNS, and the Matter lock additionally needs IPv6 link-local.

    This script ORCHESTRATES; the work is done by three files it downloads
    from the public dist mirror (github.com/dfalpha/slate-dist), which is what
    production itself was built with on 2026-09-09 (infra/install/README.md):

      1. slate-windows-setup.ps1   IPv6 on the LAN adapter, .wslconfig
                                   (mirrored, instanceIdleTimeout=-1), the
                                   Hyper-V firewall rules, the port-collision
                                   check, creates the distro, verifies it.
      2. slate-install.sh          INSIDE the distro, as root: Docker Engine,
                                   the public images, .env from prompts, the
                                   stack on host networking, and a VERIFIED
                                   host-network check.
      3. slate-keepalive-task.ps1  The scheduled task (S4U, this user, never
                                   SYSTEM) that starts the distro at boot with
                                   nobody logged on, driving wsl-keepalive.ps1.

    Idempotent: every step detects what is already done. -DryRun prints
    every action and changes nothing; preflight failures are then reported as
    WOULD ABORT and the run continues, so the whole flow can be exercised on
    any machine (CI runs it under pwsh on Linux).

.PARAMETER DryRun
    Print every action; change nothing. Also honoured as $env:SLATE_DRY_RUN=1.

.PARAMETER Distro
    Name of the WSL distro. 'Slate' is the convention.

.PARAMETER DistBase
    Base URL of the public dist mirror the four files are fetched from.

.PARAMETER InstallRoot
    Where the downloaded scripts live on Windows. NOT a user profile: the
    keepalive task must read wsl-keepalive.ps1 at boot with nobody logged on.

.NOTES
    Needs PowerShell 7 (New-NetFirewallHyperVRule does not exist in 5.1) and
    elevation. Both are checked first and explained, not assumed.

    SLATE_GHCR_USER / SLATE_GHCR_TOKEN, if set in this session, are passed into
    the distro (WSLENV) for the Linux installer's fallback when the images or
    the mirror are still private. Nothing here needs them otherwise.

    SLATE_ADMIN_PASSWORD travels the same way. SlateSetup.exe collects it on a
    wizard page and puts it in this process's environment; with it set, the
    Linux installer asks nothing at all. Run from the bare one-liner instead,
    it is simply unset and the Linux installer asks for it on the console. It
    is never printed here and never appears on a command line - a command line
    is readable by every user on the machine, an environment block is not.
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [string]$Distro      = 'Slate',
    [string]$DistBase    = 'https://raw.githubusercontent.com/dfalpha/slate-dist/main',
    [string]$InstallRoot = ''
)

$ErrorActionPreference = 'Stop'

if ($env:SLATE_DRY_RUN -eq '1' -or $env:SLATE_DRY_RUN -eq 'true') { $DryRun = $true }
if (-not $InstallRoot) {
    $InstallRoot = if ($env:ProgramData) { Join-Path $env:ProgramData 'Slate' } else { '/tmp/slate-install-dry-run' }
}
$InstallDir   = Join-Path $InstallRoot 'install'
$PortalLink   = 'https://portal.slatepanel.app/account/link'
# Everything this run needs, refreshed from the mirror every time. The last
# two are only USED by SlateSetup.exe, which registers the version-sync task -
# but they are downloaded here so that changing them never means rebuilding
# the installer. Run from the bare one-liner they are simply present and
# unused, and the sync script no-ops when it finds no uninstall entry.
$Files        = @('slate-windows-setup.ps1', 'slate-keepalive-task.ps1', 'wsl-keepalive.ps1', 'slate-install.sh',
                  'slate-version-sync.ps1', 'slate-version-task.ps1')
$script:PreflightProblems = 0

# ------------------------------------------------------------------ output --
function Step { param($m) Write-Host ""; Write-Host "== $m" }
function Say  { param($m) Write-Host "  $m" }
function Warn { param($m) Write-Host "WARNING: $m" -ForegroundColor Yellow }
function Die  { param($m) Write-Host ""; Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }

# Exit 3 means "not finished, and not broken either": come back after a
# restart. SlateSetup.exe reads that code specifically and says so on its last
# page instead of reporting a failure, because telling somebody their install
# failed when all it needs is a reboot sends them debugging nothing.
function DieReboot { param($m) Write-Host ""; Write-Host "RESTART NEEDED: $m" -ForegroundColor Yellow; exit 3 }

# A preflight failure: fatal for real, reported and skipped under -DryRun.
function FatalOrNote {
    param($m)
    if ($DryRun) {
        Write-Host "WOULD ABORT: $m" -ForegroundColor Yellow
        $script:PreflightProblems++
    } else {
        Die $m
    }
}

# A state-changing native command: printed under -DryRun, run otherwise.
# Returns $true when the command ran and exited 0.
function Invoke-Action {
    param([string]$What, [scriptblock]$Do)
    if ($DryRun) { Say "[dry-run] $What"; return $true }
    Say $What
    & $Do
    return ($LASTEXITCODE -eq 0 -or $null -eq $LASTEXITCODE)
}

function Test-Elevated {
    if (-not $IsWindows) { return $false }
    try {
        return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(544)
    } catch { return $false }
}

# ---------------------------------------------------------------- preflight --
function Invoke-Preflight {
    Step "Preflight"

    if ($PSVersionTable.PSVersion.Major -lt 7) {
        FatalOrNote "This needs PowerShell 7, and this is Windows PowerShell $($PSVersionTable.PSVersion). Install it with: winget install --id Microsoft.PowerShell -e   - then open 'PowerShell 7' as Administrator and run the line again."
    } else {
        Say "PowerShell $($PSVersionTable.PSVersion)"
    }

    if (-not $IsWindows) {
        FatalOrNote "This is the Windows installer. On Linux: curl -fsSL https://get.slatepanel.app/linux | sudo sh. On macOS (beta): curl -fsSL https://get.slatepanel.app/mac | sh."
    } else {
        $build = [Environment]::OSVersion.Version.Build
        Say "Windows build $build"
        # Mirrored networking arrived with WSL 2.0.4 on Windows 11 22H2 (build
        # 22621). Nothing older can do what this stack needs.
        if ($build -lt 22621) {
            FatalOrNote "Windows 11 22H2 (build 22621) or newer is required: WSL's mirrored networking mode does not exist before it, and without it the distro is behind NAT with no mDNS and no IPv6 link-local."
        }
    }

    if (Test-Elevated) {
        Say "Running elevated."
    } else {
        FatalOrNote "Run this elevated: right-click 'PowerShell 7' > Run as administrator, then run the line again. Registering the boot task, writing the Hyper-V firewall rules and creating the distro all need it."
    }

    if ($IsWindows -and (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        $ver = (& wsl.exe --version 2>$null) -replace "`0", '' | Where-Object { $_ -match 'WSL version:\s*([\d.]+)' } | ForEach-Object { $Matches[1] } | Select-Object -First 1
        if ($ver) {
            Say "WSL $ver"
            if ([version]$ver -lt [version]'2.0.4') {
                Warn "WSL $ver is older than 2.0.4 (the first with mirrored networking). Updating it."
                [void](Invoke-Action "wsl --update" { & wsl.exe --update })
            }
        } else {
            Warn "wsl.exe is present but 'wsl --version' did not answer. This is usually the in-box WSL rather than the Store one; 'wsl --update' fixes that."
            [void](Invoke-Action "wsl --update" { & wsl.exe --update })
        }
    } elseif ($IsWindows) {
        Say "WSL is not installed; installing it (no distro yet - the setup script creates ours)."
        [void](Invoke-Action "wsl --install --no-distribution" { & wsl.exe --install --no-distribution })
        if (-not $DryRun) {
            DieReboot "WSL was just installed and Windows has to restart before there is anything to install into. Restart, then run the same line again (or the installer again) - it picks up from here."
        }
    } else {
        FatalOrNote "wsl.exe is not available (not Windows)."
    }

    if ($IsWindows -and (Get-Service 'com.docker.service' -ErrorAction SilentlyContinue)) {
        Warn "Docker Desktop is installed. It is not used and must NOT be integrated with the '$Distro' distro (Settings > Resources > WSL integration): a Desktop-backed container has no LAN and every integration fails silently. The setup script repeats this; the Linux installer refuses a Desktop engine outright."
    }
}

# ---------------------------------------------------------------- download --
function Get-DistFiles {
    Step "Fetching the installer files into $InstallDir"

    if ($DryRun) {
        foreach ($f in $Files) { Say "[dry-run] download $DistBase/$f -> $(Join-Path $InstallDir $f)" }
        return
    }
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    foreach ($f in $Files) {
        $dest = Join-Path $InstallDir $f
        $tmp  = "$dest.part"
        try {
            Invoke-WebRequest -UseBasicParsing -Uri "$DistBase/$f" -OutFile $tmp
            Move-Item -Force $tmp $dest
            Say "$f"
        } catch {
            Remove-Item -Force -ErrorAction SilentlyContinue $tmp
            if (Test-Path $dest) {
                Warn "Could not download $f from the public mirror ($DistBase) - it is not public yet, or this machine cannot reach raw.githubusercontent.com. Reusing the copy already at $dest."
            } else {
                Die "Could not download $f from the public mirror ($DistBase): the dist repository is not public yet, or this machine cannot reach raw.githubusercontent.com. Until it is public, copy the four files ($($Files -join ', ')) from the Slate repository's infra/install/ (and infra/wsl-keepalive.ps1) into $InstallDir by hand and run this line again - it reuses what is there."
            }
        }
    }
    # A CRLF slate-install.sh would die inside the distro with '\r: not found'.
    $sh = [IO.File]::ReadAllText((Join-Path $InstallDir 'slate-install.sh'))
    if (-not $sh.StartsWith('#!/bin/sh')) { Die "The downloaded slate-install.sh does not start with #!/bin/sh. Check $DistBase." }
    if ($sh.Contains("`r")) {
        [IO.File]::WriteAllText((Join-Path $InstallDir 'slate-install.sh'), $sh.Replace("`r", ''))
        Say "slate-install.sh: normalised line endings to LF."
    }
}

# --------------------------------------------------------- windows setup ---
# Half the host's RAM for WSL, between 4 and 16 GB. With no .wslconfig at all
# WSL takes half by default; the cap keeps a 64 GB box from handing 32 GB to a
# stack that wants 4.
function Get-WslMemoryGb {
    try {
        $total = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory / 1GB
        return [Math]::Max(4, [Math]::Min(16, [Math]::Floor($total / 2)))
    } catch { return 8 }
}

function Invoke-WindowsSetup {
    Step "Windows side (slate-windows-setup.ps1)"
    $mem  = Get-WslMemoryGb
    $swap = [Math]::Max(2, [Math]::Floor($mem / 2))
    $setup = Join-Path $InstallDir 'slate-windows-setup.ps1'
    Say "WSL memory ${mem}GB, swap ${swap}GB, distro '$Distro'"
    # A child pwsh, so the setup script's own `exit 1` ends IT, not this
    # session, and its exit code is a value rather than a surprise.
    $ok = Invoke-Action "pwsh -NoProfile -ExecutionPolicy Bypass -File $setup -Distro $Distro -MemoryGb $mem -SwapGb $swap" {
        & pwsh -NoProfile -ExecutionPolicy Bypass -File $setup -Distro $Distro -MemoryGb $mem -SwapGb $swap
    }
    if (-not $ok) { Die "slate-windows-setup.ps1 failed (exit $LASTEXITCODE). Its own message above says why; fix that and run this line again." }
}

# ------------------------------------------------------ the linux installer --
function Invoke-LinuxInstaller {
    Step "Inside the distro: slate-install.sh (Docker, images, .env, the stack, verification)"
    $shPath = Join-Path $InstallDir 'slate-install.sh'
    # wslpath inside the distro turns C:\ProgramData\... into /mnt/c/ProgramData/...
    # without this script guessing the mount root. Same pattern the setup
    # script uses for /etc/wsl.conf, proven on the production host.
    $lin = 'sh "$(wslpath -u ' + "'$shPath'" + ')"'
    # Forwarded into the distro. WSLENV names variables to copy out of THIS
    # process's environment, so an unset one simply arrives empty: the GHCR
    # pair is for the private-images fallback, and SLATE_ADMIN_PASSWORD is
    # what SlateSetup.exe's wizard page collected. Empty means "not set" on
    # the Linux side, which then asks for it on the console.
    $env:WSLENV = 'SLATE_GHCR_USER:SLATE_GHCR_TOKEN:SLATE_DIST_RAW:SLATE_ADMIN_PASSWORD'
    $ok = Invoke-Action "wsl -d $Distro -u root -e sh -c `"$lin`"" {
        & wsl.exe -d $Distro -u root -e sh -c $lin
    }
    if (-not $ok) { Die "The Linux installer failed inside '$Distro' (exit $LASTEXITCODE). Its own message above says why. Re-run this line once it is fixed - everything already done is reused." }
}

# ---------------------------------------------------------------- keepalive --
function Register-Keepalive {
    Step "Boot task (slate-keepalive-task.ps1)"
    $script  = Join-Path $InstallRoot 'wsl-keepalive.ps1'
    $taskReg = Join-Path $InstallDir 'slate-keepalive-task.ps1'
    if ($DryRun) {
        Say "[dry-run] copy $(Join-Path $InstallDir 'wsl-keepalive.ps1') -> $script"
    } else {
        Copy-Item -Force (Join-Path $InstallDir 'wsl-keepalive.ps1') $script
    }
    $ok = Invoke-Action "pwsh -NoProfile -ExecutionPolicy Bypass -File $taskReg -Distro $Distro -ScriptPath $script" {
        & pwsh -NoProfile -ExecutionPolicy Bypass -File $taskReg -Distro $Distro -ScriptPath $script
    }
    if (-not $ok) { Die "Registering the keepalive task failed (exit $LASTEXITCODE). Without it the distro - and the whole stack - stops with the next reboot. See the message above." }
}

# ------------------------------------------------------------------- finish --
function Get-LanIp {
    if (-not $IsWindows) { return '' }
    try {
        return (Get-NetIPConfiguration -ErrorAction Stop | Where-Object { $_.IPv4DefaultGateway } | Select-Object -First 1).IPv4Address.IPAddress
    } catch { return '' }
}

function Show-Finish {
    $ip = Get-LanIp
    Write-Host ""
    if ($DryRun) {
        Write-Host "A real run would end here, with Slate installed in the '$Distro' distro."
    } else {
        Write-Host "Slate is installed, in the '$Distro' WSL distro on this PC."
    }
    Write-Host ""
    Write-Host "Admin panel:"
    if ($ip) { Write-Host "  http://${ip}:8080/admin" } else { Write-Host "  http://<this-pc-lan-ip>:8080/admin" }
    Write-Host ""
    Write-Host "Log in as 'admin' with the password you set during this install,"
    Write-Host "then change it from the Users tab whenever you like. The stack lives at"
    Write-Host "/opt/slate inside the distro ('wsl -d $Distro' opens a shell there);"
    Write-Host "re-running this line is safe - it keeps every value already in .env."
    Write-Host ""
    # The device-link code is minted by the server when an admin starts a link
    # and is read back only through the authenticated admin API; there is no
    # unauthenticated read and this installer adds no endpoint. So: where it
    # appears, and where it goes.
    Write-Host "Connect this server to your Slate account:"
    Write-Host "  open the Licence tab, click Link to my Slate account, and type the"
    Write-Host "  code at $PortalLink"
    Write-Host ""
    Write-Host "Keep this PC on. Windows Update reboots and sleep both take the house's"
    Write-Host "dashboards down; the boot task brings the stack back, sleep does not."
    if ($DryRun) {
        Write-Host ""
        Write-Host "This was a dry run - nothing was changed."
        if ($script:PreflightProblems -gt 0) {
            Write-Host "$($script:PreflightProblems) preflight check(s) would have aborted a real run."
        }
    }
}

# --------------------------------------------------------------------- main --
Write-Host "Slate server installer for Windows"
if ($DryRun) { Write-Host "(dry run - nothing will be changed)" }

Invoke-Preflight
Get-DistFiles
Invoke-WindowsSetup
Invoke-LinuxInstaller
Register-Keepalive
Show-Finish
