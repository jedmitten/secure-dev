#!/usr/bin/env bash
# mount-secure.sh — Mount the encrypted APFS container
#
# Detects which YubiKey is present, uses that key's salt and Keychain entry
# to unwrap the container password. Each key works identically and independently.
# Falls back to Bitwarden if no key is present or unwrap fails.
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
YK_SLOT=$(read_toml "$CONFIG_FILE" security yubikey_slot)
SALT_DIR=$(eval echo "$(dirname "$(read_toml "$CONFIG_FILE" security hmac_salt_path)")")
PREFERRED_SERIAL=$(read_toml "$CONFIG_FILE" security preferred_serial)
BW_ITEM=$(read_toml "$CONFIG_FILE" security bitwarden_item_name)
LOG=$(eval echo "$(read_toml "$CONFIG_FILE" logging detach_log)")

# ── Preflight ──────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}Secure Dev -- Mount${NC}\n"

[[ -e "$SB_PATH" ]] || die "Sparsebundle not found at $SB_PATH. Run create-container.sh first."

# Idempotent -- already mounted?
if mount | grep -q "$VOLUME_PATH"; then
    success "Volume already mounted at $VOLUME_PATH"
    echo "  cd $VOLUME_PATH/repos"
    exit 0
fi

# ── Attempt YubiKey unlock ────────────────────────────────────────────────────
# Detect which key is plugged in, try its salt + Keychain entry.
APFS_PASSWORD=""

try_yubikey_unlock() {
    local serial="$1"
    local salt_path="$SALT_DIR/hmac.salt.$serial"
    local kc_account="apfs-password-$serial"

    [[ -f "$salt_path" ]] || { warn "No salt file for key $serial ($salt_path). Key may not be enrolled." >&2; return 1; }

    local salt hmac wrapped password
    salt=$(cat "$salt_path")

    info "Touch YubiKey $serial when it flashes..." >&2
    hmac=$(ykman --device "$serial" otp calculate "$YK_SLOT" "$salt" 2>/dev/null) || return 1

    wrapped=$(security find-generic-password \
        -s "$KC_SERVICE" -a "$kc_account" -w 2>/dev/null) || return 1

    password=$(WRAPPED="$wrapped" HMAC="$hmac" python3 -c "
import base64, os
wrapped = base64.b64decode(os.environ['WRAPPED'])
key     = os.environ['HMAC'].encode()
out     = bytes(wrapped[i] ^ key[i % len(key)] for i in range(len(wrapped)))
print(out.decode())
") || return 1

    echo "$password"
}

# Try each detected YubiKey — preferred key first
YK_SERIALS=()
while IFS= read -r line; do
    [[ -n "$line" ]] && YK_SERIALS+=("$line")
done < <(ykman list --serials 2>/dev/null)

# Move preferred serial to front if present
if [[ -n "${PREFERRED_SERIAL:-}" ]]; then
    ORDERED=()
    for s in "${YK_SERIALS[@]}"; do [[ "$s" == "$PREFERRED_SERIAL" ]] && ORDERED+=("$s"); done
    for s in "${YK_SERIALS[@]}"; do [[ "$s" != "$PREFERRED_SERIAL" ]] && ORDERED+=("$s"); done
    YK_SERIALS=("${ORDERED[@]}")
    unset ORDERED
fi

for serial in "${YK_SERIALS[@]}"; do
    APFS_PASSWORD=$(try_yubikey_unlock "$serial" 2>/dev/null) && break || true
done

# ── Bitwarden fallback ────────────────────────────────────────────────────────
if [[ -z "$APFS_PASSWORD" ]]; then
    warn "YubiKey unlock failed or no key present -- falling back to Bitwarden..."
    local_status=$(bw status 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','locked'))" 2>/dev/null || echo "locked")
    if [[ "$local_status" != "unlocked" ]]; then
        info "Unlocking Bitwarden vault..."
        export BW_SESSION
        BW_SESSION=$(bw unlock --raw)
    fi
    APFS_PASSWORD=$(bw get password "$BW_ITEM" 2>/dev/null) \
        || die "Could not retrieve password from Bitwarden."
fi

[[ -n "$APFS_PASSWORD" ]] || die "Failed to retrieve container password."

# ── Mount ──────────────────────────────────────────────────────────────────────
info "Mounting $SB_PATH..."
printf '%s' "$APFS_PASSWORD" | hdiutil attach "$SB_PATH" \
    -mountpoint "$VOLUME_PATH" \
    -stdinpass \
    -nobrowse

unset APFS_PASSWORD
success "Mounted at $VOLUME_PATH"

# ── Reset idle timestamp ───────────────────────────────────────────────────────
date +%s > "$HOME/.config/secure-dev/last_mount"

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