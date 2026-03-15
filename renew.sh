#!/bin/sh
# renew.sh -- Let's Encrypt certificate renewal for Sophos XGS
# Runs as an infinite loop, renewing certificates defined in config.csv daily.

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
CONF=/var/acme
HOME=/var/acme
LOG_FILE=/var/acme/renew.log
LOCK_DIR=/var/acme/renew.lock
HTTP_PORT=8000
SLEEP_INTERVAL=86400

# ---------------------------------------------------------------------------
# Mutable state (tracked for cleanup)
# ---------------------------------------------------------------------------
pythonPid=""
iptablesRuleActive=0
varMountedExec=0
lockAcquired=0

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
# Lock management (mkdir-based, atomic, POSIX-portable)
# ---------------------------------------------------------------------------
acquireLock() {
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        printf '%s\n' $$ > "$LOCK_DIR/pid"
        lockAcquired=1
        log INFO "Lock acquired (PID: $$)"
        return 0
    fi

    # Lock exists -- check if holder is still alive
    if [ -f "$LOCK_DIR/pid" ]; then
        existingPid=$(cat "$LOCK_DIR/pid" 2>/dev/null)
        if [ -n "$existingPid" ] && kill -0 "$existingPid" 2>/dev/null; then
            log ERROR "Another instance is running (PID: $existingPid)"
            return 1
        fi
        # Stale lock from a crashed instance
        log WARN "Removing stale lock (PID: $existingPid)"
        rm -rf "$LOCK_DIR"
        if mkdir "$LOCK_DIR" 2>/dev/null; then
            printf '%s\n' $$ > "$LOCK_DIR/pid"
            lockAcquired=1
            log INFO "Lock acquired after stale removal (PID: $$)"
            return 0
        fi
    fi

    log ERROR "Failed to acquire lock"
    return 1
}

releaseLock() {
    if [ "$lockAcquired" -eq 1 ]; then
        rm -rf "$LOCK_DIR"
        lockAcquired=0
    fi
}

# ---------------------------------------------------------------------------
# Cleanup (idempotent -- safe to call from any state)
# ---------------------------------------------------------------------------
stopHttpServer() {
    if [ -n "$pythonPid" ] && kill -0 "$pythonPid" 2>/dev/null; then
        log INFO "Stopping HTTP server (PID: $pythonPid)"
        kill "$pythonPid" 2>/dev/null
        waitCount=0
        while kill -0 "$pythonPid" 2>/dev/null && [ "$waitCount" -lt 3 ]; do
            sleep 1
            waitCount=$((waitCount + 1))
        done
        if kill -0 "$pythonPid" 2>/dev/null; then
            log WARN "Force-killing HTTP server (PID: $pythonPid)"
            kill -9 "$pythonPid" 2>/dev/null
        fi
    fi
    pythonPid=""
}

removeIptablesRule() {
    if [ "$iptablesRuleActive" -eq 1 ]; then
        iptables -t nat -D PREROUTING -p tcp --dport 80 -j DNAT --to-destination :"$HTTP_PORT" 2>/dev/null
        iptablesRuleActive=0
        log INFO "iptables NAT rule removed"
    fi
}

mountVarNoexec() {
    if [ "$varMountedExec" -eq 1 ]; then
        mount -o "remount,noexec" /var 2>/dev/null
        varMountedExec=0
        log INFO "/var remounted as noexec"
    fi
}

cleanup() {
    log INFO "Cleanup starting"
    stopHttpServer
    removeIptablesRule
    mountVarNoexec
    releaseLock
    log INFO "Cleanup complete"
}

# ---------------------------------------------------------------------------
# Signal handling
# ---------------------------------------------------------------------------
onSignal() {
    log WARN "Signal received, shutting down"
    exit 1
}

trap onSignal INT TERM HUP
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
preflightChecks() {
    checksPassed=0

    if [ ! -x "$HOME/acme.sh" ]; then
        log ERROR "acme.sh not found or not executable at $HOME/acme.sh"
        checksPassed=1
    fi

    if [ ! -r "$CONF/config.csv" ]; then
        log ERROR "config.csv not found at $CONF/config.csv"
        checksPassed=1
    fi

    if [ ! -d "/conf/certificate" ]; then
        log ERROR "Certificate directory /conf/certificate does not exist"
        checksPassed=1
    fi

    if [ ! -d "/conf/certificate/private" ]; then
        log ERROR "Private key directory /conf/certificate/private does not exist"
        checksPassed=1
    fi

    for cmd in python3 iptables mount sed cut tr date; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log ERROR "Required command not found: $cmd"
            checksPassed=1
        fi
    done

    if [ "$(id -u)" -ne 0 ]; then
        log ERROR "Must run as root"
        checksPassed=1
    fi

    return $checksPassed
}

# ---------------------------------------------------------------------------
# Config parsing
# ---------------------------------------------------------------------------
# Sets PARSED_CERT_NAME and PARSED_DOMAINS on success, returns 1 to skip.
parseLine() {
    rawLine=$1

    # Strip DOS carriage return
    rawLine=$(printf '%s' "$rawLine" | tr -d '\r')

    # Skip blank lines
    case "$rawLine" in
        "") return 1 ;;
    esac

    # Skip comment lines (# optionally preceded by whitespace)
    trimmedForComment=$(printf '%s' "$rawLine" | sed 's/^[[:space:]]*//')
    case "$trimmedForComment" in
        "#"*) return 1 ;;
    esac

    # Split on semicolon
    certName=$(printf '%s' "$rawLine" | cut -d';' -f1)
    domainList=$(printf '%s' "$rawLine" | cut -d';' -f2)

    # Trim whitespace
    certName=$(printf '%s' "$certName" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    domainList=$(printf '%s' "$domainList" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    # Remove spaces around commas in domain list
    domainList=$(printf '%s' "$domainList" | sed 's/[[:space:]]*,[[:space:]]*/,/g')

    if [ -z "$certName" ]; then
        log WARN "Empty certificate name, skipping line"
        return 1
    fi

    if [ -z "$domainList" ]; then
        log WARN "No domains for certificate '$certName', skipping"
        return 1
    fi

    PARSED_CERT_NAME="$certName"
    PARSED_DOMAINS="$domainList"
    return 0
}

# ---------------------------------------------------------------------------
# HTTP server management
# ---------------------------------------------------------------------------
startHttpServer() {
    mkdir -p "$HOME/http"
    python3 -m http.server "$HTTP_PORT" -d "$HOME/http" >/dev/null 2>&1 &
    pythonPid=$!
    log INFO "Started HTTP server on port $HTTP_PORT (PID: $pythonPid)"
}

waitForHttpServer() {
    maxWait=10
    waited=0
    while [ "$waited" -lt "$maxWait" ]; do
        if curl -s -o /dev/null "http://127.0.0.1:$HTTP_PORT/" 2>/dev/null; then
            log INFO "HTTP server ready (${waited}s)"
            return 0
        fi
        if ! kill -0 "$pythonPid" 2>/dev/null; then
            log ERROR "HTTP server process died unexpectedly"
            pythonPid=""
            return 1
        fi
        sleep 1
        waited=$((waited + 1))
    done
    log ERROR "HTTP server not ready after ${maxWait}s"
    return 1
}

# ---------------------------------------------------------------------------
# iptables management
# ---------------------------------------------------------------------------
addIptablesRule() {
    # Defensively remove any stale rule from a previous crash
    iptables -t nat -D PREROUTING -p tcp --dport 80 -j DNAT --to-destination :"$HTTP_PORT" 2>/dev/null

    if iptables -t nat -A PREROUTING -p tcp --dport 80 -j DNAT --to-destination :"$HTTP_PORT"; then
        iptablesRuleActive=1
        log INFO "iptables NAT rule added (80 -> $HTTP_PORT)"
        return 0
    else
        log ERROR "Failed to add iptables NAT rule"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Mount management
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

# ---------------------------------------------------------------------------
# Per-certificate renewal
# ---------------------------------------------------------------------------
renewCertificate() {
    certName=$1
    domains=$2

    log INFO "--- Processing certificate: $certName ---"
    log INFO "Domains: $domains"

    # Step 1-2: Start HTTP server and wait for it
    startHttpServer
    if ! waitForHttpServer; then
        log ERROR "Aborting $certName: HTTP server failed"
        stopHttpServer
        return 1
    fi

    # Step 3: Add iptables rule
    if ! addIptablesRule; then
        log ERROR "Aborting $certName: iptables rule failed"
        stopHttpServer
        return 1
    fi

    # Step 4: Remount /var as exec
    if ! mountVarExec; then
        log ERROR "Aborting $certName: mount failed"
        removeIptablesRule
        stopHttpServer
        return 1
    fi

    # Step 5: Run acme.sh
    certificateNames=$(printf '%s' "$domains" | sed 's/,/ -d /g')

    log INFO "Running acme.sh for $certName"
    # shellcheck disable=SC2086
    # certificateNames is intentionally unquoted to expand into multiple -d arguments
    "$HOME/acme.sh" \
        --config-home "$CONF" \
        -w "$HOME/http/" --issue --server letsencrypt \
        --reloadcmd "killall -SIGHUP httpd" \
        --cert-file      "/conf/certificate/${certName}.pem" \
        --key-file       "/conf/certificate/private/${certName}.key" \
        -d $certificateNames
    acmeExit=$?

    if [ "$acmeExit" -eq 0 ]; then
        log INFO "Certificate issued/renewed successfully: $certName"
    elif [ "$acmeExit" -eq 2 ]; then
        log INFO "Certificate not due for renewal: $certName"
    else
        log ERROR "acme.sh failed for $certName (exit: $acmeExit)"
    fi

    # Step 6-8: Cleanup (always, regardless of acme.sh result)
    mountVarNoexec
    removeIptablesRule
    stopHttpServer

    # Step 9: Reload httpd
    killall -SIGHUP httpd 2>/dev/null
    log INFO "httpd reloaded"

    log INFO "--- Finished certificate: $certName ---"
    return 0
}

# ---------------------------------------------------------------------------
# Signal-aware sleep (interruptible by trap)
# ---------------------------------------------------------------------------
signalAwareSleep() {
    duration=$1
    log INFO "Sleeping ${duration}s until next cycle"
    sleep "$duration" &
    sleepPid=$!
    wait "$sleepPid" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    log INFO "=== renew.sh starting (PID: $$) ==="

    if ! preflightChecks; then
        log ERROR "Pre-flight checks failed, exiting"
        exit 1
    fi

    if ! acquireLock; then
        exit 1
    fi

    while :; do
        log INFO "=== Starting renewal cycle ==="

        while IFS= read -r rawLine || [ -n "$rawLine" ]; do
            if ! parseLine "$rawLine"; then
                continue
            fi
            renewCertificate "$PARSED_CERT_NAME" "$PARSED_DOMAINS"
        done < "$CONF/config.csv"

        log INFO "=== Renewal cycle complete ==="
        signalAwareSleep "$SLEEP_INTERVAL"
    done
}

main
