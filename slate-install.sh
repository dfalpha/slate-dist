#!/bin/sh
#
# Slate server installer (Linux).
#
# Installs Docker Engine + the compose plugin if missing, fetches the two
# compose files this stack needs from the public dist mirror, signs this
# machine in to Slate's registry and pulls the images, writes a host-local
# .env, brings the stack up, and then VERIFIES that
# the containers really are on the host's own network before declaring success.
#
# IT ASKS NOTHING. Every value in .env.example is either legitimately empty,
# ships a correct default, or has one this script knows better
# (env_installer_default) - so there is nothing for a customer to decide and
# nothing for them to get wrong. Owner, 2026-09-15 (D12): "Browser opens; the
# setup wizard creates the admin. Installers ask nothing." So the last thing
# this script does is hand over the server's single-use first-setup link -
# printed always, and opened in a browser when there is a desktop session.
#
# THE ONE INTERACTION IS A BROWSER APPROVAL (owner, 2026-09-24). The images
# are served from registry.slatepanel.app to Slate accounts with a licence, so
# the installer shows a code and a link, the customer approves this machine
# while signed in to their account, and the installer carries on - it never
# reads a keystroke and never sees the portal password. See registry_sign_in.
# The files come from https://github.com/dfalpha/slate-dist, a public mirror
# of exactly what an install fetches (never the source), with no credential.
#
# Runs from a pipe: `curl -fsSL https://get.slatepanel.app/linux | sudo sh`.
# Nothing reads stdin - under `curl | sh`, stdin IS the script, and a `read`
# from it would eat the next line of this file.
#
# Why that last part is not optional: five subsystems depend on real LAN
# presence - Cast discovery, Ecobee's HomeKit (HAP) pairing, Hue discovery and
# both Lutron discovery paths are all mDNS, plus Matter commissioning, which
# additionally needs IPv6 link-local on the same L2. A bridged container gets
# none of it, and the failure is silent: the stack comes up, the admin panel
# loads, and then nothing can find any device. See ../README.md's "Dedicated
# Linux VM per host" and "Lock control: Matter" sections.
#
# POSIX sh on purpose - no bashisms, so it runs under dash (Debian/Ubuntu's
# /bin/sh) as well as bash.
#
# Usage: sh slate-install.sh [--dry-run] [--install-dir DIR] [--help]

set -eu

# ---------------------------------------------------------------- constants

# The public mirror. CI (.github/workflows/dist.yml) pushes the released
# compose files, .env.example and the installer scripts there on every server
# promotion; raw.githubusercontent.com serves a public repository anonymously.
SLATE_DIST_RAW_DEFAULT="https://raw.githubusercontent.com/dfalpha/slate-dist/main"
SLATE_DIST_RAW="${SLATE_DIST_RAW:-$SLATE_DIST_RAW_DEFAULT}"

# Where the images come from (owner decision 2026-09-24): Slate's own
# registry, not public packages. Pulling needs a Slate account with a licence,
# so the installer signs the customer in through the browser first - the
# device-code flow in registry_sign_in below - and keeps the per-install
# credential it is given in root's docker config, where Watchtower reads it.
SLATE_REGISTRY="registry.slatepanel.app"
SLATE_PORTAL="https://portal.slatepanel.app"

# Where the customer types the code the Licence tab shows.
SLATE_PORTAL_LINK_URL="https://portal.slatepanel.app/account/link"

# The stack, as infra/README.md documents it. mediamtx and watchtower must be
# named explicitly: naming any service on the command line starts only the
# named ones, and forgetting mediamtx is exactly how doorbell video ran broken
# on every host for weeks (infra/README.md, 2026-08-28). soloist is Spotify's
# player (build PR 4): without it Spotify is simply off.
COMPOSE_SERVICES="server caddy watchtower mediamtx soloist"

# The host-shell command that prints (or with --new, rotates) the server's
# single-use first-setup link. The server mints the token itself on its first
# start with no administrator (server/src/auth/firstSetup.ts); this only reads
# it out, and it is the documented way to get a fresh one later.
SETUP_URL_COMMAND="docker exec slate-server node dist/cli/firstSetupUrl.js"

# What to do with that link at the end:
#   auto   print it, and open it in a browser when a desktop session exists
#   print  print it, never open a browser
#   none   say nothing about it - for a wrapper that fetches and opens the link
#          itself (the Windows and macOS installers), so it is never printed
#          into a log or on a screen that is not the one being looked at
SLATE_FIRST_SETUP="${SLATE_FIRST_SETUP:-auto}"

INSTALL_DIR="${SLATE_INSTALL_DIR:-/opt/slate}"
DRY_RUN=0
PREFLIGHT_PROBLEMS=0

# A registry credential handed in by a wrapper that already signed the
# customer in on its own side (the Windows and macOS installers), or by CI.
# Set, the browser sign-in is skipped. Never logged.
REGISTRY_USER="${SLATE_REGISTRY_USER:-}"
REGISTRY_TOKEN="${SLATE_REGISTRY_TOKEN:-}"

# Which installer is asking, shown to the customer on the approval page.
SLATE_INSTALLER_OS="${SLATE_INSTALLER_OS:-linux}"

# ------------------------------------------------------------------- output

log()  { printf '%s\n' "$*"; }
info() { printf '  %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }

step() {
    printf '\n== %s\n' "$*"
}

die() {
    printf '\nERROR: %s\n' "$*" >&2
    exit 1
}

# A preflight failure. In a real run this is fatal. Under --dry-run it is
# reported and execution continues, so the whole script can be exercised (in
# CI, for instance) on a machine that is deliberately not a valid target.
fatal_or_note() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf 'WOULD ABORT: %s\n' "$*" >&2
        PREFLIGHT_PROBLEMS=$((PREFLIGHT_PROBLEMS + 1))
    else
        die "$*"
    fi
}

have() {
    command -v "$1" >/dev/null 2>&1
}

# Run a state-changing command, or just print it under --dry-run. Read-only
# probes are NOT wrapped in this - they change nothing, so they are safe to
# run either way, and running them makes a dry run far more informative.
run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '  [dry-run] %s\n' "$*"
        return 0
    fi
    "$@"
}

usage() {
    cat <<'USAGE'
slate-install.sh - install and start a Slate server on Linux

Usage:
  sudo sh slate-install.sh [options]

Options:
  --dry-run            Print every action without changing anything. Preflight
                       failures are reported as "WOULD ABORT" instead of
                       stopping, so the whole flow can be exercised anywhere.
  --install-dir DIR    Where the stack lives (default: /opt/slate, or
                       $SLATE_INSTALL_DIR).
  -h, --help           This text.

Environment (all optional):
  SLATE_FIRST_SETUP    What to do with the first-setup link at the end: auto
                       (default: print it, and open a browser when there is a
                       desktop session), print (never open), or none.
  SLATE_INSTALL_DIR    Same as --install-dir.
  SLATE_DIST_RAW       Base URL of the public dist mirror (for testing).
  SLATE_REGISTRY_USER  A registry.slatepanel.app credential from an earlier
  SLATE_REGISTRY_TOKEN sign-in; set, the browser sign-in is skipped. Never
                       echoed, never written to the install directory.

Slate's images come from registry.slatepanel.app and need a Slate account
with a licence. The installer asks for nothing: it shows a code and a link
(and opens the link when there is a desktop), you approve this machine in
your browser while signed in to your Slate account, and it carries on. The
files come from the public mirror github.com/dfalpha/slate-dist.

What it does:
  1. Refuses to run where Slate cannot work (not Linux, not root, inside a
     container, or WSL without mirrored networking + native Docker).
  2. Installs Docker Engine + the compose plugin (apt or dnf) if absent.
  3. Fetches docker-compose.yml, infra/docker-compose.host-network.yml and
     .env.example from the dist mirror, anonymously.
  4. Writes <install-dir>/.env without asking anything, using .env.example as
     the source of truth for which variables exist. Mode 0600, never inside a
     checkout.
  5. Signs this machine in to registry.slatepanel.app (a browser approval,
     once), pulls the images and brings the stack up with host networking.
  6. VERIFIES host networking - container network namespace vs the host's,
     plus an mDNS sanity probe - and fails loudly with the reason if it is
     not what the stack needs.
  7. Prints the single-use first-setup link - and opens it in a browser when
     there is a desktop session - where you create the administrator and link
     this server to your Slate account. The link works once and expires after
     24 hours; print a fresh one with:
       sudo docker exec slate-server node dist/cli/firstSetupUrl.js --new

Re-running is safe: an existing Docker install, .env and running stack are
all detected and reused.
USAGE
}

# --------------------------------------------------------------- arg parsing

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --install-dir)
            [ $# -ge 2 ] || die "--install-dir needs a directory"
            INSTALL_DIR="$2"
            shift
            ;;
        --install-dir=*) INSTALL_DIR="${1#--install-dir=}" ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'Unknown option: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

# ---------------------------------------------------------------- preflight

# True if this kernel is WSL. Both markers are checked because the string has
# moved between WSL builds ("Microsoft" vs "microsoft-standard-WSL2").
is_wsl() {
    if [ -r /proc/sys/kernel/osrelease ] &&
       grep -qiE 'microsoft|wsl' /proc/sys/kernel/osrelease; then
        return 0
    fi
    if [ -r /proc/version ] && grep -qiE 'microsoft|wsl' /proc/version; then
        return 0
    fi
    return 1
}

in_container() {
    [ -f /.dockerenv ] && return 0
    [ -f /run/.containerenv ] && return 0
    if [ -r /proc/1/cgroup ] &&
       grep -qE '(:/docker/|:/lxc/|containerd|/docker-|libpod)' /proc/1/cgroup; then
        return 0
    fi
    return 1
}

# WSL is supported, but only in the one shape that was actually measured to
# work (docs/commercial-architecture.md, lane T1, 2026-09-08): a WSL distro in
# MIRRORED networking mode, running NATIVE Docker inside that distro.
#
# The measurement, by counting distinct mDNS responders on the LAN:
#   Ubuntu-24.04 WSL distro, mirrored ................... 35 responders
#   container, native docker inside that distro, host net  34 responders
#   container, Docker Desktop, --network host ............  1 (itself)
#
# Docker Desktop fails even with mirrored mode enabled because its engine runs
# in its own separate VM; --network host there means the host of THAT VM, and
# the container lands behind Docker Desktop's NAT on 192.168.65.0/24. Mirrored
# mode applies to WSL distros, and the engine VM is not one.
check_wsl() {
    is_wsl || return 0

    log "Detected WSL."
    info "Supported only as: WSL distro in mirrored networking mode, with"
    info "native Docker (docker.io / Docker's apt repo) installed INSIDE the"
    info "distro. Docker Desktop cannot work here - measured 2026-09-08:"
    info "1 mDNS responder via Docker Desktop vs 34 via native Docker in a"
    info "mirrored distro. Its engine runs in its own VM behind its own NAT."

    # In mirrored mode WSL creates a `loopback0` interface and the distro's
    # interfaces mirror the Windows host's - including a real LAN address and
    # the real default gateway. In the default NAT mode the distro gets a
    # 172.16/12 address behind a virtual switch instead.
    if have ip; then
        if ip link show loopback0 >/dev/null 2>&1; then
            info "Mirrored networking: yes (loopback0 present)."
        else
            wsl_gw=$(ip -4 route show default 2>/dev/null | awk '{print $3; exit}')
            case "$wsl_gw" in
                172.1[6-9].*|172.2[0-9].*|172.3[01].*|"")
                    fatal_or_note "WSL is NOT in mirrored networking mode (default route via '${wsl_gw:-none}'). Slate needs the real LAN. Add 'networkingMode=mirrored' under [wsl2] in %USERPROFILE%\\.wslconfig on Windows, run 'wsl --shutdown', and start the distro again."
                    ;;
                *)
                    warn "Could not confirm mirrored mode (no loopback0), but the default gateway ($wsl_gw) looks like a real LAN one. Continuing; the host-network verification at the end is the real test."
                    ;;
            esac
        fi
    else
        warn "'ip' is not installed, so mirrored networking could not be confirmed here. The verification step at the end still applies."
    fi

    # Matter commissioning is IPv6 link-local. Mirrored mode mirrors the
    # Windows host's interfaces, so if IPv6 is unbound on the Windows adapter
    # there is nothing to mirror and commissioning cannot even be attempted.
    if have ip; then
        if [ -z "$(ip -6 addr show scope link 2>/dev/null)" ]; then
            warn "No IPv6 link-local address in this distro. Everything else works, but the Matter lock cannot be commissioned. On Windows, enable IPv6 on the adapter (Enable-NetAdapterBinding -Name Ethernet -ComponentID ms_tcpip6), then 'wsl --shutdown' and start the distro again."
        fi
    fi
}

# Docker Desktop, on any OS, is a dead end for this stack - see check_wsl.
# `docker info` reports "Docker Desktop" as the operating system, which is the
# cheapest reliable way to spot it, including via WSL integration.
check_not_docker_desktop() {
    have docker || return 0
    dd_os=$(docker info --format '{{.OperatingSystem}}' 2>/dev/null || true)
    case "$dd_os" in
        *"Docker Desktop"*)
            fatal_or_note "This Docker is Docker Desktop, which cannot put a container on the real LAN: its engine runs in its own VM behind its own NAT, so mDNS discovery (Cast, Hue, Lutron, Ecobee HAP) sees nothing and the Matter lock cannot be commissioned. Measured 2026-09-08: 1 mDNS responder vs 34 from native Docker. Install Docker Engine natively on this Linux host (this script does that) and disable Docker Desktop's integration for it."
            ;;
    esac
}

preflight() {
    step "Preflight"

    if [ "$(uname -s 2>/dev/null || echo unknown)" != "Linux" ]; then
        fatal_or_note "Slate's server installs on Linux only. This is $(uname -s 2>/dev/null || echo 'an unknown OS'). On Windows 11 use the one-liner in an elevated PowerShell 7: irm https://get.slatepanel.app/windows | iex (it creates a WSL distro and runs this script inside it). On macOS (beta): curl -fsSL https://get.slatepanel.app/mac | sh (a bridged Linux VM via Lima). Docker Desktop on either cannot reach the LAN."
    else
        info "OS: Linux $(uname -r 2>/dev/null || echo '')"
    fi

    if [ "$(id -u)" != "0" ]; then
        fatal_or_note "This installer must run as root (it installs packages, writes to $INSTALL_DIR and manages services). Re-run with sudo."
    else
        info "Running as root."
    fi

    if in_container; then
        fatal_or_note "This looks like the inside of a container. Slate's server IS the container - run this installer on the host that will run Docker, not inside one."
    else
        info "Not running inside a container."
    fi

    check_wsl
    check_not_docker_desktop

    if ! have curl; then
        info "curl is missing; it will be installed with Docker's prerequisites."
    fi
}

# ------------------------------------------------------------ docker install

# /etc/os-release is read with sed rather than sourced: sourcing an
# arbitrary file into this shell would let it redefine anything here.
os_release_field() {
    [ -r /etc/os-release ] || return 0
    sed -n "s/^$1=//p" /etc/os-release 2>/dev/null | head -n 1 | tr -d '"'
}

# Sets OS_ID / OS_LIKE / OS_CODENAME from /etc/os-release.
read_os_release() {
    OS_ID=$(os_release_field ID)
    OS_LIKE=$(os_release_field ID_LIKE)
    OS_CODENAME=$(os_release_field UBUNTU_CODENAME)
    if [ -z "$OS_CODENAME" ]; then
        OS_CODENAME=$(os_release_field VERSION_CODENAME)
    fi
}

install_docker_apt() {
    # Docker publishes separate repositories for Debian and Ubuntu; anything
    # derived (Mint, Pop, Raspberry Pi OS) is served by its parent's.
    case "$OS_ID" in
        ubuntu|debian) docker_flavour="$OS_ID" ;;
        *)
            case "$OS_LIKE" in
                *ubuntu*) docker_flavour="ubuntu" ;;
                *debian*) docker_flavour="debian" ;;
                *) docker_flavour="debian" ;;
            esac
            ;;
    esac
    if [ -z "$OS_CODENAME" ]; then
        fatal_or_note "Could not determine this distribution's codename from /etc/os-release, so Docker's apt repository cannot be configured. Install Docker Engine and the compose plugin manually (https://docs.docker.com/engine/install/), then re-run this script - it skips this step when Docker is already present."
        return 0
    fi

    info "Using Docker's $docker_flavour apt repository ($OS_CODENAME)."
    run env DEBIAN_FRONTEND=noninteractive apt-get update
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl
    run install -m 0755 -d /etc/apt/keyrings
    run curl -fsSL "https://download.docker.com/linux/$docker_flavour/gpg" \
        -o /etc/apt/keyrings/docker.asc
    run chmod a+r /etc/apt/keyrings/docker.asc

    if [ "$DRY_RUN" -eq 1 ]; then
        printf '  [dry-run] write /etc/apt/sources.list.d/docker.list\n'
    else
        arch=$(dpkg --print-architecture)
        printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/%s %s stable\n' \
            "$arch" "$docker_flavour" "$OS_CODENAME" \
            > /etc/apt/sources.list.d/docker.list
    fi

    run env DEBIAN_FRONTEND=noninteractive apt-get update
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y \
        docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

install_docker_dnf() {
    case "$OS_ID" in
        fedora) docker_flavour="fedora" ;;
        rhel) docker_flavour="rhel" ;;
        centos|rocky|almalinux) docker_flavour="centos" ;;
        *)
            case "$OS_LIKE" in
                *fedora*) docker_flavour="fedora" ;;
                *) docker_flavour="centos" ;;
            esac
            ;;
    esac

    info "Using Docker's $docker_flavour dnf repository."
    run dnf -y install ca-certificates curl
    # The .repo file is fetched directly rather than via `dnf config-manager`,
    # whose syntax changed between dnf4 and dnf5. The file itself is
    # release-independent ($releasever is expanded by dnf).
    run curl -fsSL "https://download.docker.com/linux/$docker_flavour/docker-ce.repo" \
        -o /etc/yum.repos.d/docker-ce.repo
    run dnf -y install \
        docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

ensure_docker() {
    step "Docker Engine + compose plugin"

    if have docker && docker compose version >/dev/null 2>&1; then
        info "Already installed: $(docker --version 2>/dev/null || echo docker), $(docker compose version --short 2>/dev/null || echo 'compose plugin')"
    else
        read_os_release
        if have apt-get; then
            install_docker_apt
        elif have dnf; then
            install_docker_dnf
        else
            fatal_or_note "No supported package manager found (need apt-get or dnf). Install Docker Engine and the compose plugin manually - https://docs.docker.com/engine/install/ - then re-run this script; it skips this step when Docker is already present."
        fi
    fi

    if have systemctl; then
        run systemctl enable --now docker
    else
        warn "systemctl not found; make sure the Docker daemon is running and starts at boot. Slate's server must be always on - a lock that stops responding because the host rebooted is the failure customers notice first."
    fi

    if [ "$DRY_RUN" -eq 0 ]; then
        docker info >/dev/null 2>&1 ||
            die "The Docker daemon is not responding after installation. Check 'systemctl status docker'."
        # Re-check now that a daemon definitely exists: Docker Desktop's WSL
        # integration can be what answers here even after a native install.
        check_not_docker_desktop
    fi
}

# ------------------------------------------------------- registry sign-in
#
# Owner, 2026-09-24: the images live on registry.slatepanel.app and pulling
# them needs a Slate account with a licence. The customer's portal password
# never comes near this script - it runs as root on a machine nobody has
# authenticated - so it is RFC 8628's device flow, the same one the Licence
# tab uses to link a server:
#
#   1. ask the portal for a code          POST /registry/device/code
#   2. show the code and link; open the link when there is a desktop
#   3. the customer approves this machine in their browser
#   4. poll until the credential arrives  POST /registry/device/token
#   5. `docker login` with it, as root - Watchtower mounts root's docker
#      config, so every later update uses the same credential
#
# The portal answers in key=value lines (Accept: text/plain): this is POSIX sh
# under `curl | sh`, with no jq, and parsing JSON with sed breaks on the first
# unusual character.

registry_already_authenticated() {
    [ -f "$HOME/.docker/config.json" ] || return 1
    grep -q "$SLATE_REGISTRY" "$HOME/.docker/config.json"
}

# $1 = the key=value body, $2 = the key.
kv() {
    printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -n 1
}

# POST a small JSON body read from stdin, so a device code is never on a
# command line. Prints the body whatever the status: RFC 8628's "keep waiting"
# answers are 400s.
portal_post() {
    curl -sS --max-time 30 -X POST -H 'Accept: text/plain' -H 'Content-Type: application/json' \
        --data-binary @- "$SLATE_PORTAL$1"
}

# --password-stdin, so the credential never appears in the process list, the
# shell history or the terminal.
registry_login() {
    printf '%s' "$REGISTRY_TOKEN" | docker login "$SLATE_REGISTRY" -u "$REGISTRY_USER" --password-stdin >/dev/null ||
        die "docker login to $SLATE_REGISTRY failed with the credential this machine was given. Run the installer again to sign in afresh."
    info "Signed in to $SLATE_REGISTRY."
}

# The browser sign-in. Fills REGISTRY_USER and REGISTRY_TOKEN, or dies saying
# why. Waits as long as the code lives (ten minutes) and no longer.
registry_device_flow() {
    started=$(printf '{"os":"%s"}' "$SLATE_INSTALLER_OS" | portal_post /registry/device/code) ||
        die "Could not reach $SLATE_PORTAL to sign in. Check this machine can reach the internet, then re-run."
    device_code=$(kv "$started" device_code)
    user_code=$(kv "$started" user_code)
    verify_uri=$(kv "$started" verification_uri)
    verify_full=$(kv "$started" verification_uri_complete)
    interval=$(kv "$started" interval)
    expires_in=$(kv "$started" expires_in)
    [ -n "$device_code" ] && [ -n "$user_code" ] ||
        die "The Slate portal did not start a sign-in ($(kv "$started" error)). Try again in a minute."
    case "$interval" in ''|*[!0-9]*) interval=5 ;; esac
    case "$expires_in" in ''|*[!0-9]*) expires_in=600 ;; esac

    printf '\n'
    log "Approve this machine with your Slate account to download Slate:"
    log "  1. Open   $verify_uri"
    log "  2. Enter  $user_code"
    log "Sign in with the account that holds your Slate licence. The code lasts"
    log "ten minutes; this installer carries on by itself once you approve."
    if find_desktop_session; then
        open_in_browser "${verify_full:-$verify_uri}"
        log "(Opening it in your browser now.)"
    fi

    waited=0
    while [ "$waited" -lt "$expires_in" ]; do
        sleep "$interval"
        waited=$((waited + interval))
        polled=$(printf '{"device_code":"%s"}' "$device_code" | portal_post /registry/device/token) || continue
        REGISTRY_USER=$(kv "$polled" username)
        REGISTRY_TOKEN=$(kv "$polled" password)
        if [ -n "$REGISTRY_USER" ] && [ -n "$REGISTRY_TOKEN" ]; then
            device_code=""
            polled=""
            info "Approved."
            return 0
        fi
        case "$(kv "$polled" error)" in
            authorization_pending) ;;
            slow_down) interval=$((interval + 5)) ;;
            access_denied)
                die "The sign-in was refused, or the Slate account has no active licence. Start a trial or buy a licence at $SLATE_PORTAL, then re-run." ;;
            expired_token)
                die "The code expired before it was approved. Re-run the installer for a new one." ;;
            *) ;;
        esac
    done
    die "The code expired before it was approved. Re-run the installer for a new one."
}

# $1 = "force" to sign in again even with a stored credential (it was refused).
registry_sign_in() {
    if [ "$DRY_RUN" -eq 1 ]; then
        info "[dry-run] would sign this machine in to $SLATE_REGISTRY: show a code and"
        info "[dry-run] $SLATE_PORTAL/account/authorize-install, open it when there is a"
        info "[dry-run] desktop, wait for approval, then docker login with the credential."
        return 0
    fi
    if [ -n "$REGISTRY_USER" ] && [ -n "$REGISTRY_TOKEN" ]; then
        registry_login
        return 0
    fi
    if [ "${1:-}" != force ] && registry_already_authenticated; then
        info "This machine is already signed in to $SLATE_REGISTRY."
        return 0
    fi
    registry_device_flow
    registry_login
}

# --------------------------------------------------------------- file fetch

# $1 = path within the mirror, $2 = destination file. Anonymous, from the
# public dist mirror; it needs no credential of any kind.
fetch_repo_file() {
    fetch_url="$SLATE_DIST_RAW/$1"
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '  [dry-run] fetch %s -> %s (anonymous)\n' "$fetch_url" "$2"
        return 0
    fi
    if curl -fsSL -o "$2.part" "$fetch_url" 2>/dev/null && [ -s "$2.part" ]; then
        mv "$2.part" "$2"
        return 0
    fi
    rm -f "$2.part"
    die "Could not download $1 from $SLATE_DIST_RAW. Check this machine can reach raw.githubusercontent.com, then re-run."
}

fetch_stack_files() {
    step "Fetching the stack files into $INSTALL_DIR"

    guard_not_a_checkout

    run mkdir -p "$INSTALL_DIR/infra"
    fetch_repo_file "docker-compose.yml" "$INSTALL_DIR/docker-compose.yml"
    fetch_repo_file "infra/docker-compose.host-network.yml" \
        "$INSTALL_DIR/infra/docker-compose.host-network.yml"
    fetch_repo_file ".env.example" "$INSTALL_DIR/.env.example"

    if [ "$DRY_RUN" -eq 0 ]; then
        grep -q '^services:' "$INSTALL_DIR/docker-compose.yml" ||
            die "The fetched docker-compose.yml does not look like a compose file. Check $SLATE_DIST_RAW."
        grep -q 'network_mode: host' "$INSTALL_DIR/infra/docker-compose.host-network.yml" ||
            die "The fetched host-network override does not set network_mode: host. Refusing to continue - host networking is mandatory for this stack."
        info "docker-compose.yml, infra/docker-compose.host-network.yml, .env.example"
    fi
}

# The .env this writes can hold secrets (an optional recovery password, keys
# added later). It must never land inside a git working tree, where a stray `git add -A` could
# commit it.
guard_not_a_checkout() {
    guard_dir="$INSTALL_DIR"
    while [ -n "$guard_dir" ] && [ "$guard_dir" != "/" ]; do
        if [ -e "$guard_dir/.git" ]; then
            die "$INSTALL_DIR is inside a git working tree ($guard_dir). This installer writes a .env containing secrets and refuses to put one in a checkout. Choose another directory with --install-dir."
        fi
        guard_dir=$(dirname "$guard_dir")
    done
}

# ----------------------------------------------------------------- .env file

# .env.example is the source of truth for which variables exist - the script
# does not carry its own list, so a variable added to the repo shows up here
# on the next run without touching this file.
env_example_vars() {
    sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' "$1"
}

# Existing value for a variable in an existing .env, so a re-run keeps what is
# already configured instead of asking the operator to retype it.
env_current_value() {
    [ -f "$1" ] || return 0
    sed -n "s/^$2=//p" "$1" | head -n 1
}

# Defaults this installer knows better than .env.example does, because this
# script only ever installs the host-networking shape.
env_installer_default() {
    case "$1" in
        # Under host networking the compose bridge does not exist, so caddy
        # reaches the server as another process on the same host.
        SLATE_UPSTREAM) printf 'localhost:8080' ;;
        # Deliberately blank on host networking: mediamtx finds the real LAN
        # interface itself.
        SLATE_HOST_LAN_IP) printf '' ;;
        SLATE_RESET_ADMIN_PASSWORD) printf 'false' ;;
        WATCHTOWER_POLL_INTERVAL) printf '300' ;;
        *) printf '' ;;
    esac
}

# The value a variable gets when nobody is asked for it. In order:
#   1. what an existing .env already has - a re-run keeps this install's
#      answers, including a hostname the portal assigned since last time;
#   2. what this installer knows better than .env.example does, because it
#      only ever builds the host-networking shape (env_installer_default);
#   3. what .env.example ships, which is the shipped default for everything
#      else and empty where empty is the right answer.
# $1 variable, $2 the existing .env, $3 .env.example.
env_resolved_value() {
    resolved=$(env_current_value "$2" "$1")
    [ -n "$resolved" ] || resolved=$(env_installer_default "$1")
    [ -n "$resolved" ] || resolved=$(env_current_value "$3" "$1")
    printf '%s' "$resolved"
}

# Nothing in here asks a question. The first administrator is not an
# installer setting at all any more: the server has none until somebody opens
# the first-setup link at the end of this script and creates one (D12).
write_env() {
    step "Configuration ($INSTALL_DIR/.env)"

    if [ "$DRY_RUN" -eq 1 ]; then
        info "[dry-run] would write $INSTALL_DIR/.env (mode 0600) with every"
        info "[dry-run] variable in .env.example, taking each value from an"
        info "[dry-run] existing .env, then this installer's own defaults, then"
        info "[dry-run] .env.example's. It asks nothing: the administrator is"
        info "[dry-run] created in the browser afterwards."
        return 0
    fi

    env_file="$INSTALL_DIR/.env"
    example_file="$INSTALL_DIR/.env.example"
    tmp_file="$INSTALL_DIR/.env.new"

    [ -f "$example_file" ] || die "$example_file is missing; cannot determine which settings exist."
    if [ -f "$env_file" ]; then
        info "An existing .env was found - every value already in it is kept."
    fi

    umask 077
    : > "$tmp_file"
    printf '# Generated by slate-install.sh. Host-local; may contain secrets.\n' >> "$tmp_file"
    printf '# Regenerate by re-running the installer.\n\n' >> "$tmp_file"

    for var in $(env_example_vars "$example_file"); do
        value=$(env_resolved_value "$var" "$env_file" "$example_file")
        printf '%s=%s\n' "$var" "$value" >> "$tmp_file"
    done
    value=""

    mv "$tmp_file" "$env_file"
    chmod 600 "$env_file"
    info "Wrote $env_file (mode 0600)."
}

# --------------------------------------------------------------- bring it up

compose() {
    docker compose \
        -f "$INSTALL_DIR/docker-compose.yml" \
        -f "$INSTALL_DIR/infra/docker-compose.host-network.yml" \
        "$@"
}

# CADDY STARTS EVEN WITH NO HOSTNAME, AND THAT IS THE POINT.
#
# This used to drop caddy from the list when SLATE_HOSTNAME was empty, because
# the Caddyfile named that variable and a nameless Caddy died on a config
# error. The Caddyfile no longer references it at all: Caddy boots a valid
# bootstrap config in every case, and the SERVER pushes it a site over Caddy's
# admin API on 127.0.0.1:2019 once the account is linked and a certificate
# exists.
#
# So Caddy has to be RUNNING for there to be an admin API to push to. Leave it
# out of a fresh install and the server has nothing to configure, and HTTPS
# never comes up however correctly everything else behaves. Do not re-add the
# optimisation: it is running so that the server can configure it.
stack_up() {
    step "Starting the stack"
    if [ "$DRY_RUN" -eq 1 ]; then
        registry_sign_in
        printf '  [dry-run] docker compose -f %s -f %s pull %s   (from %s, signed in)
'             "$INSTALL_DIR/docker-compose.yml"             "$INSTALL_DIR/infra/docker-compose.host-network.yml"             "$COMPOSE_SERVICES" "$SLATE_REGISTRY"
        printf '  [dry-run] docker compose -f %s -f %s up -d %s
'             "$INSTALL_DIR/docker-compose.yml"             "$INSTALL_DIR/infra/docker-compose.host-network.yml"             "$COMPOSE_SERVICES"
        info "[dry-run] caddy is in that list with or without a hostname - the"
        info "[dry-run] server configures it over its admin API once linked."
        return 0
    fi
    registry_sign_in
    pull_images
    # Word splitting is intended here - it is a service list.
    # shellcheck disable=SC2086
    compose up -d $COMPOSE_SERVICES ||
        die "'docker compose up' failed. Run it by hand in $INSTALL_DIR to see why."
    info "Containers started."
}

# A refusal with a STORED credential means it was withdrawn from the portal or
# the account's licence has lapsed: sign in afresh once, then pull again. Any
# other failure (no network, a typo in the compose file) is reported as itself.
pull_images() {
    info "Pulling images from $SLATE_REGISTRY."
    pull_log=$(mktemp)
    # shellcheck disable=SC2086
    if compose pull $COMPOSE_SERVICES >"$pull_log" 2>&1; then
        rm -f "$pull_log"
        return 0
    fi
    if ! grep -qiE 'denied|unauthorized|authentication required|requested access to the resource is denied' "$pull_log"; then
        cat "$pull_log" >&2
        rm -f "$pull_log"
        die "Could not pull the Slate images. This does not look like a sign-in problem - check the output above and the network."
    fi
    rm -f "$pull_log"

    warn "$SLATE_REGISTRY refused this machine's credential - it was withdrawn, or the Slate account has no active licence. Signing in again."
    REGISTRY_USER=""
    REGISTRY_TOKEN=""
    registry_sign_in force
    # shellcheck disable=SC2086
    compose pull $COMPOSE_SERVICES ||
        die "Could not pull the Slate images even after signing in again. Check the Slate account at $SLATE_PORTAL has an active licence."
}

# ------------------------------------------------------------- verification

# Proof, not assumption: the container's network namespace must literally be
# the host's. Comparing /proc/<pid>/ns/net inode links is definitive and needs
# nothing installed inside the image (which is alpine, and has no `ip`).
verify_host_network() {
    step "Verifying host networking"

    if [ "$DRY_RUN" -eq 1 ]; then
        info "[dry-run] would check slate-server's NetworkMode is 'host',"
        info "[dry-run] compare its net namespace with the host's, and probe"
        info "[dry-run] for mDNS responders on the LAN."
        return 0
    fi

    mode=$(docker inspect -f '{{.HostConfig.NetworkMode}}' slate-server 2>/dev/null || printf 'unknown')
    if [ "$mode" != "host" ]; then
        die "slate-server is on network mode '$mode', not 'host'. The host-network override did not take effect. Five subsystems need real LAN presence - Cast, Ecobee HAP, Hue and both Lutron paths are mDNS, and Matter commissioning needs IPv6 link-local on the same L2 - and none of them work from a bridged container. Re-run compose with -f infra/docker-compose.host-network.yml."
    fi
    info "NetworkMode: host"

    cpid=$(docker inspect -f '{{.State.Pid}}' slate-server 2>/dev/null || printf '0')
    if [ "$cpid" = "0" ] || [ ! -e "/proc/$cpid/ns/net" ]; then
        die "Could not read slate-server's network namespace (pid '$cpid'). The container may not be running: check 'docker ps -a' and 'docker logs slate-server'."
    fi
    cns=$(readlink "/proc/$cpid/ns/net" 2>/dev/null || printf 'container-unknown')
    hns=$(readlink /proc/1/ns/net 2>/dev/null || printf 'host-unknown')
    if [ "$cns" != "$hns" ]; then
        die "slate-server claims host networking but its network namespace ($cns) is not the host's ($hns). Something is virtualising the network under this container - Docker Desktop is the usual cause, and it cannot reach the LAN. See infra/install/README.md."
    fi
    info "Network namespace: shared with the host ($hns)"

    verify_mdns
    verify_ipv6_link_local
}

# An mDNS sanity check. It runs on the host rather than in the container, and
# that is sound BECAUSE of the namespace check above: the container is in the
# host's network namespace, so what the host can see on 224.0.0.251, the
# container sees identically.
#
# Dependency-free by design: it uses whatever is already here (avahi-browse,
# or python3's standard library) and simply reports that it could not check if
# neither exists. Nothing is installed for it.
verify_mdns() {
    responders=""
    if have avahi-browse; then
        responders=$(avahi-browse -a -t -p 2>/dev/null | awk -F';' '/^=/ {print $8}' | sort -u | grep -c . || true)
        mdns_how="avahi-browse"
    elif have python3; then
        responders=$(python3 - <<'PY' 2>/dev/null || true
import socket, struct, time

def query(name):
    out = b""
    for label in name.split("."):
        out += bytes([len(label)]) + label.encode()
    out += b"\x00"
    # id 0, standard query, one question, PTR (12) IN (1)
    return struct.pack(">HHHHHH", 0, 0, 1, 0, 0, 0) + out + struct.pack(">HH", 12, 1)

names = ["_services._dns-sd._udp.local", "_googlecast._tcp.local",
         "_hap._tcp.local", "_hue._tcp.local"]
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 2)
s.settimeout(0.4)
try:
    for n in names:
        try:
            s.sendto(query(n), ("224.0.0.251", 5353))
        except OSError:
            pass
    seen = set()
    deadline = time.time() + 4
    while time.time() < deadline:
        try:
            _, addr = s.recvfrom(4096)
            seen.add(addr[0])
        except socket.timeout:
            continue
        except OSError:
            break
    print(len(seen))
finally:
    s.close()
PY
)
        mdns_how="python3 multicast probe"
    else
        warn "Neither avahi-browse nor python3 is present, so the mDNS sanity check was skipped. Nothing was installed for it. The namespace check above already proves host networking; confirm discovery from the admin panel (Cast, Hue, Ecobee) once you log in."
        return 0
    fi

    case "$responders" in
        ''|*[!0-9]*) responders=0 ;;
    esac

    if [ "$responders" -gt 0 ]; then
        info "mDNS: $responders responder(s) on the LAN ($mdns_how)."
    else
        warn "mDNS: no responders answered on this LAN ($mdns_how). Host networking itself is confirmed, so this is most likely a quiet network, a firewall dropping UDP 5353, or multicast filtered by the switch/AP. Cast, Hue, Lutron and Ecobee discovery all depend on this working - check it before assuming a Slate bug."
    fi
}

verify_ipv6_link_local() {
    if ! have ip; then
        return 0
    fi
    if [ -z "$(ip -6 addr show scope link 2>/dev/null)" ]; then
        warn "No IPv6 link-local address on this host. Everything else works, but the Matter lock cannot be commissioned - Matter's commissioning advertisement (_matterc._udp) is IPv6 link-local on the same L2. Enable IPv6 on this machine's LAN interface."
    else
        info "IPv6 link-local: present (Matter commissioning can be attempted)."
    fi
}

host_lan_ip() {
    if have ip; then
        ip route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<NF;i++) if ($i=="src") {print $(i+1); exit}}'
        return 0
    fi
    if have hostname; then
        hostname -I 2>/dev/null | awk '{print $1}'
    fi
}

wait_for_server() {
    if [ "$DRY_RUN" -eq 1 ]; then
        info "[dry-run] would poll http://localhost:8080/health until it answers."
        return 0
    fi
    if ! have curl; then
        return 0
    fi
    attempt=0
    while [ "$attempt" -lt 30 ]; do
        if curl -fsS -m 2 http://localhost:8080/health >/dev/null 2>&1; then
            info "Server health check: OK"
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 2
    done
    warn "The server did not answer http://localhost:8080/health within 60s. It may still be starting; check 'docker logs slate-server'."
}

# ------------------------------------------------------------- first setup

FIRST_SETUP_URL=""
FIRST_SETUP_STATE=""

# Reads the first-setup link out of the running server. $1 is the host to put
# in it. Sets FIRST_SETUP_STATE to:
#   url           FIRST_SETUP_URL holds the link;
#   admin-exists  the command's exit 3 - an existing install that already has
#                 an administrator, so there is nothing to set up;
#   unavailable   anything else (an older image without the command, a server
#                 that is not up) - the caller prints how to get it by hand.
read_first_setup_url() {
    FIRST_SETUP_URL=""
    FIRST_SETUP_STATE=unavailable
    have docker || return 0
    # Word splitting of SETUP_URL_COMMAND is intended: it is a command line.
    # shellcheck disable=SC2086
    if setup_out=$($SETUP_URL_COMMAND --host "$1" 2>/dev/null); then
        FIRST_SETUP_URL=$(printf '%s\n' "$setup_out" | head -n 1)
        case "$FIRST_SETUP_URL" in
            http://*"/admin/setup?t="*) FIRST_SETUP_STATE=url ;;
            *) FIRST_SETUP_URL="" ;;
        esac
    else
        setup_rc=$?
        if [ "$setup_rc" -eq 3 ]; then
            FIRST_SETUP_STATE=admin-exists
        fi
    fi
    setup_out=""
}

OPEN_USER=""
OPEN_DISPLAY=""
OPEN_WAYLAND=""
OPEN_RUNTIME=""

# True when there is a graphical session to open a browser in. This script
# runs as root, normally through sudo, and root has no desktop - so it looks
# for the session of the user who ran sudo. A headless server has neither a
# display variable nor a Wayland or X socket, and gets the link printed only.
#
# WSL is excluded on purpose: there the Windows installer opens the browser on
# Windows, and a Linux browser appearing through WSLg would be a second one.
find_desktop_session() {
    if is_wsl || ! have xdg-open; then
        return 1
    fi
    OPEN_USER=""
    OPEN_DISPLAY="${DISPLAY:-}"
    OPEN_WAYLAND="${WAYLAND_DISPLAY:-}"
    OPEN_RUNTIME="${XDG_RUNTIME_DIR:-}"
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
        have sudo || return 1
        open_uid=$(id -u "$SUDO_USER" 2>/dev/null || printf '')
        [ -n "$open_uid" ] || return 1
        OPEN_USER="$SUDO_USER"
        OPEN_RUNTIME="/run/user/$open_uid"
        if [ -z "$OPEN_WAYLAND" ] && [ -S "$OPEN_RUNTIME/wayland-0" ]; then
            OPEN_WAYLAND=wayland-0
        fi
        if [ -z "$OPEN_DISPLAY" ] && [ -S /tmp/.X11-unix/X0 ]; then
            OPEN_DISPLAY=:0
        fi
    fi
    [ -n "$OPEN_DISPLAY" ] || [ -n "$OPEN_WAYLAND" ]
}

# As the desktop user, in the background, output discarded: a browser that
# will not start must not fail an install that has already succeeded, and the
# link is on screen either way. Call find_desktop_session first.
open_in_browser() {
    open_url="$1"
    set -- env
    if [ -n "$OPEN_DISPLAY" ]; then set -- "$@" "DISPLAY=$OPEN_DISPLAY"; fi
    if [ -n "$OPEN_WAYLAND" ]; then set -- "$@" "WAYLAND_DISPLAY=$OPEN_WAYLAND"; fi
    if [ -n "$OPEN_RUNTIME" ]; then
        set -- "$@" "XDG_RUNTIME_DIR=$OPEN_RUNTIME"
        if [ -S "$OPEN_RUNTIME/bus" ]; then
            set -- "$@" "DBUS_SESSION_BUS_ADDRESS=unix:path=$OPEN_RUNTIME/bus"
        fi
    fi
    if [ -n "$OPEN_USER" ]; then
        set -- sudo -u "$OPEN_USER" "$@"
    fi
    "$@" xdg-open "$open_url" >/dev/null 2>&1 &
    open_url=""
}

# D12, 2026-09-15: "Browser opens; the setup wizard creates the admin.
# Installers ask nothing." The server minted a single-use token on its first
# start with no administrator; this reads the link out and hands it over.
# $1 is this host's LAN address, which is what a link printed for use from
# another machine has to carry.
show_first_setup() {
    setup_mode="$SLATE_FIRST_SETUP"
    case "$setup_mode" in
        auto|print|none) ;;
        *)
            warn "SLATE_FIRST_SETUP='$setup_mode' is not auto, print or none; using auto."
            setup_mode=auto
            ;;
    esac
    if [ "$setup_mode" = none ]; then
        return 0
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        info "[dry-run] would print the single-use first-setup link ($SETUP_URL_COMMAND)"
        if [ "$setup_mode" = auto ] && find_desktop_session; then
            info "[dry-run] and open it in a browser: a desktop session is present."
        else
            info "[dry-run] and open no browser: no desktop session here, or SLATE_FIRST_SETUP=print."
        fi
        return 0
    fi

    read_first_setup_url "${1:-localhost}"
    case "$FIRST_SETUP_STATE" in
        url)
            log "Finish setting up in a browser: create the administrator, then link"
            log "this server to your Slate account. Open:"
            log "  $FIRST_SETUP_URL"
            log "The link works once and expires after 24 hours. For a fresh one:"
            log "  sudo $SETUP_URL_COMMAND --new"
            if [ "$setup_mode" = auto ] && find_desktop_session; then
                open_in_browser "$FIRST_SETUP_URL"
                log "(Opening it in your browser now.)"
            fi
            ;;
        admin-exists)
            log "This server already has an administrator: sign in with that account."
            ;;
        *)
            log "Finish setting up in a browser. Print the single-use setup link with:"
            log "  sudo $SETUP_URL_COMMAND"
            ;;
    esac
    FIRST_SETUP_URL=""
}

finish() {
    lan_ip=$(host_lan_ip)
    hostname_value=""
    if [ "$DRY_RUN" -eq 0 ]; then
        hostname_value=$(env_current_value "$INSTALL_DIR/.env" SLATE_HOSTNAME)
    fi

    printf '\n'
    if [ "$DRY_RUN" -eq 1 ]; then
        log "A real run would end here, with Slate installed and running."
    else
        log "Slate is installed."
    fi
    printf '\n'
    log "Admin panel:"
    if [ -n "$hostname_value" ]; then
        log "  https://$hostname_value/admin"
    fi
    if [ -n "$lan_ip" ]; then
        log "  http://$lan_ip:8080/admin"
    else
        log "  http://<this-host-lan-ip>:8080/admin"
    fi
    printf '\n'
    show_first_setup "$lan_ip"
    printf '\n'
    log "The stack lives in $INSTALL_DIR; re-running this installer is safe - it"
    log "keeps every value already in .env and asks nothing."
    printf '\n'
    # The setup page's second step signs in to the Slate account. The
    # device-link code stays the way to do it later: it is minted by the server
    # only when an admin starts a link and read back through the authenticated
    # admin API, so this names where it appears rather than printing one.
    log "Connect this server to your Slate account in the setup page's second"
    log "step. To do it later instead, sign in to the admin panel and"
    log "  open the Licence tab, click Link to my Slate account, and type the"
    log "  code at $SLATE_PORTAL_LINK_URL"

    if [ "$DRY_RUN" -eq 1 ]; then
        printf '\n'
        log "This was a dry run - nothing was changed."
        if [ "$PREFLIGHT_PROBLEMS" -gt 0 ]; then
            log "$PREFLIGHT_PROBLEMS preflight check(s) would have aborted a real run."
        fi
    fi
}

# ---------------------------------------------------------------------- main

log "Slate server installer"
if [ "$DRY_RUN" -eq 1 ]; then
    log "(dry run - nothing will be changed)"
fi

preflight
ensure_docker
fetch_stack_files
write_env
stack_up
verify_host_network
wait_for_server
finish
