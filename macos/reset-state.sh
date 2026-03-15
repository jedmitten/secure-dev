#!/usr/bin/env bash
# reset-state.sh — Wipe all secure-dev state to start completely clean
#
# Removes:
#   - The encrypted sparsebundle (ALL CONTENTS PERMANENTLY LOST)
#   - All Keychain entries for the service
#   - All HMAC salt files
#   - The last_mount marker
#   - The phase1 Bitwarden item ID file (.bwid)
set -euo pipefail

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

SB_PATH=$(eval echo "$(read_toml "$CONFIG_FILE" container path)")
VOLUME_PATH=$(read_toml "$CONFIG_FILE" container volume_path)
KC_SERVICE=$(read_toml "$CONFIG_FILE" security keychain_service)
SALT_BASE=$(eval echo "$(read_toml "$CONFIG_FILE" security hmac_salt_path)")
SALT_DIR=$(dirname "$SALT_BASE")

# ── Confirm ────────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}${RED}Secure Dev -- Reset State${NC}\n"
warn "This will PERMANENTLY DELETE:"
echo "    Sparsebundle : $SB_PATH"
echo "    Keychain     : all entries under service '$KC_SERVICE'"
echo "    Salt files   : $SALT_DIR/hmac.salt.*"
echo "    Misc markers : last_mount, .bwid"
echo ""
warn "The encrypted volume and ALL its contents will be unrecoverable."
echo ""
read -rp "  Type 'destroy' to confirm, or Ctrl-C to abort: " CONFIRM
[[ "$CONFIRM" == "destroy" ]] || { echo ""; info "Aborted -- nothing changed."; exit 0; }
echo ""

# ── Detach volume if mounted ───────────────────────────────────────────────────
if mount | grep -q "$VOLUME_PATH"; then
    info "Detaching mounted volume..."
    if hdiutil detach "$VOLUME_PATH" -force 2>/dev/null; then
        success "Volume detached"
    else
        warn "Detach failed -- continuing anyway"
    fi
fi

# ── Remove sparsebundle ────────────────────────────────────────────────────────
if [[ -e "$SB_PATH" ]]; then
    info "Removing sparsebundle..."
    rm -rf "$SB_PATH"
    success "Removed $SB_PATH"
else
    info "No sparsebundle at $SB_PATH"
fi

# ── Collect serials: from salt files + any connected YubiKeys ─────────────────
SERIALS=()

for f in "$SALT_DIR"/hmac.salt.*; do
    [[ -f "$f" ]] || continue
    serial="${f##*hmac.salt.}"
    # skip the .bwid file which also matches hmac.salt.*
    [[ "$serial" == "bwid" ]] && continue
    SERIALS+=("$serial")
done

while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    # deduplicate inline (bash 3.2 -- no associative arrays)
    already=0
    for s in ${SERIALS[@]+"${SERIALS[@]}"}; do
        [[ "$s" == "$line" ]] && already=1 && break
    done
    [[ $already -eq 0 ]] && SERIALS+=("$line")
done < <(ykman list --serials 2>/dev/null || true)

# ── Remove Keychain entries ────────────────────────────────────────────────────
if [[ ${#SERIALS[@]} -eq 0 ]]; then
    info "No serials found -- no Keychain entries to remove"
else
    for serial in "${SERIALS[@]}"; do
        kc_account="apfs-password-$serial"
        if security delete-generic-password -s "$KC_SERVICE" -a "$kc_account" 2>/dev/null; then
            success "Deleted Keychain: $KC_SERVICE / $kc_account"
        else
            info "No Keychain entry for $kc_account"
        fi
    done
fi

# ── Remove salt files ──────────────────────────────────────────────────────────
for f in "$SALT_DIR"/hmac.salt.*; do
    [[ -f "$f" ]] || continue
    rm -f "$f"
    success "Removed $f"
done

# ── Remove misc markers ────────────────────────────────────────────────────────
for f in \
    "$HOME/.config/secure-dev/last_mount" \
    "${SALT_BASE}.bwid"
do
    if [[ -f "$f" ]]; then
        rm -f "$f"
        success "Removed $f"
    fi
done

# ── Done ───────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}State cleared.${NC} Ready for a fresh run:"
echo ""
echo "  cd $(dirname "$0")"
echo "  bash create-container.sh"
echo ""
