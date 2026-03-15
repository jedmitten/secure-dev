#!/usr/bin/env bash
# create-container.sh — One-time encrypted APFS sparsebundle creation
#
# Each YubiKey is enrolled independently and symmetrically:
#   - Its own salt file:      hmac.salt.<serial>
#   - Its own Keychain entry: <service> / apfs-password-<serial>
#   - Both wrap the same container password
#   - Either key unlocks the container identically
#
# Run with one or both keys plugged in. Each detected key is enrolled.
# To add a key later, run enroll-yubikeys.sh with the new key plugged in.
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

VOLUME_NAME=$(read_toml "$CONFIG_FILE" container name)
SB_PATH=$(eval echo "$(read_toml "$CONFIG_FILE" container path)")
VOLUME_PATH=$(read_toml "$CONFIG_FILE" container volume_path)
SIZE=$(read_toml "$CONFIG_FILE" container size)
KC_SERVICE=$(read_toml "$CONFIG_FILE" security keychain_service)
YK_SLOT=$(read_toml "$CONFIG_FILE" security yubikey_slot)
SALT_DIR=$(eval echo "$(dirname "$(read_toml "$CONFIG_FILE" security hmac_salt_path)")")
BW_ITEM=$(read_toml "$CONFIG_FILE" security bitwarden_item_name)

# ── Preflight ──────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}Secure Dev -- Container Creation${NC}\n"

[[ -e "$SB_PATH" ]] && die "Container already exists at $SB_PATH. Aborting to avoid data loss."
command -v ykman   &>/dev/null || die "ykman not found. Run install.sh first."
command -v hdiutil &>/dev/null || die "hdiutil not found (not macOS?)."
command -v python3 &>/dev/null || die "python3 not found."

# ── Enumerate connected YubiKeys ──────────────────────────────────────────────
YK_SERIALS=()
while IFS= read -r line; do
    [[ -n "$line" ]] && YK_SERIALS+=("$line")
done < <(ykman list --serials 2>/dev/null)
YK_COUNT=${#YK_SERIALS[@]}

[[ $YK_COUNT -eq 0 ]] && die "No YubiKeys detected. Insert at least one YubiKey and retry."
info "Found $YK_COUNT YubiKey(s): ${YK_SERIALS[*]}"

# ── Program each YubiKey independently ───────────────────────────────────────
# Each key gets its own random HMAC secret programmed into slot $YK_SLOT.
# Keys are NOT cross-enrolled -- each is fully independent.
program_yubikey() {
    local serial="$1"
    info "Programming YubiKey $serial..."

    local slot_info slot_line
    slot_info=$(ykman --device "$serial" otp info 2>/dev/null || true)
    slot_line=$(echo "$slot_info" | grep -i "Slot $YK_SLOT" || true)

    if echo "$slot_line" | grep -qi "programmed"; then
        warn "YubiKey $serial slot $YK_SLOT is already programmed."
        warn "Continuing will OVERWRITE the existing slot $YK_SLOT configuration."
        echo ""
        read -rp "  Type 'overwrite' to confirm for key $serial, or Ctrl-C to abort: " CONFIRM
        [[ "$CONFIRM" == "overwrite" ]] || die "Aborted. Slot $YK_SLOT on key $serial not modified."
    else
        info "YubiKey $serial slot $YK_SLOT is empty -- safe to program."
    fi

    local secret
    secret=$(openssl rand -hex 20)
    ykman --device "$serial" otp chalresp --force "$YK_SLOT" "$secret" \
        || die "Failed to program slot $YK_SLOT on YubiKey $serial."
    secret="0000000000000000000000000000000000000000"
    unset secret
    success "YubiKey $serial programmed (slot: $YK_SLOT)"
}

for serial in "${YK_SERIALS[@]}"; do
    program_yubikey "$serial"
done

# ── Generate container password ───────────────────────────────────────────────
info "Generating strong container password..."
APFS_PASSWORD=$(openssl rand -base64 32 | tr -d '\n/+=' | head -c 40)
success "Password generated (40-char alphanumeric)"

# ── For each key: generate salt, derive HMAC, wrap password, store in Keychain ─
mkdir -p "$SALT_DIR"

wrap_key() {
    local serial="$1"
    local salt_path="$SALT_DIR/hmac.salt.$serial"
    local kc_account="apfs-password-$serial"

    info "Enrolling YubiKey $serial..."

    # Generate a unique salt for this key
    openssl rand -hex 32 > "$salt_path"
    chmod 600 "$salt_path"
    local salt
    salt=$(cat "$salt_path")

    # Derive HMAC from this key
    info "Touch YubiKey $serial when it flashes..."
    local hmac
    hmac=$(ykman --device "$serial" otp calculate "$YK_SLOT" "$salt" 2>/dev/null) \
        || die "HMAC derivation failed for YubiKey $serial."

    # XOR-wrap the container password under this key's HMAC
    local wrapped
    wrapped=$(APFS_PASSWORD="$APFS_PASSWORD" HMAC="$hmac" python3 -c "
import base64, os
pw  = os.environ['APFS_PASSWORD'].encode()
key = os.environ['HMAC'].encode()
out = bytes(pw[i] ^ key[i % len(key)] for i in range(len(pw)))
print(base64.b64encode(out).decode())
")

    # Store in Keychain under a key-specific account name
    security delete-generic-password -s "$KC_SERVICE" -a "$kc_account" 2>/dev/null || true
    security add-generic-password \
        -s "$KC_SERVICE" \
        -a "$kc_account" \
        -w "$wrapped" \
        -T "" \
        || die "Failed to store wrapped password in Keychain for key $serial."

    success "YubiKey $serial enrolled (salt: $salt_path, keychain: $KC_SERVICE / $kc_account)"
    unset hmac wrapped salt
}

for serial in "${YK_SERIALS[@]}"; do
    wrap_key "$serial"
done

# ── Show password — always, unconditionally ───────────────────────────────────
# Save this to Bitwarden manually as break-glass. Bitwarden CLI is attempted
# silently below but its failure never blocks container creation.
echo ""
echo -e "  ${BOLD}Container password (save this to Bitwarden as '$BW_ITEM'):${NC}"
echo ""
echo -e "  ${RED}${BOLD}$APFS_PASSWORD${NC}"
echo ""
warn "This is the ONLY time this password will be shown in plaintext."
read -rp "  Press ENTER after saving it securely..."
echo ""

# ── Bitwarden break-glass backup (best-effort, never fatal) ──────────────────
if bw status 2>/dev/null | grep -q '"status":"unlocked"'; then
    BW_ITEM_JSON=$(bw get template item.login 2>/dev/null | jq \
        --arg name "$BW_ITEM" \
        --arg pw "$APFS_PASSWORD" \
        --arg serials "${YK_SERIALS[*]}" \
        '.name = $name | .login.password = $pw | .notes = ("BREAK-GLASS ONLY\nYubiKey serials: " + $serials)' \
        2>/dev/null) || true
    if [[ -n "${BW_ITEM_JSON:-}" ]]; then
        echo "$BW_ITEM_JSON" | bw encode 2>/dev/null | bw create item 2>/dev/null >/dev/null \
            && success "Password also saved to Bitwarden item: $BW_ITEM" \
            || warn "Bitwarden save failed -- add manually."
    else
        warn "Bitwarden template fetch failed -- add password manually."
    fi
else
    warn "Bitwarden not unlocked -- add password manually."
fi

# ── Create sparsebundle ──────────────────────────────────────────────────────
info "Creating encrypted APFS sparsebundle (${SIZE})..."
echo ""
read -rsp "  Container password (paste from notes/Bitwarden): " APFS_PASSWORD_CONFIRM
echo ""

hdiutil create \
    -size "$SIZE" \
    -type SPARSEBUNDLE \
    -fs APFS \
    -volname "$VOLUME_NAME" \
    -encryption AES-256 \
    -stdinpass \
    "$SB_PATH" <<< "$APFS_PASSWORD_CONFIRM"

success "Sparsebundle created at $SB_PATH"

# ── Initial mount and directory scaffold ──────────────────────────────────────
info "Mounting for initial directory setup..."
hdiutil attach "$SB_PATH" -mountpoint "$VOLUME_PATH" -stdinpass <<< "$APFS_PASSWORD_CONFIRM"
unset APFS_PASSWORD_CONFIRM APFS_PASSWORD

mkdir -p "$VOLUME_PATH/repos"
mkdir -p "$VOLUME_PATH/data"
success "Directory structure created inside volume"

hdiutil detach "$VOLUME_PATH"
success "Volume detached -- encryption active"

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}Container creation complete.${NC}"
echo ""
echo "  Sparsebundle : $SB_PATH"
echo "  YubiKey(s)   : ${YK_SERIALS[*]} (slot $YK_SLOT)"
echo "  Salt dir     : $SALT_DIR"
echo "  Keychain     : $KC_SERVICE / apfs-password-<serial>"
echo "  Bitwarden    : $BW_ITEM (break-glass only)"
echo ""
echo "  Each key is fully independent -- either unlocks the container."
echo "  To enroll an additional key later: enroll-yubikeys.sh"
echo "  Back up $SB_PATH to an external encrypted drive."
echo "  Start working: mount-secure.sh"
echo ""