#!/usr/bin/env bash
# create-container-phase1.sh — Option C bootstrap
#
# Creates the encrypted APFS sparsebundle now, with a strong random password
# stored as plaintext in Bitwarden (FIDO2-gated). No YubiKey HMAC enrollment.
#
# When your second YubiKey arrives, run enroll-yubikeys.sh to:
#   1. Program both keys with a shared HMAC secret
#   2. Wrap the container password under that HMAC secret in Keychain
#   3. Delete the raw plaintext Bitwarden entry
#
# After enroll-yubikeys.sh completes, mount-secure.sh works normally.
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
SALT_PATH=$(eval echo "$(read_toml "$CONFIG_FILE" security hmac_salt_path)")
BW_ITEM=$(read_toml "$CONFIG_FILE" security bitwarden_item_name)

# Temporary Bitwarden item name — distinct from the final break-glass item.
# enroll-yubikeys.sh will delete this and create a properly-labelled one.
BW_TEMP_ITEM="${BW_ITEM} (phase1-temp — delete after enroll-yubikeys.sh)"

# ── Preflight ──────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}Secure Dev — Phase 1 Container Bootstrap${NC}\n"
echo -e "  ${YELLOW}YubiKey enrollment deferred — second key not yet available.${NC}"
echo -e "  Container password will be held in Bitwarden until enroll-yubikeys.sh\n"

[[ -e "$SB_PATH" ]] && die "Container already exists at $SB_PATH. Aborting."
command -v bw      &>/dev/null || die "Bitwarden CLI not found. Run install.sh first."
command -v hdiutil &>/dev/null || die "hdiutil not found (not macOS?)."
command -v jq      &>/dev/null || die "jq not found. Run install.sh first."

# ── Bitwarden unlock ──────────────────────────────────────────────────────────
info "Checking Bitwarden vault status…"
if ! bw status 2>/dev/null | grep -q '"status":"unlocked"'; then
    info "Unlocking Bitwarden vault…"
    export BW_SESSION
    BW_SESSION=$(bw unlock --raw) || die "Bitwarden unlock failed."
    success "Bitwarden vault unlocked"
else
    success "Bitwarden vault already unlocked"
fi

# ── Step 1: Generate container password ───────────────────────────────────────
info "Generating strong container password…"
APFS_PASSWORD=$(openssl rand -base64 32 | tr -d '\n/+=' | head -c 40)
success "Password generated (40-char alphanumeric)"

# ── Step 2: Generate HMAC salt (for later use by enroll-yubikeys.sh) ──────────
# We generate and store the salt now so mount-secure.sh can use it after
# enrollment without any state having to be passed between scripts.
info "Generating HMAC salt (stored for use by enroll-yubikeys.sh)…"
mkdir -p "$(dirname "$SALT_PATH")"
openssl rand -hex 32 > "$SALT_PATH"
chmod 600 "$SALT_PATH"
success "HMAC salt stored at $SALT_PATH"

# ── Step 3: Store raw password in Bitwarden ───────────────────────────────────
info "Storing password in Bitwarden (temporary — will be replaced by enroll-yubikeys.sh)…"
BW_TEMPLATE=$(bw get template item.login 2>/dev/null)
BW_ITEM_JSON=$(echo "$BW_TEMPLATE" | jq \
    --arg name "$BW_TEMP_ITEM" \
    --arg pw "$APFS_PASSWORD" \
    '.name = $name | .login.password = $pw |
     .notes = "PHASE 1 TEMPORARY ENTRY.\nDo NOT delete manually.\nRun enroll-yubikeys.sh — it will migrate and delete this item."'
)
BW_ITEM_ID=$(echo "$BW_ITEM_JSON" | bw encode | bw create item | jq -r '.id')
success "Password saved to Bitwarden item: $BW_TEMP_ITEM"
info "Bitwarden item ID: $BW_ITEM_ID (saved to $SALT_PATH.bwid for enroll-yubikeys.sh)"

# Save item ID so enroll-yubikeys.sh can find and delete this entry
echo "$BW_ITEM_ID" > "${SALT_PATH}.bwid"
chmod 600 "${SALT_PATH}.bwid"

# ── Step 4: Create sparsebundle ──────────────────────────────────────────────
info "Creating encrypted APFS sparsebundle (${SIZE})…"
hdiutil create \
    -size "$SIZE" \
    -type SPARSEBUNDLE \
    -fs APFS \
    -volname "$VOLUME_NAME" \
    -encryption AES-256 \
    -stdinpass \
    "$SB_PATH" <<< "$APFS_PASSWORD"

success "Sparsebundle created at $SB_PATH"

# ── Step 5: Initial mount and directory scaffold ──────────────────────────────
info "Mounting for initial directory setup…"
hdiutil attach "$SB_PATH" -mountpoint "$VOLUME_PATH" -stdinpass <<< "$APFS_PASSWORD"

mkdir -p "$VOLUME_PATH/repos"
mkdir -p "$VOLUME_PATH/data"
success "Directory structure created inside volume"

hdiutil detach "$VOLUME_PATH"
success "Volume detached — encryption active"

# Clear password from environment
unset APFS_PASSWORD

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}Phase 1 complete.${NC}"
echo ""
echo "  Sparsebundle : $SB_PATH"
echo "  HMAC salt    : $SALT_PATH"
echo "  Bitwarden    : $BW_TEMP_ITEM"
echo ""
echo -e "${YELLOW}${BOLD}ACTION REQUIRED when second YubiKey arrives:${NC}"
echo "  1. Plug in BOTH YubiKeys"
echo "  2. Run: enroll-yubikeys.sh"
echo "     This will program both keys, wrap the password under HMAC,"
echo "     store the wrapped form in Keychain, and delete this temp Bitwarden entry."
echo ""
echo -e "${YELLOW}Until then, mount-secure.sh will use Bitwarden as the credential source.${NC}"
echo ""
echo "  Start working: mount-secure.sh"
echo ""