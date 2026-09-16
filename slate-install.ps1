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
                                   the public images, .env with no prompts, the
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

.PARAMETER SetupUrlFile
    Write the server's single-use first-setup link to this file instead of
    printing it or opening a browser. SlateSetup.exe passes a file in its own
    temporary directory: its run is under a transcript in ProgramData, and the
    link must not land in a log.

.PARAMETER NoBrowser
    Print the first-setup link but do not open it.

.NOTES
    Needs PowerShell 7 (New-NetFirewallHyperVRule does not exist in 5.1) and
    elevation. Both are checked first and explained, not assumed.

    It asks nothing. Owner, 2026-09-15 (D12): "Browser opens; the setup wizard
    creates the admin. Installers ask nothing." The server mints a single-use
    first-setup token on its first start with no administrator; the last thing
    this script does is ask it for the link and open it (Show-FirstSetup).

    SLATE_GHCR_USER / SLATE_GHCR_TOKEN, if set in this session, are passed into
    the distro (WSLENV) for the Linux installer's fallback when the images or
    the mirror are still private. Nothing here needs them otherwise.
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [string]$Distro      = 'Slate',
    [string]$DistBase    = 'https://raw.githubusercontent.com/dfalpha/slate-dist/main',
    [string]$InstallRoot = '',
    [string]$SetupUrlFile = '',
    [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'

if ($env:SLATE_DRY_RUN -eq '1' -or $env:SLATE_DRY_RUN -eq 'true') { $DryRun = $true }
if (-not $InstallRoot) {
    $InstallRoot = if ($env:ProgramData) { Join-Path $env:ProgramData 'Slate' } else { '/tmp/slate-install-dry-run' }
}
$InstallDir   = Join-Path $InstallRoot 'install'
$PortalLink   = 'https://portal.slatepanel.app/account/link'
# Run inside the distro: prints (or with --new, rotates) the server's
# single-use first-setup link.
$SetupUrlCommand = 'docker exec slate-server node dist/cli/firstSetupUrl.js'
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
    # pair is for the private-images fallback. SLATE_FIRST_SETUP=none tells the
    # Linux installer to say nothing about the first-setup link - this script
    # fetches it at the end and opens it on Windows (Show-FirstSetup).
    $env:SLATE_FIRST_SETUP = 'none'
    $env:WSLENV = 'SLATE_GHCR_USER:SLATE_GHCR_TOKEN:SLATE_DIST_RAW:SLATE_FIRST_SETUP'
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

# Asks the server inside the distro for its first-setup link. State is 'url',
# 'admin-exists' (the command's exit 3: nothing to set up) or 'unavailable'
# (an older image without the command, or a server that is not up).
function Get-FirstSetupUrl {
    $result = @{ State = 'unavailable'; Url = '' }
    if (-not $IsWindows) { return $result }
    try {
        $out = & wsl.exe -d $Distro -u root -e docker exec slate-server node dist/cli/firstSetupUrl.js --host localhost 2>$null
        $code = $LASTEXITCODE
    } catch { return $result }
    $first = ([string]($out | Select-Object -First 1)).Trim()
    if ($code -eq 0 -and $first -match '^http://\S+/admin/setup\?t=[A-Za-z0-9_-]+$') {
        $result.State = 'url'
        $result.Url = $first
    } elseif ($code -eq 3) {
        $result.State = 'admin-exists'
    }
    return $result
}

# D12, 2026-09-15: "Browser opens; the setup wizard creates the admin.
# Installers ask nothing." Until somebody uses it, the link is a credential -
# whoever opens it first chooses the admin password - so it goes to exactly one
# place:
#   -SetupUrlFile   SlateSetup.exe: that file and nowhere else. This run is
#                   under a transcript in ProgramData, and a link in a log is a
#                   link anybody who can read the log can use.
#   (default)       the one-liner: printed, and opened in the browser.
#   -NoBrowser      printed only.
function Show-FirstSetup {
    $command = "wsl -d $Distro -u root $SetupUrlCommand"
    if ($DryRun) {
        Say "[dry-run] would ask the server for its single-use first-setup link ($command)"
        if ($SetupUrlFile) { Say "[dry-run] and write it to $SetupUrlFile for SlateSetup.exe to open" }
        elseif (-not $NoBrowser) { Say "[dry-run] and open it in the browser" }
        return
    }
    $setup = Get-FirstSetupUrl
    switch ($setup.State) {
        'url' {
            if ($SetupUrlFile) {
                try {
                    [IO.File]::WriteAllText($SetupUrlFile, $setup.Url)
                    Write-Host "Finish setting up in the browser: Setup opens Slate's setup page when it finishes."
                } catch {
                    Warn "Could not hand the setup link to Setup ($($_.Exception.Message)). Print it with: $command"
                }
            } else {
                Write-Host "Finish setting up in a browser: create the administrator, then link this"
                Write-Host "server to your Slate account. Open:"
                Write-Host "  $($setup.Url)"
                Write-Host "The link works once and expires after 24 hours. For a fresh one:"
                Write-Host "  $command --new"
                if (-not $NoBrowser) {
                    # Through explorer.exe, so the browser starts as the
                    # signed-in user instead of inheriting this elevated session.
                    try { Start-Process -FilePath explorer.exe -ArgumentList $setup.Url } catch { }
                }
            }
        }
        'admin-exists' {
            Write-Host "This server already has an administrator: sign in with that account."
        }
        default {
            Write-Host "Finish setting up in a browser. Print the single-use setup link with:"
            Write-Host "  $command"
        }
    }
    $setup = $null
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
    Show-FirstSetup
    Write-Host ""
    Write-Host "The stack lives at /opt/slate inside the distro ('wsl -d $Distro' opens a"
    Write-Host "shell there); re-running this line is safe - it keeps every value already in .env."
    Write-Host ""
    # The setup page's second step signs in to the Slate account. The
    # device-link code stays the way to do it later: minted by the server when
    # an admin starts a link, readable only through the authenticated admin API.
    Write-Host "Connect this server to your Slate account in the setup page's second step."
    Write-Host "To do it later instead, sign in to the admin panel and"
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
