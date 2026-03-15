#!/usr/bin/env bash
# enroll-yubikeys.sh — Enroll an additional YubiKey into an existing setup
#
# Use this to add a new key after the container is already created.
# The new key gets its own salt and Keychain entry, wrapping the same
# container password retrieved via an already-enrolled key or Bitwarden.
#
# Run with:
#   - An already-enrolled key plugged in (to retrieve the container password)
#   - The new key also plugged in (to enroll it)
# Or with just the new key plugged in if you retrieve the password from Bitwarden.
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
YK_SLOT=$(read_toml "$CONFIG_FILE" security yubikey_slot)
SALT_DIR=$(eval echo "$(dirname "$(read_toml "$CONFIG_FILE" security hmac_salt_path)")")
PREFERRED_SERIAL=$(read_toml "$CONFIG_FILE" security preferred_serial)
BW_ITEM=$(read_toml "$CONFIG_FILE" security bitwarden_item_name)

# ── Preflight ──────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}Secure Dev -- Enroll New YubiKey${NC}\n"

command -v ykman &>/dev/null || die "ykman not found."
command -v python3 &>/dev/null || die "python3 not found."

# ── Detect connected keys ─────────────────────────────────────────────────────
YK_SERIALS=()
while IFS= read -r line; do
    [[ -n "$line" ]] && YK_SERIALS+=("$line")
done < <(ykman list --serials 2>/dev/null)

[[ ${#YK_SERIALS[@]} -eq 0 ]] && die "No YubiKeys detected."
info "Detected YubiKey(s): ${YK_SERIALS[*]}"

# ── Identify which keys are new (no salt file) ────────────────────────────────
NEW_SERIALS=()
ENROLLED_SERIALS=()
for serial in "${YK_SERIALS[@]}"; do
    if [[ -f "$SALT_DIR/hmac.salt.$serial" ]]; then
        ENROLLED_SERIALS+=("$serial")
    else
        NEW_SERIALS+=("$serial")
    fi
done

[[ ${#NEW_SERIALS[@]} -eq 0 ]] && die "All detected keys are already enrolled. Plug in the new key and retry."
info "New key(s) to enroll: ${NEW_SERIALS[*]}"
[[ ${#ENROLLED_SERIALS[@]} -gt 0 ]] && info "Already enrolled: ${ENROLLED_SERIALS[*]}"

# Move preferred serial to front of enrolled list so it's used for password retrieval
if [[ -n "${PREFERRED_SERIAL:-}" && ${#ENROLLED_SERIALS[@]} -gt 1 ]]; then
    ORDERED=()
    for s in "${ENROLLED_SERIALS[@]}"; do [[ "$s" == "$PREFERRED_SERIAL" ]] && ORDERED+=("$s"); done
    for s in "${ENROLLED_SERIALS[@]}"; do [[ "$s" != "$PREFERRED_SERIAL" ]] && ORDERED+=("$s"); done
    ENROLLED_SERIALS=("${ORDERED[@]}")
    unset ORDERED
fi

# ── Retrieve container password ───────────────────────────────────────────────
# Try enrolled key first, fall back to Bitwarden.
APFS_PASSWORD=""

if [[ ${#ENROLLED_SERIALS[@]} -gt 0 ]]; then
    enrolled_serial="${ENROLLED_SERIALS[0]}"
    salt_path="$SALT_DIR/hmac.salt.$enrolled_serial"
    kc_account="apfs-password-$enrolled_serial"
    salt=$(cat "$salt_path")

    info "Touch enrolled YubiKey $enrolled_serial to retrieve password..."
    hmac=$(ykman --device "$enrolled_serial" otp calculate "$YK_SLOT" "$salt" 2>/dev/null) \
        || warn "HMAC failed for enrolled key $enrolled_serial -- will try Bitwarden."

    if [[ -n "${hmac:-}" ]]; then
        wrapped=$(security find-generic-password \
            -s "$KC_SERVICE" -a "$kc_account" -w 2>/dev/null) || true

        if [[ -n "${wrapped:-}" ]]; then
            APFS_PASSWORD=$(WRAPPED="$wrapped" HMAC="$hmac" python3 -c "
import base64, os
wrapped = base64.b64decode(os.environ['WRAPPED'])
key     = os.environ['HMAC'].encode()
out     = bytes(wrapped[i] ^ key[i % len(key)] for i in range(len(wrapped)))
print(out.decode())
") || true
        fi
    fi
    unset hmac wrapped salt
fi

if [[ -z "$APFS_PASSWORD" ]]; then
    warn "Could not retrieve password via enrolled key -- falling back to Bitwarden..."
    local_status=$(bw status 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','locked'))" 2>/dev/null || echo "locked")
    if [[ "$local_status" != "unlocked" ]]; then
        export BW_SESSION
        BW_SESSION=$(bw unlock --raw)
    fi
    APFS_PASSWORD=$(bw get password "$BW_ITEM" 2>/dev/null) \
        || die "Could not retrieve password from Bitwarden."
fi

[[ -n "$APFS_PASSWORD" ]] || die "Failed to retrieve container password."
success "Container password retrieved"

# ── Enroll each new key ───────────────────────────────────────────────────────
for serial in "${NEW_SERIALS[@]}"; do
    info "Programming YubiKey $serial..."

    slot_info=$(ykman --device "$serial" otp info 2>/dev/null || true)
    slot_line=$(echo "$slot_info" | grep -i "Slot $YK_SLOT" || true)

    if echo "$slot_line" | grep -qi "programmed"; then
        warn "YubiKey $serial slot $YK_SLOT is already programmed."
        read -rp "  Type 'overwrite' to confirm, or Ctrl-C to abort: " CONFIRM
        [[ "$CONFIRM" == "overwrite" ]] || die "Aborted."
    fi

    # Program with a new random secret
    local_secret=$(openssl rand -hex 20)
    ykman --device "$serial" otp chalresp --force "$YK_SLOT" "$local_secret" \
        || die "Failed to program YubiKey $serial."
    local_secret="0000000000000000000000000000000000000000"
    unset local_secret
    success "YubiKey $serial programmed"

    # Generate salt, derive HMAC, wrap password, store in Keychain
    salt_path="$SALT_DIR/hmac.salt.$serial"
    kc_account="apfs-password-$serial"

    openssl rand -hex 32 > "$salt_path"
    chmod 600 "$salt_path"
    salt=$(cat "$salt_path")

    info "Touch YubiKey $serial when it flashes..."
    hmac=$(ykman --device "$serial" otp calculate "$YK_SLOT" "$salt" 2>/dev/null) \
        || die "HMAC derivation failed for YubiKey $serial."

    wrapped=$(APFS_PASSWORD="$APFS_PASSWORD" HMAC="$hmac" python3 -c "
import base64, os
pw  = os.environ['APFS_PASSWORD'].encode()
key = os.environ['HMAC'].encode()
out = bytes(pw[i] ^ key[i % len(key)] for i in range(len(pw)))
print(base64.b64encode(out).decode())
")

    security delete-generic-password -s "$KC_SERVICE" -a "$kc_account" 2>/dev/null || true
    security add-generic-password \
        -s "$KC_SERVICE" \
        -a "$kc_account" \
        -w "$wrapped" \
        -T "" \
        || die "Failed to store wrapped password in Keychain for key $serial."

    success "YubiKey $serial enrolled (salt: $salt_path, keychain: $KC_SERVICE / $kc_account)"
    unset hmac wrapped salt
done

unset APFS_PASSWORD

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}Enrollment complete.${NC}"
echo ""
echo "  Newly enrolled: ${NEW_SERIALS[*]}"
echo "  All enrolled  : ${YK_SERIALS[*]}"
echo ""
echo "  Each key works independently -- plug in either to mount."
echo ""