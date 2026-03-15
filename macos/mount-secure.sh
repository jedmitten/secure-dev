#!/usr/bin/env bash
# mount-secure.sh — Mount the encrypted APFS container
# Retrieves password via HMAC-unwrap from Keychain + YubiKey touch.
# Falls back to Bitwarden if Keychain cache is stale or missing.
set -euo pipefail

# ── Colours ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[info]${NC}  $*"; }
success() { echo -e "${GREEN}[ok]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[warn]${NC}  $*"; }
die()     { echo -e "${RED}[error]${NC} $*" >&2; exit 1; }

# ── Config ─────────────────────────────────────────────────────────────────────
CONFIG_FILE="$HOME/.config/secure-dev/config.toml"
[[ -f "$CONFIG_FILE" ]] || die "config.toml not found. Run install.sh first."

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

SB_PATH=$(eval echo "$(read_toml "$CONFIG_FILE" container path)")
VOLUME_PATH=$(read_toml "$CONFIG_FILE" container volume_path)
KC_SERVICE=$(read_toml "$CONFIG_FILE" security keychain_service)
KC_ACCOUNT=$(read_toml "$CONFIG_FILE" security keychain_account)
YK_SLOT=$(read_toml "$CONFIG_FILE" security yubikey_slot)
SALT_PATH=$(eval echo "$(read_toml "$CONFIG_FILE" security hmac_salt_path)")
BW_ITEM=$(read_toml "$CONFIG_FILE" security bitwarden_item_name)
LOG=$(eval echo "$(read_toml "$CONFIG_FILE" logging detach_log)")

# ── Preflight ──────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}Secure Dev — Mount${NC}\n"

[[ -e "$SB_PATH" ]] || die "Sparsebundle not found at $SB_PATH. Run create-container.sh first."

# Idempotent — already mounted?
if mount | grep -q "$VOLUME_PATH"; then
    success "Volume already mounted at $VOLUME_PATH"
    echo "  cd $VOLUME_PATH/repos"
    exit 0
fi

# ── Retrieve password via HMAC-unwrap ─────────────────────────────────────────
get_password_from_keychain() {
    local wrapped hmac_salt hmac_output password

    # 1. Verify YubiKey present
    ykman info &>/dev/null || return 1

    # 2. Read HMAC salt
    [[ -f "$SALT_PATH" ]] || return 1
    hmac_salt=$(cat "$SALT_PATH")

    # 3. Derive HMAC from YubiKey (touch required)
    info "Touch YubiKey to unlock…"
    hmac_output=$(ykman otp calculate "$YK_SLOT" "$hmac_salt" 2>/dev/null) || return 1

    # 4. Read wrapped password from Keychain
    wrapped=$(security find-generic-password \
        -s "$KC_SERVICE" -a "$KC_ACCOUNT" -w 2>/dev/null) || return 1

    # 5. Unwrap: reverse the XOR applied in create-container.sh
    password=$(python3 -c "
import sys, base64
wrapped = base64.b64decode('$wrapped')
key     = b'$hmac_output'
out     = bytes(wrapped[i] ^ key[i % len(key)] for i in range(len(wrapped)))
print(out.decode())
")
    echo "$password"
}

get_password_from_bitwarden() {
    info "Falling back to Bitwarden…"

    # Ensure vault is unlocked
    local status
    status=$(bw status 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','locked'))" 2>/dev/null || echo "locked")

    if [[ "$status" != "unlocked" ]]; then
        info "Unlocking Bitwarden vault (YubiKey FIDO2 will be prompted)…"
        export BW_SESSION
        BW_SESSION=$(bw unlock --raw)
    fi

    bw get password "$BW_ITEM" 2>/dev/null
}

# ── Attempt Keychain path first ───────────────────────────────────────────────
APFS_PASSWORD=""

if command -v ykman &>/dev/null && [[ -f "$SALT_PATH" ]]; then
    APFS_PASSWORD=$(get_password_from_keychain 2>/dev/null) || true
fi

if [[ -z "$APFS_PASSWORD" ]]; then
    warn "Keychain path failed or YubiKey not present — trying Bitwarden…"
    APFS_PASSWORD=$(get_password_from_bitwarden) || die "Could not retrieve password from Bitwarden."

    # Opportunistically re-cache in Keychain if YubiKey now available
    if command -v ykman &>/dev/null && ykman info &>/dev/null 2>&1; then
        info "YubiKey now present — refreshing Keychain cache…"
        if [[ -f "$SALT_PATH" ]]; then
            HMAC_SALT=$(cat "$SALT_PATH")
            HMAC_OUT=$(ykman otp calculate "$YK_SLOT" "$HMAC_SALT" 2>/dev/null) || true
            if [[ -n "$HMAC_OUT" ]]; then
                WRAPPED=$(python3 -c "
import base64
pw  = b'$APFS_PASSWORD'
key = b'$HMAC_OUT'
out = bytes(pw[i] ^ key[i % len(key)] for i in range(len(pw)))
print(base64.b64encode(out).decode())
")
                security delete-generic-password -s "$KC_SERVICE" -a "$KC_ACCOUNT" 2>/dev/null || true
                security add-generic-password -s "$KC_SERVICE" -a "$KC_ACCOUNT" -w "$WRAPPED" -T ""
                success "Keychain cache refreshed"
                unset HMAC_OUT WRAPPED
            fi
        fi
    fi
fi

[[ -n "$APFS_PASSWORD" ]] || die "Failed to retrieve APFS password."

# ── Mount ──────────────────────────────────────────────────────────────────────
info "Mounting $SB_PATH…"
echo "$APFS_PASSWORD" | hdiutil attach "$SB_PATH" \
    -mountpoint "$VOLUME_PATH" \
    -stdinpass \
    -nobrowse          # hide from Finder sidebar for lower profile

unset APFS_PASSWORD
success "Mounted at $VOLUME_PATH"

# ── Reset idle timestamp ───────────────────────────────────────────────────────
MOUNT_TS_FILE="$HOME/.config/secure-dev/last_mount"
date +%s > "$MOUNT_TS_FILE"

# ── Log ───────────────────────────────────────────────────────────────────────
mkdir -p "$(dirname "$LOG")"
echo "$(date '+%Y-%m-%d %H:%M:%S') MOUNTED  $VOLUME_PATH" >> "$LOG"

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "  ${GREEN}Ready.${NC} Start your session:"
echo ""
echo "  cd $VOLUME_PATH/repos/<project>"
echo "  source .venv/bin/activate"
echo ""