<#
.SYNOPSIS
    Keep the version Windows shows in Installed apps equal to the version
    Slate is actually running.
.DESCRIPTION
    The installer runs once. The server updates itself continuously - the
    compose stack tracks `ghcr.io/dfalpha/slate-server:production`, and
    Watchtower pulls a new digest whenever that tag moves. So within a day of
    installing, the version in Apps & Features is a lie, and it stays one for
    as long as the machine lives.

    This closes that gap: it asks the running server what it is, and writes the
    answer into the Add/Remove Programs entry. It is exactly what Chrome's
    updater does, and the reason Chrome's entry tracks Chrome.

    WHY AN INNO-SETUP EXE AND NOT AN MSI. An MSI owns its ARP entry:
    DisplayVersion is projected from the package's ProductVersion, and a
    background writer is editing a value Windows Installer considers its own -
    a repair or major upgrade resets it, and MSI upgrade logic then disagrees
    with what is displayed. Inno's uninstall key is a plain registry key we
    own outright, so this is the supported thing to do rather than a trick.

    WHY IT RUNS AS SYSTEM, when the WSL keepalive task must NOT. The keepalive
    has to run as the invoking user because WSL reads .wslconfig from that
    user's profile, and as SYSTEM it silently falls back to NAT networking -
    which breaks mDNS and therefore half the product. This task has the
    opposite requirement: it writes under HKLM and never launches WSL, so
    SYSTEM is right and a user context would just fail on permissions.
.PARAMETER AppId
    The Inno Setup AppId, without the trailing `_is1`.
.PARAMETER Endpoint
    Where to ask. Defaults to the local server's health route.
.PARAMETER WhatIf
    Print what would be written and change nothing.
#>
[CmdletBinding()]
param(
    [string]$AppId    = 'Slate.Server',
    [string[]]$Endpoint = @('http://127.0.0.1:8080/health', 'http://localhost:8080/health'),
    # Where the uninstall entries live. Overridable so the write path can be
    # exercised under HKCU without elevation - a version writer nobody can
    # test without an administrator shell is one nobody tests.
    [string[]]$UninstallRoot = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    ),
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'

# Both views by default. A 32-bit Inno install lands under WOW6432Node even on
# x64, and while this installer is built 64-bit, an older install on the same
# machine might not be - so look in both rather than assume.
$roots = $UninstallRoot | ForEach-Object { Join-Path $_ "${AppId}_is1" }

function Get-SlateVersion {
    foreach ($url in $Endpoint) {
        try {
            $r = Invoke-RestMethod -Uri $url -TimeoutSec 8 -ErrorAction Stop
        } catch {
            continue
        }
        if (-not $r.version) { continue }

        # `version` is the package version; `gitSha` is what actually differs
        # between two builds of it, and a promotion is a registry retag with
        # no rebuild, so the sha is the only honest discriminator. Semver
        # build metadata is the right place for it and ARP renders it fine.
        $v = [string]$r.version
        if ($r.gitSha -and $r.gitSha -ne 'unknown') {
            $short = ([string]$r.gitSha)
            if ($short.Length -gt 7) { $short = $short.Substring(0, 7) }
            $v = "$v+$short"
        }
        return $v
    }
    return $null
}

$version = Get-SlateVersion
if (-not $version) {
    # NOT AN ERROR, AND IT MUST NOT BE. The server is legitimately down during
    # a reboot, an update, or a long `docker pull`. Leaving the last known
    # version in place is correct; writing "unknown" over it would be worse
    # than saying nothing.
    Write-Verbose 'Slate is not answering; leaving the recorded version alone.'
    exit 0
}

$wrote = $false
foreach ($root in $roots) {
    if (-not (Test-Path $root)) { continue }
    $current = (Get-ItemProperty -Path $root -Name DisplayVersion -ErrorAction SilentlyContinue).DisplayVersion
    if ($current -eq $version) {
        Write-Verbose "$root already reads $version"
        $wrote = $true
        continue
    }
    if ($WhatIf) {
        Write-Host "would set $root\DisplayVersion = $version (was '$current')"
    } else {
        Set-ItemProperty -Path $root -Name DisplayVersion -Value $version
        Write-Host "Installed apps now reads $version (was '$current')"
    }
    $wrote = $true
}

if (-not $wrote) {
    Write-Verbose "No Slate uninstall entry found for AppId '$AppId' - nothing to update."
}
