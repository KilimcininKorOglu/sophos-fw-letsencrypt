#!/bin/sh
# setup.sh -- One-time installer for sophos-fw-letsencrypt
# Downloads acme.sh, registers a Let's Encrypt account, and installs
# the boot service at /etc/rc.d/S01lets.
# Safe to re-run: idempotent for all operations.

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
VERSION="1.0.0"
REPO_OWNER="KilimcininKorOglu"
REPO_NAME="sophos-fw-letsencrypt"
REPO_BRANCH="main"
BASE_URL="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_BRANCH}"

ACME_URL="https://raw.githubusercontent.com/acmesh-official/acme.sh/master/acme.sh"

HOME=/var/acme
CONF=/var/acme
LOG_FILE=/var/acme/setup.log
BOOT_SERVICE_PATH="/etc/rc.d/S01lets"
ACCOUNT_DIR="/var/acme/ca/acme-v02.api.letsencrypt.org/directory"

# ---------------------------------------------------------------------------
# Mutable state (tracked for cleanup)
# ---------------------------------------------------------------------------
varMountedExec=0
rootMountedRw=0

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log() {
    logLevel=$1
    shift
    logTimestamp=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date '+%F %T')
    logLine="[$logTimestamp] [$logLevel] $*"
    printf '%s\n' "$logLine"
    printf '%s\n' "$logLine" >> "$LOG_FILE" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Mount management (state-tracked)
# ---------------------------------------------------------------------------
mountVarExec() {
    if mount -o "remount,exec" /var; then
        varMountedExec=1
        log INFO "/var remounted as exec"
        return 0
    else
        log ERROR "Failed to remount /var as exec"
        return 1
    fi
}

mountVarNoexec() {
    if [ "$varMountedExec" -eq 1 ]; then
        if mount -o "remount,noexec" /var 2>/dev/null; then
            varMountedExec=0
            log INFO "/var remounted as noexec"
        else
            log ERROR "Failed to remount /var as noexec"
        fi
    fi
}

mountRootRw() {
    if mount -o "remount,rw" /; then
        rootMountedRw=1
        log INFO "/ remounted as read-write"
        return 0
    else
        log ERROR "Failed to remount / as read-write"
        return 1
    fi
}

mountRootRo() {
    if [ "$rootMountedRw" -eq 1 ]; then
        if mount -o "remount,ro" / 2>/dev/null; then
            rootMountedRw=0
            log INFO "/ remounted as read-only"
        else
            log ERROR "Failed to remount / as read-only"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Cleanup (idempotent -- safe to call from any state)
# ---------------------------------------------------------------------------
cleanup() {
    log INFO "Cleanup starting"
    mountVarNoexec
    mountRootRo
    log INFO "Cleanup complete"
}

# ---------------------------------------------------------------------------
# Signal handling
# ---------------------------------------------------------------------------
onSignal() {
    log WARN "Signal received, aborting setup"
    exit 1
}

trap onSignal INT TERM HUP
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
preflightChecks() {
    checksPassed=0

    if [ "$(id -u)" -ne 0 ]; then
        log ERROR "Must run as root"
        checksPassed=1
    fi

    for cmd in curl mount chmod mkdir date id; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log ERROR "Required command not found: $cmd"
            checksPassed=1
        fi
    done

    if [ "$checksPassed" -eq 0 ]; then
        if ! curl -sf --max-time 10 -o /dev/null "https://raw.githubusercontent.com/"; then
            log ERROR "Cannot reach raw.githubusercontent.com (network or DNS issue)"
            checksPassed=1
        fi
    fi

    return $checksPassed
}

# ---------------------------------------------------------------------------
# Download helper (DRY)
# ---------------------------------------------------------------------------
downloadFile() {
    dlUrl=$1
    dlDest=$2
    dlDescription=$3

    log INFO "Downloading $dlDescription"
    if curl -fSs --max-time 60 "$dlUrl" -o "$dlDest"; then
        chmod +x "$dlDest"
        log INFO "Downloaded $dlDescription -> $dlDest"
        return 0
    else
        log ERROR "Failed to download $dlDescription from $dlUrl"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Email validation (POSIX glob, no regex)
# ---------------------------------------------------------------------------
validateEmail() {
    valEmail=$1

    if [ -z "$valEmail" ]; then
        log ERROR "Email address cannot be empty"
        return 1
    fi

    case "$valEmail" in
        *@*.*)
            return 0
            ;;
        *)
            log ERROR "Invalid email format: $valEmail (expected user@domain.tld)"
            return 1
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Account registration (conditional)
# ---------------------------------------------------------------------------
registerAccount() {
    if [ -e "$ACCOUNT_DIR/account.json" ]; then
        log INFO "Account already registered ($ACCOUNT_DIR exists)"
        return 0
    fi

    printf 'Please enter your Let'\''s Encrypt account email: '
    read -r email

    if ! validateEmail "$email"; then
        return 1
    fi

    log INFO "Registering Let's Encrypt account with email: $email"
    if "$HOME/acme.sh" --config-home "$CONF" --register-account -m "$email" --server letsencrypt; then
        log INFO "Account registered successfully"
        return 0
    else
        log ERROR "Account registration failed"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Boot service installation (narrow rw window)
# ---------------------------------------------------------------------------
installBootService() {
    log INFO "Installing boot service"

    if ! mountRootRw; then
        return 1
    fi

    if ! downloadFile "${BASE_URL}/S01lets" "$BOOT_SERVICE_PATH" "S01lets boot service"; then
        mountRootRo
        return 1
    fi

    mountRootRo
    log INFO "Boot service installed at $BOOT_SERVICE_PATH"
    return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    log INFO "=== setup.sh v${VERSION} starting (PID: $$) ==="

    if ! preflightChecks; then
        log ERROR "Pre-flight checks failed, exiting"
        exit 1
    fi

    # Phase 1: Prepare /var (exec mount needed for acme.sh)
    if ! mountVarExec; then
        exit 1
    fi

    mkdir -p "$HOME/http"
    log INFO "Ensured directories: $HOME, $HOME/http"

    # Phase 2: Download dependencies
    downloadFile "$ACME_URL" "$HOME/acme.sh" "acme.sh" || exit 1
    downloadFile "${BASE_URL}/renew.sh" "$HOME/renew.sh" "renew.sh" || exit 1
    downloadFile "${BASE_URL}/setup.sh" "$HOME/setup.sh" "setup.sh" || exit 1

    if [ -e "$CONF/config.csv" ]; then
        log INFO "config.csv already exists, skipping download"
    else
        downloadFile "${BASE_URL}/config.csv" "$CONF/config.csv" "config.csv" || exit 1
    fi

    # Phase 3: Account registration (needs /var exec for acme.sh)
    if ! registerAccount; then
        exit 1
    fi

    # Phase 4: Restore /var to noexec
    mountVarNoexec

    # Phase 5: Install boot service (needs / rw, narrow window)
    if ! installBootService; then
        exit 1
    fi

    log INFO "=== Installed sophos-fw-letsencrypt ==="
}

main
