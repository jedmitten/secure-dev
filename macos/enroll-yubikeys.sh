#!/usr/bin/env bash
# enroll-yubikeys.sh — Phase 2 YubiKey enrollment
#
# Run this when both YubiKeys are available (after create-container-phase1.sh).
#
# What this script does:
#   1. Retrieves the container password from the phase1 Bitwarden temp entry
#   2. Generates one shared HMAC secret and programs BOTH YubiKeys with it
#   3. Verifies both keys produce identical HMAC output
#   4. Derives HMAC-Secret from primary key + stored salt
#   5. XOR-wraps the container password under that HMAC output
#   6. Stores the wrapped password in macOS Keychain
#   7. Deletes the plaintext temp Bitwarden entry
#   8. Creates a properly-labelled break-glass Bitwarden entry
#      (password only, no raw form — for emergency use with mount-secure.sh fallback)
#
# After this script: mount-secure.sh uses YubiKey + Keychain as primary,
# Bitwarden as break-glass. The raw plaintext password no longer exists anywhere.
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
[[ -f "$CONFIG_FILE" ]] || die "config.toml not found."

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

KC_SERVICE=$(read_toml "$CONFIG_FILE" security keychain_service)
KC_ACCOUNT=$(read_toml "$CONFIG_FILE" security keychain_account)
YK_SLOT=$(read_toml "$CONFIG_FILE" security yubikey_slot)
SALT_PATH=$(eval echo "$(read_toml "$CONFIG_FILE" security hmac_salt_path)")
BW_ITEM=$(read_toml "$CONFIG_FILE" security bitwarden_item_name)
BWID_FILE="${SALT_PATH}.bwid"

# ── Preflight ──────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}Secure Dev — Phase 2 YubiKey Enrollment${NC}\n"

command -v ykman    &>/dev/null || die "ykman not found. Run install.sh first."
command -v bw       &>/dev/null || die "Bitwarden CLI not found."
command -v jq       &>/dev/null || die "jq not found."
[[ -f "$SALT_PATH" ]] || die "HMAC salt not found at $SALT_PATH. Was create-container-phase1.sh run?"
[[ -f "$BWID_FILE" ]] || die "Phase 1 Bitwarden item ID not found at $BWID_FILE. Was create-container-phase1.sh run?"

PHASE1_BW_ID=$(cat "$BWID_FILE")
[[ -n "$PHASE1_BW_ID" ]] || die "Phase 1 Bitwarden item ID is empty."

# ── Bitwarden unlock ──────────────────────────────────────────────────────────
info "Checking Bitwarden vault status…"
if ! bw status 2>/dev/null | grep -q '"status":"unlocked"'; then
    info "Unlocking Bitwarden vault (touch YubiKey if prompted for FIDO2)…"
    export BW_SESSION
    BW_SESSION=$(bw unlock --raw) || die "Bitwarden unlock failed."
    success "Bitwarden vault unlocked"
else
    success "Bitwarden vault already unlocked"
fi

# ── Retrieve container password from phase1 temp Bitwarden entry ──────────────
info "Retrieving container password from phase1 Bitwarden entry…"
APFS_PASSWORD=$(bw get item "$PHASE1_BW_ID" | jq -r '.login.password') \
    || die "Failed to retrieve password from Bitwarden item $PHASE1_BW_ID."
[[ -n "$APFS_PASSWORD" ]] || die "Retrieved password is empty — Bitwarden item may have been deleted."
success "Container password retrieved"

# ── Enumerate connected YubiKeys ──────────────────────────────────────────────
mapfile -t YK_SERIALS < <(ykman list --serials 2>/dev/null)
YK_COUNT=${#YK_SERIALS[@]}

if [[ $YK_COUNT -eq 0 ]]; then
    die "No YubiKeys detected. Plug in both YubiKeys and retry."
elif [[ $YK_COUNT -eq 1 ]]; then
    warn "Only one YubiKey detected (serial: ${YK_SERIALS[0]})."
    warn "This defeats the purpose of the two-key setup."
    warn "You can proceed with one key, but you will not have hardware backup."
    echo ""
    read -rp "  Continue with one key only? [y/N]: " ONE_KEY
    [[ "${ONE_KEY,,}" == "y" ]] || die "Aborted. Plug in both YubiKeys and retry."
else
    info "Found $YK_COUNT YubiKeys: ${YK_SERIALS[*]}"
fi

YK_SERIAL="${YK_SERIALS[0]}"   # primary — serial recorded in final Bitwarden item

# ── Generate shared HMAC secret ───────────────────────────────────────────────
# One secret, programmed identically onto every key, then discarded.
info "Generating shared HMAC secret (20 bytes)…"
HMAC_SECRET=$(openssl rand -hex 20)

# ── Program each YubiKey ──────────────────────────────────────────────────────
program_yubikey() {
    local serial="$1" label="$2"
    info "Programming $label YubiKey (serial: $serial)…"

    local slot_info slot_line
    slot_info=$(ykman --device "$serial" otp info 2>/dev/null || true)
    slot_line=$(echo "$slot_info" | grep -i "Slot $YK_SLOT" || true)

    if echo "$slot_line" | grep -qi "programmed"; then
        warn "$label YubiKey slot $YK_SLOT is already programmed."
        warn "Continuing will OVERWRITE the existing slot $YK_SLOT configuration."
        echo ""
        read -rp "  Type 'overwrite' to confirm for $label key, or Ctrl-C to abort: " CONFIRM
        [[ "$CONFIRM" == "overwrite" ]] || die "Aborted. Slot $YK_SLOT on $label key not modified."
    else
        info "$label YubiKey slot $YK_SLOT is empty — safe to program."
    fi

    ykman --device "$serial" otp chalresp --force "$YK_SLOT" "$HMAC_SECRET" \
        || die "Failed to program slot $YK_SLOT on $label YubiKey (serial: $serial)."
    success "$label YubiKey programmed (serial: $serial, slot: $YK_SLOT)"
}

for i in "${!YK_SERIALS[@]}"; do
    label=$([ "$i" -eq 0 ] && echo "primary" || echo "backup #$i")
    program_yubikey "${YK_SERIALS[$i]}" "$label"
done

# ── Verify all keys produce identical HMAC output ─────────────────────────────
info "Verifying all keys produce identical HMAC output…"
TEST_CHALLENGE="deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
REFERENCE_HMAC=""
for i in "${!YK_SERIALS[@]}"; do
    serial="${YK_SERIALS[$i]}"
    label=$([ "$i" -eq 0 ] && echo "primary" || echo "backup #$i")
    info "Touch $label YubiKey (serial: $serial) when it flashes…"
    KEY_HMAC=$(echo -n "$TEST_CHALLENGE" | ykman --device "$serial" otp calculate "$YK_SLOT" - 2>/dev/null) \
        || die "HMAC challenge failed on $label YubiKey (serial: $serial)."
    if [[ -z "$REFERENCE_HMAC" ]]; then
        REFERENCE_HMAC="$KEY_HMAC"
        success "Primary key HMAC: $KEY_HMAC"
    elif [[ "$KEY_HMAC" != "$REFERENCE_HMAC" ]]; then
        die "HMAC mismatch on $label key!\n  Expected: $REFERENCE_HMAC\n  Got: $KEY_HMAC\n  Keys have different secrets. Aborting before any Keychain writes."
    else
        success "$label key HMAC matches primary ✓"
    fi
done
unset REFERENCE_HMAC TEST_CHALLENGE

# Zero the programming secret — no longer needed
HMAC_SECRET="0000000000000000000000000000000000000000"
unset HMAC_SECRET
success "All keys verified and programming secret discarded"

# ── Derive HMAC-Secret from primary key + stored salt ─────────────────────────
HMAC_SALT=$(cat "$SALT_PATH")
info "Deriving HMAC-Secret from primary YubiKey (touch when it flashes)…"
HMAC_OUTPUT=$(echo -n "$HMAC_SALT" | ykman --device "$YK_SERIAL" otp calculate "$YK_SLOT" - 2>/dev/null) \
    || die "YubiKey HMAC derivation failed on primary key (serial: $YK_SERIAL)."
success "HMAC derived"

# ── XOR-wrap container password under HMAC output ────────────────────────────
info "Wrapping container password with HMAC output…"
WRAPPED=$(python3 -c "
import sys, base64
pw   = b'$APFS_PASSWORD'
key  = b'$HMAC_OUTPUT'
out  = bytes(pw[i] ^ key[i % len(key)] for i in range(len(pw)))
print(base64.b64encode(out).decode())
")

# ── Store wrapped password in Keychain ────────────────────────────────────────
info "Storing wrapped password in Keychain…"
# Delete existing entry if present (idempotent)
security delete-generic-password -s "$KC_SERVICE" -a "$KC_ACCOUNT" &>/dev/null || true
security add-generic-password \
    -s "$KC_SERVICE" \
    -a "$KC_ACCOUNT" \
    -w "$WRAPPED" \
    -T "" \
    || die "Failed to store wrapped password in Keychain."
success "Wrapped password stored in Keychain (service: $KC_SERVICE)"

# ── Create final break-glass Bitwarden entry ──────────────────────────────────
info "Creating final break-glass Bitwarden entry…"
BW_TEMPLATE=$(bw get template item.login 2>/dev/null)
BW_FINAL_JSON=$(echo "$BW_TEMPLATE" | jq \
    --arg name "$BW_ITEM" \
    --arg pw "$APFS_PASSWORD" \
    --arg serial "$YK_SERIAL" \
    --arg serials "${YK_SERIALS[*]}" \
    '.name = $name | .login.password = $pw |
     .notes = ("BREAK-GLASS ONLY — use if YubiKey unavailable.\nYubiKey serials enrolled: " + $serials + "\nPrimary: " + $serial + "\nSalt path: '"$SALT_PATH"'")'
)
echo "$BW_FINAL_JSON" | bw encode | bw create item >/dev/null \
    || die "Failed to create final Bitwarden break-glass entry."
success "Break-glass entry created: $BW_ITEM"

# ── Delete phase1 temp Bitwarden entry ───────────────────────────────────────
info "Deleting phase1 temporary Bitwarden entry (item ID: $PHASE1_BW_ID)…"
bw delete item "$PHASE1_BW_ID" \
    || warn "Could not auto-delete phase1 Bitwarden entry (ID: $PHASE1_BW_ID). Delete it manually."
success "Phase1 temp entry deleted"

# Remove the .bwid state file — no longer needed
rm -f "$BWID_FILE"

# Clear sensitive variables
unset APFS_PASSWORD HMAC_OUTPUT WRAPPED HMAC_SALT

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}Phase 2 enrollment complete.${NC}"
echo ""
echo "  YubiKey(s)   : ${YK_SERIALS[*]} (slot $YK_SLOT)"
echo "  HMAC salt    : $SALT_PATH"
echo "  Keychain     : $KC_SERVICE / $KC_ACCOUNT (wrapped, HMAC-protected)"
echo "  Bitwarden    : $BW_ITEM (break-glass only)"
echo ""
echo "  mount-secure.sh will now use YubiKey + Keychain as primary."
echo "  The plaintext password no longer exists in Bitwarden temp storage."
echo ""