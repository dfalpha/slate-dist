<#
.SYNOPSIS
    Register the scheduled task that keeps Installed apps in step with the
    version Slate is running.
.DESCRIPTION
    Runs slate-version-sync.ps1 at startup and every 15 minutes. Cheap: one
    HTTP request to localhost, and a registry write only when the value has
    actually changed.

    AS SYSTEM, DELIBERATELY. The WSL keepalive task in this same directory
    must run as the invoking user - WSL reads .wslconfig from that user's
    profile, and a SYSTEM-launched distro silently falls back to NAT, which
    breaks mDNS. This task is the mirror image: it writes under HKLM and
    never launches WSL, so it needs SYSTEM and would simply fail as a user.
    Do not "make them consistent" by aligning the principals.
.PARAMETER ScriptPath
    Where slate-version-sync.ps1 lives on this host.
.PARAMETER Remove
    Unregister the task instead of creating it.
#>
[CmdletBinding()]
param(
    [string]$ScriptPath = "$env:ProgramData\Slate\install\slate-version-sync.ps1",
    [string]$TaskName   = 'Slate version sync',
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(544)) {
    Write-Host 'Run elevated: registering a SYSTEM task needs administrator.' -ForegroundColor Red
    exit 1
}

if ($Remove) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "==> Removed '$TaskName'"
    exit 0
}

if (-not (Test-Path $ScriptPath)) {
    Write-Host "No script at $ScriptPath" -ForegroundColor Red
    exit 1
}

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ScriptPath`""

# At startup, and then on a repeating 15-minute cycle for the life of the
# session. Watchtower's own poll is five minutes, so a version change is
# reflected well inside the hour without this being chatty.
$atStartup = New-ScheduledTaskTrigger -AtStartup
$repeating = New-ScheduledTaskTrigger -Once -At (Get-Date).Date `
    -RepetitionInterval (New-TimeSpan -Minutes 15)

$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
    -MultipleInstances IgnoreNew `
    -StartWhenAvailable

Register-ScheduledTask -TaskName $TaskName -Action $action `
    -Trigger @($atStartup, $repeating) -Principal $principal -Settings $settings -Force | Out-Null

Write-Host "==> Registered '$TaskName' (SYSTEM, at startup and every 15 minutes)"
Start-ScheduledTask -TaskName $TaskName
