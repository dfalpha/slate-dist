<#
.SYNOPSIS
    Prepares a Windows host to run a Slate server in a WSL2 distro.

.DESCRIPTION
    Slate's supported Windows shape is "WSL2 distro + native Docker inside it",
    NOT Docker Desktop. Docker Desktop's engine lives in its own VM behind
    192.168.65.0/24, so a container on --network host there hears only itself:
    measured 1 mDNS responder against 34 from a native container in a mirrored
    distro. Five subsystems need real LAN presence - Cast, Hue, Lutron and
    Ecobee HAP discovery are mDNS, and Matter additionally needs IPv6
    link-local on the same L2.

    This script does the whole Windows side and verifies it. It is idempotent:
    running it twice reconfigures rather than duplicating.

    First proven end to end on a production host on 2026-09-09, migrating
    off a Hyper-V VM. See infra/README.md.

.PARAMETER Distro
    Name of the WSL distro to create/configure. 'Slate' is the convention, and
    naming it at creation time avoids a rename later.

.PARAMETER LanIp
    The host's LAN IPv4. Used to find which adapter really carries the LAN.
    Defaults to the IPv4 of the interface holding the default route.

.PARAMETER MemoryGb / SwapGb
    WSL2 memory cap. With no .wslconfig at all WSL takes HALF the host's RAM.

.PARAMETER SkipDistroCreate
    Configure Windows only; do not create the distro.

.EXAMPLE
    pwsh -File slate-windows-setup.ps1 -Distro Slate

.NOTES
    MUST run in PowerShell 7 (pwsh), elevated. New-NetFirewallHyperVRule does
    not exist in Windows PowerShell 5.1.
#>
[CmdletBinding()]
param(
    [string]$Distro       = 'Slate',
    [string]$LanIp        = '',
    [int]$MemoryGb        = 16,
    [int]$SwapGb          = 8,
    [string]$UbuntuImage  = 'Ubuntu-26.04',
    [int]$VhdSizeGb       = 256,
    [switch]$SkipDistroCreate
)

$ErrorActionPreference = 'Stop'

function Say  { param($m) Write-Host "==> $m" }
function Warn { param($m) Write-Host "!!  $m" -ForegroundColor Yellow }
function Die  { param($m) Write-Host "XX  $m" -ForegroundColor Red; exit 1 }

# ---------------------------------------------------------------- preflight --
if ($PSVersionTable.PSVersion.Major -lt 6) {
    Die "Run this under pwsh (PowerShell 7). New-NetFirewallHyperVRule does not exist in Windows PowerShell $($PSVersionTable.PSVersion). Install with: winget install --id Microsoft.PowerShell -e"
}
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(544)) {
    Die "Run elevated."
}
if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    Die "WSL is not installed. Run: wsl --install --no-distribution, reboot, then re-run this."
}

# Docker Desktop silently replaces `docker` inside a distro with its own engine,
# and the container then lands in Desktop's VM with no LAN. Refuse rather than
# hand someone a stack that starts and discovers nothing.
if (Get-Service 'com.docker.service' -ErrorAction SilentlyContinue) {
    Warn "Docker Desktop is installed on this host."
    Warn "Turn OFF its WSL integration for '$Distro' (Settings > Resources > WSL integration),"
    Warn "or uninstall it. A Desktop-backed container has no LAN and every"
    Warn "integration fails silently."
}

if (-not $LanIp) {
    $LanIp = (Get-NetIPConfiguration |
        Where-Object { $_.IPv4DefaultGateway } |
        Select-Object -First 1).IPv4Address.IPAddress
}
if (-not $LanIp) { Die "Could not determine the LAN IPv4. Pass -LanIp explicitly." }
Say "LAN IPv4: $LanIp"

# --------------------------------------------- IPv6 on the RIGHT adapter -----
# The trap: on a host with a Hyper-V external switch the stack lives on the
# 'vEthernet (...)' adapter, not the physical NIC. Enabling IPv6 on 'Ethernet'
# does nothing. Resolve the adapter FROM the IP, never by name.
$alias = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object IPAddress -eq $LanIp).InterfaceAlias
if (-not $alias) { Die "No adapter holds $LanIp." }
Say "LAN adapter: $alias"

$binding = Get-NetAdapterBinding -Name $alias -ComponentID ms_tcpip6
if (-not $binding.Enabled) {
    Say "Enabling IPv6 on '$alias' (was off - Matter needs link-local)"
    Enable-NetAdapterBinding -Name $alias -ComponentID ms_tcpip6
    Warn "Enabling this binding resets the adapter; existing connections drop briefly."
} else {
    Say "IPv6 already enabled on '$alias'"
}

# ------------------------------------------------------------- .wslconfig ---
# Read from the %USERPROFILE% of whoever LAUNCHES wsl - which is why the
# keepalive task must never run as SYSTEM.
$wslconfigPath = "$env:USERPROFILE\.wslconfig"
$wslconfig = @"
# Slate host. Written by infra/install/slate-windows-setup.ps1.
#
# networkingMode=mirrored gives the distro the host's real interfaces, carrying
# IPv4 mDNS (Cast, Hue, Lutron, Ecobee HAP) and IPv6 link-local + NDP (Matter)
# into a container on host networking. Without it the distro is behind NAT and
# every one of those fails silently.
#
# hostAddressLoopback=true is the hairpin: without it THIS host cannot reach its
# own stack via its LAN IP (only 127.0.0.1), while LAN clients can - so it looks
# broken from the console and fine from a tablet.
#
# instanceIdleTimeout=-1 stops WSL terminating the distro ~15s after the last
# wsl.exe client exits. Undocumented on learn.microsoft.com but real: it is what
# the WSL Settings app's "Keep WSL running" toggle writes. Without it, every
# administrative command that touches the distro also RESTARTS THE WHOLE STACK
# on exit, which reads convincingly as an application crash loop.
#
# With no .wslconfig at all, WSL2 takes half the host's RAM.
# autoMemoryReclaim returns freed memory instead of holding the high-water mark.
# sparseVhd is deliberately absent: current WSL refuses it ("disabled due to
# potential data corruption") and forcing it with --allow-unsafe is not a trade
# worth making on a server.
[wsl2]
memory=${MemoryGb}GB
swap=${SwapGb}GB
networkingMode=mirrored

[experimental]
autoMemoryReclaim=gradual
hostAddressLoopback=true

[general]
instanceIdleTimeout=-1
"@

if (Test-Path $wslconfigPath) {
    $backup = "$wslconfigPath.bak-$(Get-Date -Format yyyy-MM-dd-HHmmss)"
    Copy-Item $wslconfigPath $backup
    Warn "Existing .wslconfig backed up to $backup and REPLACED."
}
# CRLF is what WSL expects here.
($wslconfig -replace "`r`n", "`n" -replace "`n", "`r`n") |
    Set-Content -Path $wslconfigPath -NoNewline -Encoding ASCII
Say "Wrote $wslconfigPath"

# ------------------------------------------- Hyper-V firewall (narrow set) ---
# The WSL VM's DefaultInboundAction is Block and it drops Neighbour
# Advertisements, echo replies and multicast mDNS. IPv4 unicast survives only
# because replies to a query Linux sent are tracked as a flow. WSL's shipped
# WslCore-Allow-Inbound-ICMPv6 rule does NOT match what Matter needs - measured.
# We keep Block and open exactly what the stack serves. This port list came from
# `ss -lntup` on a real Slate host; do not guess it.
$vmCreatorId = '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}'

Get-NetFirewallHyperVRule -ErrorAction SilentlyContinue |
    Where-Object Name -like 'Slate-*' |
    ForEach-Object { Remove-NetFirewallHyperVRule -Name $_.Name -ErrorAction SilentlyContinue }

function New-SlateRule {
    param($Name, $Display, $Protocol, $Ports)
    # -LocalPorts rejects a comma-separated STRING; it needs an array.
    $p = @{
        Name = $Name; DisplayName = $Display; Direction = 'Inbound'
        VMCreatorId = $vmCreatorId; Protocol = $Protocol; Action = 'Allow'
    }
    if ($Ports) { $p.LocalPorts = $Ports }
    New-NetFirewallHyperVRule @p | Out-Null
    Say "  rule $Name ($Protocol $($Ports -join ','))"
}

Say "Hyper-V firewall rules"
New-SlateRule 'Slate-ICMPv6'    'Slate: ICMPv6 (NDP, echo)'             'ICMPv6' $null
New-SlateRule 'Slate-mDNS'      'Slate: mDNS'                           'UDP' @('5353')
New-SlateRule 'Slate-Matter'    'Slate: Matter'                         'UDP' @('5540')
New-SlateRule 'Slate-HTTP'      'Slate: Caddy HTTP/HTTPS'               'TCP' @('80','443')
New-SlateRule 'Slate-HTTP3'     'Slate: Caddy HTTP/3'                   'UDP' @('443')
New-SlateRule 'Slate-Server'    'Slate: server HTTP/WS/admin/viewer'    'TCP' @('8080')
New-SlateRule 'Slate-Spotify'   'Slate: Spotify stream + librespot'     'TCP' @('8090','8091')
New-SlateRule 'Slate-MediaMTX'  'Slate: mediamtx WHEP/ICE'              'TCP' @('8889','8189')
New-SlateRule 'Slate-MediaMTXU' 'Slate: mediamtx ICE'                   'UDP' @('8189')
New-SlateRule 'Slate-Ephemeral' 'Slate: ephemeral UDP (ICE/HAP/Matter)' 'UDP' @('32768-60999')

# --------------------------------------------- port collisions with Windows --
# Mirrored means Linux and Windows share one address. A Windows service already
# on 443 or 8080 means Caddy or the server cannot bind. ignoredPorts is NOT the
# fix for a LAN-facing port.
Say "Checking for Windows services on Slate's ports"
$collision = $false
foreach ($port in 80, 443, 8080, 8090, 8091, 8189, 8889) {
    $c = Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue
    if ($c) {
        $procs = ($c | ForEach-Object {
            (Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).ProcessName
        } | Sort-Object -Unique) -join ','
        Warn "  TCP $port is already bound on Windows by: $procs"
        $collision = $true
    }
}
# UDP 5353 is the expected one: Windows ships its own mDNS responder. It is NOT
# a blocker - a mirrored distro binds 5353 alongside it (measured, not assumed).
$mdns = Get-NetUDPEndpoint -LocalPort 5353 -ErrorAction SilentlyContinue
if ($mdns) { Say "  UDP 5353 also bound on Windows (expected; Linux binds alongside it)" }
if ($collision) {
    Warn "Resolve the TCP collisions above before bringing the stack up."
}

# ------------------------------------------------------------ the distro ----
if (-not $SkipDistroCreate) {
    $existing = (wsl.exe --list --quiet) -replace "`0", '' -split "`r?`n" |
        ForEach-Object { $_.Trim() } | Where-Object { $_ }
    if ($existing -contains $Distro) {
        Say "Distro '$Distro' already exists; leaving it alone."
    } else {
        Say "Creating distro '$Distro' from $UbuntuImage (this downloads a few hundred MB)"
        wsl.exe --install -d $UbuntuImage --name $Distro --no-launch --vhd-size "${VhdSizeGb}GB"
        if ($LASTEXITCODE -ne 0) { Die "wsl --install failed ($LASTEXITCODE)." }
    }

    # systemd, so dockerd runs as a service and returns with the distro.
    $wslConf = @'
[boot]
systemd=true

[network]
generateResolvConf=true

[user]
default=root
'@
    $tmp = Join-Path $env:TEMP 'slate-wsl.conf'
    ($wslConf -replace "`r`n", "`n") | Set-Content -Path $tmp -NoNewline -Encoding ASCII
    $lin = 'cp "$(wslpath ' + "'$tmp'" + ')" /etc/wsl.conf'
    wsl.exe -d $Distro -u root -e sh -c $lin | Out-Null
    Say "Wrote /etc/wsl.conf (systemd=true)"
}

# ------------------------------------------------------------- apply + verify -
Say "Restarting WSL so mirrored mode, the firewall rules and wsl.conf take effect"
wsl.exe --shutdown
Start-Sleep -Seconds 5

if (-not $SkipDistroCreate) {
    Say "Verifying from inside '$Distro'"
    $check = @'
printf 'networking=%s\n' "$(wslinfo --networking-mode 2>/dev/null)"
printf 'loopback0=%s\n' "$(ip link show loopback0 >/dev/null 2>&1 && echo yes || echo no)"
printf 'lan_if=%s\n' "$(ip -4 -o route get 1.1.1.1 2>/dev/null | awk '{print $5}')"
printf 'lan_ip=%s\n' "$(ip -4 -o route get 1.1.1.1 2>/dev/null | awk '{print $7}')"
printf 'v6_linklocal=%s\n' "$(ip -6 -o addr show scope link 2>/dev/null | awk 'NR==1{print $4}')"
'@
    $tmp2 = Join-Path $env:TEMP 'slate-check.sh'
    ($check -replace "`r`n", "`n") | Set-Content -Path $tmp2 -NoNewline -Encoding ASCII
    $run = 'bash "$(wslpath ' + "'$tmp2'" + ')"'
    $out = wsl.exe -d $Distro -u root -e sh -c $run
    $out | ForEach-Object { Say "  $_" }

    if ($out -notmatch 'networking=mirrored') {
        Warn "NOT in mirrored mode. mDNS and IPv6 link-local will not work."
    }
    if ($out -notmatch 'v6_linklocal=fe80') {
        Warn "No IPv6 link-local inside the distro - the Matter lock cannot be commissioned."
    }
    # NOTE: the LAN interface is often eth1, not eth0 - a physical NIC enslaved
    # to a Hyper-V switch shows up as a DOWN eth0. Anything that pins an
    # interface name must read it, not assume it.
}

Say ""
Say "Windows side is ready."
Say "Next:"
Say "  1. Register the keepalive:  infra/install/slate-keepalive-task.ps1 -Distro $Distro"
Say "  2. Inside the distro:       infra/install/slate-migrate-to-wsl.sh (migration)"
Say "                              or infra/install/slate-install.sh (fresh install)"
