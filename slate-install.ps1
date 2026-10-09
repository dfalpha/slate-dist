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
                                   the images (signed in), .env with no prompts, the
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
    Print the registry sign-in link and the first-setup link, but open neither.

.PARAMETER Progress
    Print `##slate step <id> <start|end>` and `##slate code <code> <url>` lines
    for SlateSetup.exe, which reads this script's output and draws a step list
    from them (no console window). Off for the one-liner, so a person never sees
    them. Forwarded into the distro as SLATE_PROGRESS_MARKERS=1.

.NOTES
    Needs PowerShell 7 (New-NetFirewallHyperVRule does not exist in 5.1) and
    elevation. Both are checked first and explained, not assumed.

    It types nothing into this window. Owner, 2026-09-15 (D12): "Browser opens;
    the setup wizard creates the admin. Installers ask nothing." The server
    mints a single-use first-setup token on its first start with no
    administrator; the last thing this script does is ask it for the link and
    open it (Show-FirstSetup).

    The one interaction (owner, 2026-09-24) is approving this PC in the browser
    so it may download Slate from registry.slatepanel.app: Invoke-RegistrySignIn
    shows a code, opens the approval page, and waits. SLATE_REGISTRY_USER /
    SLATE_REGISTRY_TOKEN, if already set in this session, skip that step.
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [string]$Distro      = 'Slate',
    [string]$DistBase    = 'https://raw.githubusercontent.com/dfalpha/slate-dist/main',
    [string]$InstallRoot = '',
    [string]$SetupUrlFile = '',
    [switch]$NoBrowser,
    [switch]$Progress
)

$ErrorActionPreference = 'Stop'

# wsl.exe writes its own messages as UTF-16 unless asked otherwise; read through
# a pipe (SlateSetup.exe's step list, any capture) they arrive as "T h e r e".
$env:WSL_UTF8 = '1'
if ($Progress) { $env:SLATE_PROGRESS_MARKERS = '1' }

# A milestone for SlateSetup.exe's step list. See .PARAMETER Progress.
function Mark { param([string]$Id, [string]$State) if ($Progress) { Write-Host "##slate step $Id $State" } }

if ($env:SLATE_DRY_RUN -eq '1' -or $env:SLATE_DRY_RUN -eq 'true') { $DryRun = $true }
if (-not $InstallRoot) {
    $InstallRoot = if ($env:ProgramData) { Join-Path $env:ProgramData 'Slate' } else { '/tmp/slate-install-dry-run' }
}
$InstallDir   = Join-Path $InstallRoot 'install'
$PortalBase   = 'https://portal.slatepanel.app'
$PortalLink   = 'https://portal.slatepanel.app/account/link'
$Registry     = 'registry.slatepanel.app'
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

# Exit 4: this PC cannot run WSL2 yet, and nothing software can do will change
# that - CPU virtualization is off in the firmware, or (on a virtual machine) the
# host does not pass it through. SlateSetup.exe says so in plain words; the
# exact steps are printed here, so they are in the log too.
function DieNoVirtualization { param($m) Write-Host ""; Write-Host "VIRTUALIZATION NEEDED: $m" -ForegroundColor Yellow; exit 4 }

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
#
# THE OUTPUT GOES TO THE HOST, NOT DOWN THE PIPELINE. In PowerShell everything a
# function emits is part of its return value, so a bare `& $Do` made every
# caller's `$ok` an ARRAY of the command's output lines plus the boolean - and a
# non-empty array is truthy. Found 2026-10-01 on a clean VM: the distro was
# never created, wsl.exe printed WSL_E_DISTRO_NOT_FOUND, and every step still
# "succeeded" with its output swallowed (absent from the console and from
# Setup's transcript, which records host output). Out-Host fixes both, and
# leaves $LASTEXITCODE as the native command set it.
function Invoke-Action {
    param([string]$What, [scriptblock]$Do)
    if ($DryRun) { Say "[dry-run] $What"; return $true }
    Say $What
    $global:LASTEXITCODE = $null
    & $Do | Out-Host
    return [bool]($LASTEXITCODE -eq 0 -or $null -eq $LASTEXITCODE)
}

function Test-Elevated {
    if (-not $IsWindows) { return $false }
    try {
        return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(544)
    } catch { return $false }
}

# ---------------------------------------------------------------- preflight --
# ----------------------------------------------------------- virtualization --
# Owner, 2026-10-01: "you will need to enable virtualization in the installer if
# it's not enabled as part of it. this will be a common problem." Found on a
# clean Windows 11 VM: wsl.exe was present (the in-box stub), so nothing above
# turned on the Virtual Machine Platform feature, and WSL2 could not start
# (HCS_E_HYPERV_NOT_INSTALLED).
#
# What software CAN fix, and this does: the Virtual Machine Platform feature,
# and a boot setting that keeps the hypervisor off (hypervisorlaunchtype Off,
# often left by VirtualBox, VMware or anti-cheat tweaks). Both need a restart.
# What it CANNOT: CPU virtualization off in the BIOS/UEFI, or a virtual machine
# whose host does not pass virtualization through. Those are detected BEFORE
# anything is changed, so nobody restarts only to fail again.
#
# The parsers and the decision are separate, pure functions, so they can be
# exercised against canned output on any machine.

# `dism /English /Online /Get-FeatureInfo` output -> Enabled | Enable Pending |
# Disabled | Disable Pending | Unknown
function ConvertFrom-DismFeatureState {
    param([string[]]$Lines)
    foreach ($line in $Lines) {
        if ($line -match '^\s*State\s*:\s*(.+?)\s*$') { return $Matches[1] }
    }
    return 'Unknown'
}

# `bcdedit /enum {current}` output -> the hypervisorlaunchtype value, or
# 'Default' when the line is absent (which means Auto).
function ConvertFrom-BcdLaunchType {
    param([string[]]$Lines)
    foreach ($line in $Lines) {
        if ($line -match '^\s*hypervisorlaunchtype\s+(\S+)') { return $Matches[1] }
    }
    return 'Default'
}

# The decision, from four observations. FirmwareEnabled is only meaningful while
# no hypervisor runs (Windows reports False once one does), and may be $null on
# firmware that does not say - treated as "don't know", never as "off".
#   ok              WSL2 can run now
#   no-hardware     CPU virtualization unavailable: firmware, or a VM's host
#   enable-vmp      turn the feature on, then restart
#   pending         already turned on, waiting for a restart
#   fix-launchtype  the boot setting keeps the hypervisor off
#   restart         everything is on; the hypervisor starts at the next boot
function Get-VirtualizationAction {
    param([string]$VmpState, [bool]$HypervisorPresent, $FirmwareEnabled, [string]$LaunchType)
    # 'Unknown' (dism could not answer) with a hypervisor running is treated as
    # fine: WSL2 works on such a machine, and a real problem now surfaces when
    # the distro is created.
    if ($HypervisorPresent -and $VmpState -in @('Enabled', 'Unknown')) { return 'ok' }
    if (-not $HypervisorPresent -and $FirmwareEnabled -eq $false) { return 'no-hardware' }
    if ($VmpState -eq 'Enable Pending') { return 'pending' }
    if ($VmpState -ne 'Enabled') { return 'enable-vmp' }
    if ($LaunchType -eq 'Off') { return 'fix-launchtype' }
    return 'restart'
}

function Test-IsVirtualMachine {
    param($ComputerSystem)
    $id = "$($ComputerSystem.Manufacturer) $($ComputerSystem.Model)"
    return [bool]($id -match 'Virtual Machine|VMware|VirtualBox|KVM|QEMU|Parallels|Xen|HVM domU|Bochs')
}

function Get-NoVirtualizationAdvice {
    param([bool]$IsVm)
    if ($IsVm) {
        return "This is a virtual machine, and its host does not pass CPU virtualization through to it, so WSL2 cannot run inside it. " +
            "Shut this VM down and turn on nested virtualization for it on the host:`n" +
            "  Hyper-V (elevated PowerShell on the host):  Set-VMProcessor -VMName '<this VM>' -ExposeVirtualizationExtensions `$true`n" +
            "  VMware:      VM settings > Processors > 'Virtualize Intel VT-x/EPT or AMD-V/RVI'`n" +
            "  VirtualBox:  VBoxManage modifyvm '<this VM>' --nested-hw-virt on`n" +
            "  Parallels:   Configure > Hardware > CPU > 'Enable nested virtualization'`n" +
            "Then start the VM and run this installer again."
    }
    return "CPU virtualization is turned off in this PC's firmware, and WSL2 needs it. " +
        "Restart into the BIOS/UEFI settings (usually F2, F10, F12 or Del at power-on) and turn on " +
        "'Intel Virtualization Technology' (VT-x) or 'SVM Mode' (AMD-V) - often under Advanced or CPU Configuration. " +
        "Save, restart, and run this installer again."
}

function Assert-Virtualization {
    $vmpLines = & dism.exe /English /Online /Get-FeatureInfo /FeatureName:VirtualMachinePlatform 2>&1
    $vmp = ConvertFrom-DismFeatureState -Lines $vmpLines
    $cs  = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    $hv  = [bool]$cs.HypervisorPresent
    $fw  = (Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1).VirtualizationFirmwareEnabled
    $lt  = ConvertFrom-BcdLaunchType -Lines (& bcdedit.exe /enum '{current}' 2>&1)
    $isVm = Test-IsVirtualMachine -ComputerSystem $cs
    Say "Virtualization: Virtual Machine Platform $vmp; hypervisor $(if ($hv) { 'running' } else { 'not running' }); firmware $(if ($null -eq $fw) { 'unknown' } elseif ($fw) { 'on' } else { 'off' }); boot launch type $lt$(if ($isVm) { '; this is a virtual machine' })"

    switch (Get-VirtualizationAction -VmpState $vmp -HypervisorPresent $hv -FirmwareEnabled $fw -LaunchType $lt) {
        'ok' { return }
        'no-hardware' {
            $advice = Get-NoVirtualizationAdvice -IsVm $isVm
            if ($DryRun) { Write-Host "WOULD ABORT (exit 4): $advice" -ForegroundColor Yellow; $script:PreflightProblems++; return }
            DieNoVirtualization $advice
        }
        'enable-vmp' {
            Say "Turning on the Virtual Machine Platform feature, which WSL2 needs."
            $ok = Invoke-Action "dism /Online /Enable-Feature /FeatureName:VirtualMachinePlatform /All /NoRestart" {
                & dism.exe /Online /Enable-Feature /FeatureName:VirtualMachinePlatform /All /NoRestart
            }
            # 3010 is dism's "done, restart required" - success here.
            if (-not $ok -and $LASTEXITCODE -ne 3010) { Die "Could not turn on Virtual Machine Platform (dism exit $LASTEXITCODE). The message above says why." }
            if (-not $DryRun) { DieReboot "The Virtual Machine Platform feature has been turned on, and Windows has to restart before WSL2 can use it. Restart - this installer carries on by itself afterwards." }
        }
        'pending' {
            if (-not $DryRun) { DieReboot "The Virtual Machine Platform feature is turned on but Windows has not restarted since. Restart - this installer carries on by itself afterwards." }
            Say "[dry-run] would ask for a restart: Virtual Machine Platform is waiting for one."
        }
        'fix-launchtype' {
            Say "This PC's boot settings keep the hypervisor off (hypervisorlaunchtype Off), so WSL2 cannot start. Setting it back to Auto."
            $ok = Invoke-Action "bcdedit /set hypervisorlaunchtype auto" { & bcdedit.exe /set hypervisorlaunchtype auto }
            if (-not $ok) { Die "Could not change the boot setting (bcdedit exit $LASTEXITCODE). The message above says why." }
            if (-not $DryRun) { DieReboot "The hypervisor has been switched back on in this PC's boot settings, and Windows has to restart for it to start. Restart - this installer carries on by itself afterwards." }
        }
        'restart' {
            if (-not $DryRun) { DieReboot "Virtualization is set up but the hypervisor is not running yet - Windows needs a restart. Restart - this installer carries on by itself afterwards." }
            Say "[dry-run] would ask for a restart: the hypervisor starts at the next boot."
        }
    }
}

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

    if ($IsWindows) { Mark virt start; Assert-Virtualization; Mark virt end }

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

# ------------------------------------------------------- registry sign-in --
# Owner, 2026-09-24: Slate's images are served from registry.slatepanel.app to
# Slate accounts with a licence. The customer approves this PC in the browser
# (RFC 8628 device code, the same flow the Licence tab uses); the credential
# that comes back goes into the distro through WSLENV and the Linux installer
# logs in with it. Done HERE, on Windows, because the browser is here - inside
# the distro there is none. The portal password never reaches this script.
#
# The code and link are printed (SlateSetup.exe shows this console), and the
# link opens through explorer.exe so the browser is not elevated. The code is
# not a secret on its own: it only works for somebody signed in to an account
# with a licence, within ten minutes.
function Test-RegistrySignedIn {
    if (-not $IsWindows) { return $false }
    try {
        # Output discarded, not returned: see Invoke-Action. wsl.exe prints its
        # own errors (WSL_E_DISTRO_NOT_FOUND) on stdout, and returning them made
        # this answer "signed in" for a distro that did not exist.
        $null = & wsl.exe -d $Distro -u root -e sh -c "grep -q '$Registry' /root/.docker/config.json" 2>$null
        return [bool]($LASTEXITCODE -eq 0)
    } catch { return $false }
}

function Invoke-RegistrySignIn {
    Step "Approve this PC with your Slate account ($Registry)"
    if ($env:SLATE_REGISTRY_USER -and $env:SLATE_REGISTRY_TOKEN) {
        Say "A registry credential was supplied; using it."
        return
    }
    if ($DryRun) {
        Say "[dry-run] would show a code and $PortalBase/account/authorize-install, open it in the browser,"
        Say "[dry-run] wait for approval, and hand the credential to the Linux installer."
        return
    }
    if (Test-RegistrySignedIn) {
        Say "This PC is already signed in to $Registry."
        return
    }
    try {
        $start = Invoke-RestMethod -Method Post -Uri "$PortalBase/registry/device/code" -ContentType 'application/json' -Body '{"os":"windows"}' -TimeoutSec 30
    } catch {
        Die "Could not reach $PortalBase to sign in ($($_.Exception.Message)). Check this PC can reach the internet, then run this line again."
    }
    Write-Host ""
    Write-Host "To download Slate, approve this PC with your Slate account:"
    Write-Host "  1. Open   $($start.verification_uri)"
    Write-Host "  2. Enter  $($start.user_code)"
    if ($Progress) { Write-Host "##slate code $($start.user_code) $($start.verification_uri_complete)" }
    Write-Host "Sign in with the account that holds your Slate licence. The code lasts ten"
    Write-Host "minutes; this installer carries on by itself once you approve."
    if (-not $NoBrowser) {
        try { Start-Process -FilePath explorer.exe -ArgumentList $start.verification_uri_complete } catch { }
    }

    $interval = [int]($start.interval ?? 5)
    $deadline = (Get-Date).AddSeconds([int]($start.expires_in ?? 600))
    $body = @{ device_code = $start.device_code } | ConvertTo-Json -Compress
    $start = $null
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $interval
        try {
            $res = Invoke-WebRequest -Method Post -Uri "$PortalBase/registry/device/token" -ContentType 'application/json' -Body $body -SkipHttpErrorCheck -TimeoutSec 30
            $answer = $res.Content | ConvertFrom-Json
        } catch { continue }
        if ($answer.username -and $answer.password) {
            # Into this process's environment only, forwarded to the distro by
            # WSLENV (Invoke-LinuxInstaller). Never printed, never on disk here.
            $env:SLATE_REGISTRY_USER = $answer.username
            $env:SLATE_REGISTRY_TOKEN = $answer.password
            $answer = $null
            $body = $null
            Say "Approved."
            return
        }
        switch ($answer.error) {
            'authorization_pending' { }
            'slow_down' { $interval += 5 }
            'access_denied' { Die "The sign-in was refused, or the Slate account has no active licence. Start a trial or buy a licence at $PortalBase, then run this line again." }
            'expired_token' { Die "The code expired before it was approved. Run this line again for a new one." }
            default { }
        }
    }
    Die "The code expired before it was approved. Run this line again for a new one."
}

# ---------------------------------------------------------------- time zone --
# This PC's IANA time zone ("Area/City"), or $null. The WSL distro's own zone
# is usually UTC whatever Windows says, so the Linux installer is handed this
# one as SLATE_TZ and writes it to .env as TZ (14.42, owner-approved
# 2026-09-26). Windows names zones its own way ("Eastern Standard Time"); the
# region argument picks the right city for the country, so Eastern + CA is
# America/Toronto rather than America/New_York. Needs .NET 6+, which the
# PowerShell 7 this script already requires provides. Asks nothing (D12).
function Get-HouseTimeZone {
    try {
        $region = [Globalization.RegionInfo]::CurrentRegion.TwoLetterISORegionName
        $iana = $null
        if ([TimeZoneInfo]::TryConvertWindowsIdToIanaId([TimeZoneInfo]::Local.Id, $region, [ref]$iana) -and
            $iana -match '^[A-Za-z][A-Za-z0-9_+-]*(/[A-Za-z0-9_+-]+){0,2}$') {
            return $iana
        }
    } catch { }
    return $null
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
    # process's environment, so an unset one simply arrives empty: the registry
    # pair is the credential Invoke-RegistrySignIn collected (empty when the
    # distro was already signed in). SLATE_FIRST_SETUP=none tells the Linux
    # installer to say nothing about the first-setup link - this script fetches
    # it at the end and opens it on Windows (Show-FirstSetup).
    $env:SLATE_FIRST_SETUP = 'none'
    $env:SLATE_INSTALLER_OS = 'windows'
    $env:WSLENV = 'SLATE_REGISTRY_USER:SLATE_REGISTRY_TOKEN:SLATE_INSTALLER_OS:SLATE_DIST_RAW:SLATE_FIRST_SETUP:SLATE_PROGRESS_MARKERS:WSL_UTF8'
    # The house's zone, read here because the distro cannot see it. Nothing is
    # forwarded when it is unknown; the Linux installer then detects its own.
    $houseTz = Get-HouseTimeZone
    if ($houseTz) {
        Say "Time zone: $houseTz (from this PC)"
        $env:SLATE_TZ = $houseTz
        $env:WSLENV = $env:WSLENV + ':SLATE_TZ'
    } else {
        Warn "Could not tell this PC's time zone; the Linux installer will use its own."
    }
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

Mark preflight start; Invoke-Preflight; Mark preflight end
Mark files start; Get-DistFiles; Mark files end
Mark windows start; Invoke-WindowsSetup; Mark windows end
Mark approve start; Invoke-RegistrySignIn; Mark approve end
# The Linux installer marks its own steps (docker, pull, start, verify).
Invoke-LinuxInstaller
Mark boot start; Register-Keepalive; Mark boot end
Show-Finish
# Explicit, because slate-run-step.ps1 reports $LASTEXITCODE and that otherwise
# holds whatever the last native command left - the first-setup lookup's -1 on
# 2026-10-01 - which reported a finished install as failed. Every real failure
# above exits on its own (Die, DieReboot).
exit 0
