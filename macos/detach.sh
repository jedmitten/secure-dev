#!/usr/bin/env bash
# detach.sh — Detach the encrypted APFS container
# Called by: screen lock agent, sleep agent, idle agent, manual shortcut
#
# Usage:
#   detach.sh --trigger <screenlock|sleep|idle|manual> [--check-idle]
#
# --check-idle: before detaching, verify idle threshold has been exceeded.
#               Used by the idle launchd agent so it only acts when truly idle.
set -euo pipefail

# ── Colours ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[info]${NC}  $*"; }
success() { echo -e "${GREEN}[ok]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[warn]${NC}  $*"; }
die()     { echo -e "${RED}[error]${NC} $*" >&2; exit 1; }

# ── Args ───────────────────────────────────────────────────────────────────────
TRIGGER="manual"
CHECK_IDLE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --trigger)    TRIGGER="$2"; shift 2 ;;
        --check-idle) CHECK_IDLE=true; shift ;;
        *) shift ;;
    esac
done

# ── Config ─────────────────────────────────────────────────────────────────────
CONFIG_FILE="$HOME/.config/secure-dev/config.toml"
[[ -f "$CONFIG_FILE" ]] || exit 0   # silent exit if not configured (e.g. during setup)

read_toml() {
    local file="$1" section="$2" key="$3"
    awk -F'=' -v sec="[$section]" -v k="$key" '
        /^\[/ { in_sec = ($0 == sec) }
        in_sec && $1 ~ "^[[:space:]]*"k"[[:space:]]*$" {
            gsub(/^[[:space:]]*|[[:space:]]*$/, "", $2)
            gsub(/^"|"$/, "", $2)
            print $2; exit
        }
    ' "$file"
}

VOLUME_PATH=$(read_toml "$CONFIG_FILE" container volume_path)
IDLE_TIMEOUT_MIN=$(read_toml "$CONFIG_FILE" idle timeout_minutes)
LOG=$(eval echo "$(read_toml "$CONFIG_FILE" logging detach_log)")
MOUNT_TS_FILE="$HOME/.config/secure-dev/last_mount"

mkdir -p "$(dirname "$LOG")"

# ── Idle check ─────────────────────────────────────────────────────────────────
# The idle launchd agent fires on an interval. We re-check actual idle time
# here to avoid detaching during active use if the interval fires late.
if $CHECK_IDLE; then
    IDLE_THRESHOLD_SEC=$(( IDLE_TIMEOUT_MIN * 60 ))

    # System HID idle time (nanoseconds → seconds)
    HID_IDLE_NS=$(ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print $NF; exit}')
    HID_IDLE_SEC=$(( HID_IDLE_NS / 1000000000 ))

    if (( HID_IDLE_SEC < IDLE_THRESHOLD_SEC )); then
        # Not idle enough — also reset our mount timestamp to avoid false triggers
        exit 0
    fi

    # Secondary check: if mount timestamp is recent (user may have just mounted),
    # give a grace period of 2 minutes regardless of HID idle.
    if [[ -f "$MOUNT_TS_FILE" ]]; then
        MOUNT_TS=$(cat "$MOUNT_TS_FILE")
        NOW=$(date +%s)
        SINCE_MOUNT=$(( NOW - MOUNT_TS ))
        GRACE=120  # 2 minutes
        if (( SINCE_MOUNT < GRACE )); then
            exit 0
        fi
    fi
fi

# ── Is the volume mounted? ────────────────────────────────────────────────────
if ! mount | grep -q "$VOLUME_PATH"; then
    # Volume not mounted — nothing to do. Silent exit so agents don't spam logs.
    exit 0
fi

# ── Deactivate any active venv (best-effort) ─────────────────────────────────
# This script runs in its own subshell, so it cannot deactivate the user's
# interactive shell venv. We clear the marker file used by mount-secure.sh
# and emit a warning that the user should deactivate manually.
VENV_HINT_FILE="$HOME/.config/secure-dev/active_venv"
if [[ -f "$VENV_HINT_FILE" ]]; then
    warn "Active venv detected — run 'deactivate' in your terminal before processes fail."
    rm -f "$VENV_HINT_FILE"
fi

# Kill any processes with open files on the volume (prevents hdiutil busy error)
info "Checking for open files on $VOLUME_PATH…"
PIDS=$(lsof +D "$VOLUME_PATH" 2>/dev/null | awk 'NR>1 {print $2}' | sort -u || true)
if [[ -n "$PIDS" ]]; then
    warn "Processes with open files: $PIDS — sending SIGTERM…"
    echo "$PIDS" | xargs kill -TERM 2>/dev/null || true
    sleep 1
fi

# ── Detach ─────────────────────────────────────────────────────────────────────
info "Detaching $VOLUME_PATH (trigger: $TRIGGER)…"

# Try clean detach first
if hdiutil detach "$VOLUME_PATH" 2>/dev/null; then
    success "Detached cleanly"
else
    warn "Clean detach failed — forcing…"
    hdiutil detach "$VOLUME_PATH" -force 2>/dev/null \
        || die "Forced detach failed. Unmount manually: hdiutil detach $VOLUME_PATH -force"
    success "Force-detached"
fi

# ── Log ───────────────────────────────────────────────────────────────────────
echo "$(date '+%Y-%m-%d %H:%M:%S') DETACHED $VOLUME_PATH trigger=$TRIGGER" >> "$LOG"

# ── Notify (triggers from agents run in background — surface to user) ─────────
if [[ "$TRIGGER" != "manual" ]]; then
    # osascript notification so user knows it happened
    osascript -e "display notification \"Secure volume locked (${TRIGGER})\" \
        with title \"Secure Dev\" subtitle \"$VOLUME_PATH detached\"" 2>/dev/null || true
fi

success "Volume encrypted and inaccessible."