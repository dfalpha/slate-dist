<#
.SYNOPSIS
    Registers the scheduled task that starts (and restarts) Slate's WSL distro.

.DESCRIPTION
    A WSL2 distro runs only while something holds it. `[boot] systemd=true` does
    NOT keep it alive. Two mechanisms are needed and they do different jobs:

      * `[general] instanceIdleTimeout=-1` in .wslconfig stops WSL
        idle-terminating the distro after the last wsl.exe client exits.
        slate-windows-setup.ps1 writes it.
      * THIS task starts the distro at boot, when no user may ever log on, and
        brings it back if it goes down.

    Without the first, every administrative command that touches the distro also
    restarts the whole stack when it exits - which reads exactly like an
    application crash loop (exit code 0, RestartCount 0, ~50s period). The tell
    is that every container restarts on the same timestamps, not just one.

.PARAMETER Distro
    Distro to hold open. Matches slate-windows-setup.ps1's -Distro.

.PARAMETER ScriptPath
    Where wsl-keepalive.ps1 lives on this host. It must be somewhere the task
    can read at boot - not a network path, not a user profile that roams.

.NOTES
    Run elevated. The task uses an S4U principal: it runs as the invoking user
    with NO stored password and works with nobody logged on.

    It must NEVER run as SYSTEM. .wslconfig is read from the %USERPROFILE% of
    whoever launches WSL, and C:\Windows\System32\config\systemprofile\.wslconfig
    does not exist - so a SYSTEM-launched WSL silently falls back to NAT
    networking (killing mDNS, IPv6 link-local, Matter and Cast) and to a default
    memory entitlement of half the host's RAM.
#>
[CmdletBinding()]
param(
    [string]$Distro     = 'Slate',
    [string]$ScriptPath = 'C:\workspace\slate\infra\wsl-keepalive.ps1',
    [string]$TaskName   = ''
)

$ErrorActionPreference = 'Stop'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(544)) {
    Write-Host "Run elevated: Register-ScheduledTask fails with 'Access is denied' otherwise." -ForegroundColor Red
    exit 1
}
if (-not (Test-Path $ScriptPath)) { throw "Not found: $ScriptPath" }
if (-not $TaskName) { $TaskName = "$Distro WSL keepalive" }

# Use the SID, not DOMAIN\user: over an SSH session the account-name form fails
# with "No mapping between account names and security IDs was done."
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ScriptPath`" -Distro $Distro"

$trigger   = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId $sid -LogonType S4U -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -MultipleInstances IgnoreNew `
    -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
    -StartWhenAvailable

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Force | Out-Null
Write-Host "==> Registered '$TaskName' (S4U, SID $sid)"

Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 20

Get-ScheduledTask -TaskName $TaskName | Select-Object TaskName, State | Format-Table -AutoSize
wsl.exe --list --verbose

# The real check: the task-launched distro must still be mirrored. A task under
# the wrong account leaves the distro looking healthy with no LAN at all.
$mode = (wsl.exe -d $Distro -u root -e wslinfo --networking-mode) -replace "`0", ''
Write-Host "==> networking mode under the task-launched distro: $mode"
if ($mode -notmatch 'mirrored') {
    Write-Host "!!  NOT mirrored - check which account the task runs as." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Verify after a reboot with nobody logged in:"
Write-Host "  wsl.exe --list --verbose                       # distro Running"
Write-Host "  wsl.exe -d $Distro -u root -e wslinfo --networking-mode   # mirrored"
Write-Host "  curl http://<lan-ip>:8080/health               # from another machine"
