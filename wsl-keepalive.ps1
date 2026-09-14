# Starts a WSL2 distro at boot and brings it back if it goes down. Runs from a
# scheduled task; used for the CI runners' Ubuntu-26.04 and for the production
# Slate distro.
#
# WHY THIS EXISTS
# By default a WSL2 distro is terminated ~15 s after its last wsl.exe client
# exits (`[general] instanceIdleTimeout`, default 15000 - see the note above
# the param block). `[boot] systemd=true` does NOT change that - measured on
# DEFIANT 2026-09-08. So `wsl.exe -d Ubuntu-26.04 -- /bin/true` is useless on
# its own: it returns immediately and the distro dies with it. With
# instanceIdleTimeout=-1 set, this script is what STARTS the distro at boot
# and restarts it after `wsl --shutdown` or a VM crash; the setting is what
# keeps it up in between.
#
# This is not merely an availability gap. When the distro goes down it KILLS
# RUNNING JOBS: two jobs of run 34287215945 died at 00:36:11.91 and .93 with
# "The runner has received a shutdown signal", and journalctl showed the runner
# services stopping and restarting as the distro went down and came back.
#
# WHY A LOOP AND NOT A SINGLE HELD PROCESS
# `wsl --shutdown` kills every distro at once. A single held process would die
# with it and never return until the next reboot. This restarts it.
#
# WHY THIS MUST RUN AS THE OWNER, NOT AS SYSTEM
# .wslconfig is read from the %USERPROFILE% of whoever launches WSL.
# C:\Windows\System32\config\systemprofile\.wslconfig does not exist, so a
# SYSTEM-launched WSL would fall back to defaults: NAT networking instead of
# mirrored (breaking mDNS/IPv6 link-local, which the Matter and Cast work
# depends on) and memory = HALF OF HOST RAM = 64GB on this 128GB box. That is
# the exact runaway ~/.wslconfig's memory=28GB was written to stop after the
# WSL VM reached 65.6GB. SYSTEM is also a different session, so it would want
# its own utility VM while a distro's VHDX can attach to only one at a time.
#
# Install (ELEVATED PowerShell, needs the account password so the task can run
# at boot with nobody logged on):
#
#   schtasks /create /tn "WSL Ubuntu-26.04 keepalive" /sc onstart `
#     /ru <user> /rp <password> /f `
#     /tr "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\workspace\slate\infra\wsl-keepalive.ps1"
#
# Verify after a reboot with nobody logged in:
#   gh api repos/dfalpha/slate/actions/runners --jq '.runners[]|"\(.name) \(.status)"'
#   wsl.exe -d Ubuntu-26.04 -- wslinfo --networking-mode   # must say: mirrored

# PREFER `[general] instanceIdleTimeout=-1` IN .wslconfig OVER THIS SCRIPT.
# That setting (undocumented on learn.microsoft.com, but real - it is what the
# WSL Settings app's "Keep WSL running" toggle writes) stops WSL idle-terminating
# a distro at all, which is a cleaner fix than holding a client open. This script
# is still useful as the thing that STARTS the distro at boot; the setting only
# stops it being torn down afterwards. Slate's production host runs both.
param(
    [string]$Distro = 'Ubuntu-26.04'
)

while ($true) {
    try {
        # -e sleep infinity holds the distro open. This call blocks for as long
        # as the distro lives, so the loop only spins when it has gone away.
        & wsl.exe -d $Distro -u root -e sleep infinity
    } catch {
        # Swallow and retry - WSL may not be ready this early in boot.
    }
    # Distro went down (reboot, `wsl --shutdown`, crash). Pause so a genuinely
    # broken distro cannot become a tight restart loop, then bring it back.
    Start-Sleep -Seconds 10
}
