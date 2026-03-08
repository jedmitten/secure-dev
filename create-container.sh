#!/usr/bin/env bash
# create-container.sh — One-time encrypted APFS sparsebundle creation
# Registers HMAC-Secret on YubiKey, stores wrapped password in Keychain,
# and backs the plain password to Bitwarden.
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
KC_ACCOUNT=$(read_toml "$CONFIG_FILE" security keychain_account)
YK_SLOT=$(read_toml "$CONFIG_FILE" security yubikey_slot)
SALT_PATH=$(eval echo "$(read_toml "$CONFIG_FILE" security hmac_salt_path)")
BW_ITEM=$(read_toml "$CONFIG_FILE" security bitwarden_item_name)

# ── Preflight ──────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}Secure Dev — Container Creation${NC}\n"

[[ -f "$SB_PATH" ]] && die "Container already exists at $SB_PATH. Aborting to avoid data loss."
command -v ykman   &>/dev/null || die "ykman not found. Run install.sh first."
command -v bw      &>/dev/null || die "Bitwarden CLI not found. Run install.sh first."
command -v hdiutil &>/dev/null || die "hdiutil not found (not macOS?)."

# Verify YubiKey present
ykman info &>/dev/null || die "YubiKey not detected. Insert your YubiKey and retry."
YK_SERIAL=$(ykman info | awk '/Serial/ {print $NF}')
info "YubiKey detected — serial: $YK_SERIAL"

# ── Step 1: Generate APFS password ───────────────────────────────────────────
info "Generating strong APFS container password…"
APFS_PASSWORD=$(openssl rand -base64 32 | tr -d '\n/+=' | head -c 40)
success "Password generated (40-char alphanumeric)"

# ── Step 2: Generate and store HMAC salt ──────────────────────────────────────
info "Generating HMAC salt…"
mkdir -p "$(dirname "$SALT_PATH")"
openssl rand -hex 32 > "$SALT_PATH"
chmod 600 "$SALT_PATH"
HMAC_SALT=$(cat "$SALT_PATH")
success "HMAC salt stored at $SALT_PATH"

# ── Step 3: Derive HMAC from YubiKey ──────────────────────────────────────────
info "Deriving HMAC-Secret from YubiKey (touch if prompted)…"
HMAC_OUTPUT=$(echo -n "$HMAC_SALT" | ykman otp calculate "$YK_SLOT" - 2>/dev/null) \
    || die "YubiKey HMAC failed. Ensure slot $YK_SLOT has HMAC-SHA1 configured.\n  Run: ykman otp hmac-sha1 $YK_SLOT"
success "HMAC derived from YubiKey"

# ── Step 4: Wrap APFS password with HMAC output ───────────────────────────────
# XOR-wrap: encrypt password bytes with HMAC output bytes (simple, reversible)
# For production, consider: echo "$APFS_PASSWORD" | age -r "$HMAC_OUTPUT" > wrapped.age
# We store the wrapped form in Keychain so raw password is never at rest unwrapped.
info "Wrapping password with HMAC output and storing in Keychain…"
WRAPPED=$(python3 -c "
import sys, base64
pw   = b'$APFS_PASSWORD'
key  = b'$HMAC_OUTPUT'
out  = bytes(pw[i] ^ key[i % len(key)] for i in range(len(pw)))
print(base64.b64encode(out).decode())
")

security add-generic-password \
    -s "$KC_SERVICE" \
    -a "$KC_ACCOUNT" \
    -w "$WRAPPED" \
    -T "" \
    2>/dev/null || security delete-generic-password -s "$KC_SERVICE" -a "$KC_ACCOUNT" 2>/dev/null \
               && security add-generic-password -s "$KC_SERVICE" -a "$KC_ACCOUNT" -w "$WRAPPED" -T ""

success "Wrapped password stored in Keychain (service: $KC_SERVICE)"

# ── Step 5: Back up plain password to Bitwarden ───────────────────────────────
info "Storing plain password in Bitwarden as break-glass backup…"
if bw status 2>/dev/null | grep -q '"status":"unlocked"'; then
    BW_TEMPLATE=$(bw get template item.login 2>/dev/null)
    BW_ITEM_JSON=$(echo "$BW_TEMPLATE" | jq \
        --arg name "$BW_ITEM" \
        --arg pw "$APFS_PASSWORD" \
        --arg serial "$YK_SERIAL" \
        '.name = $name | .login.password = $pw | .notes = ("YubiKey serial: " + $serial + "\nSalt: '"$SALT_PATH"'")' \
    )
    echo "$BW_ITEM_JSON" | bw encode | bw create item >/dev/null
    success "Password saved to Bitwarden item: $BW_ITEM"
else
    warn "Bitwarden vault not unlocked. Skipping automatic backup."
    warn "IMPORTANT — manually save this password to Bitwarden item '$BW_ITEM':"
    echo ""
    echo -e "  ${RED}${BOLD}$APFS_PASSWORD${NC}"
    echo ""
    warn "This is the ONLY time this password will be shown in plaintext."
    read -rp "  Press ENTER after saving it securely…"
fi

# Clear password from environment
unset APFS_PASSWORD HMAC_OUTPUT WRAPPED

# ── Step 6: Create sparsebundle ──────────────────────────────────────────────
info "Creating encrypted APFS sparsebundle (${SIZE})…"
info "You will be prompted for the container password — retrieve it from Bitwarden."
echo ""

hdiutil create \
    -size "$SIZE" \
    -type SPARSEBUNDLE \
    -fs APFS \
    -volname "$VOLUME_NAME" \
    -encryption AES-256 \
    -stdinpass \
    "$SB_PATH" <<< "$(bw get password "$BW_ITEM" 2>/dev/null || read -rsp 'Container password: ' pw && echo "$pw")"

success "Sparsebundle created at $SB_PATH"

# ── Step 7: Initial mount and directory scaffold ──────────────────────────────
info "Mounting for initial directory setup…"
hdiutil attach "$SB_PATH" -mountpoint "$VOLUME_PATH"

mkdir -p "$VOLUME_PATH/repos"
mkdir -p "$VOLUME_PATH/data"
success "Directory structure created inside volume"

hdiutil detach "$VOLUME_PATH"
success "Volume detached — encryption active"

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}Container creation complete.${NC}"
echo ""
echo "  Sparsebundle : $SB_PATH"
echo "  YubiKey      : serial $YK_SERIAL (slot $YK_SLOT)"
echo "  HMAC salt    : $SALT_PATH"
echo "  Keychain     : $KC_SERVICE / $KC_ACCOUNT"
echo "  Bitwarden    : $BW_ITEM"
echo ""
echo "  Back up $SB_PATH to an external encrypted drive."
echo "  Enroll a second YubiKey as backup (run: ykman otp hmac-sha1 $YK_SLOT on backup key)"
echo ""
echo "  Start working: mount-secure.sh"
echo ""
