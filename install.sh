#!/usr/bin/env bash
# install.sh — One-time bootstrap for secure Python dev environment
# Run once on a new machine after copying this repo to ~/bin/
set -euo pipefail

# ── Colours ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[info]${NC}  $*"; }
success() { echo -e "${GREEN}[ok]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[warn]${NC}  $*"; }
die()     { echo -e "${RED}[error]${NC} $*" >&2; exit 1; }

# ── Config ─────────────────────────────────────────────────────────────────────
CONFIG_DIR="$HOME/.config/secure-dev"
CONFIG_FILE="$CONFIG_DIR/config.toml"
BIN_DIR="$HOME/bin"
SECURE_DIR="$HOME/Secure"
LAUNCHAGENTS_DIR="$HOME/Library/LaunchAgents"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Helpers ────────────────────────────────────────────────────────────────────
read_toml() {
    # Minimal TOML reader: read_toml <file> <section> <key>
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

require_brew() {
    command -v brew &>/dev/null || die "Homebrew not found. Install from https://brew.sh"
}

brew_install_if_missing() {
    local pkg="$1" cmd="${2:-$1}"
    if ! command -v "$cmd" &>/dev/null; then
        info "Installing $pkg via Homebrew…"
        brew install "$pkg"
        success "$pkg installed"
    else
        success "$pkg already present ($(command -v "$cmd"))"
    fi
}

# ── Step 0: Preflight ──────────────────────────────────────────────────────────
echo -e "\n${BOLD}Secure Dev Environment — Bootstrap${NC}\n"

[[ "$(uname)" == "Darwin" ]] || die "macOS only."
require_brew

# ── Step 1: Install dependencies ──────────────────────────────────────────────
info "Checking dependencies…"
brew_install_if_missing "python-yubico/stable/yubikey-manager" "ykman"
brew_install_if_missing "age"
brew_install_if_missing "age-plugin-yubikey"
brew_install_if_missing "bitwarden-cli" "bw"
brew_install_if_missing "pyenv"
brew_install_if_missing "uv"
brew_install_if_missing "jq"

# ── Step 2: Create directories ────────────────────────────────────────────────
info "Creating directory structure…"
mkdir -p "$CONFIG_DIR" "$BIN_DIR" "$SECURE_DIR" "$LAUNCHAGENTS_DIR"
success "Directories ready"

# ── Step 3: Install config.toml ───────────────────────────────────────────────
if [[ ! -f "$CONFIG_FILE" ]]; then
    cp "$SCRIPT_DIR/config.toml" "$CONFIG_FILE"
    success "config.toml installed at $CONFIG_FILE"
else
    warn "config.toml already exists — skipping (edit manually if needed)"
fi

# ── Step 4: Install scripts ───────────────────────────────────────────────────
info "Installing scripts to $BIN_DIR…"
for script in mount-secure.sh detach.sh create-container.sh; do
    if [[ -f "$SCRIPT_DIR/$script" ]]; then
        cp "$SCRIPT_DIR/$script" "$BIN_DIR/$script"
        chmod +x "$BIN_DIR/$script"
        success "$script installed"
    else
        warn "$script not found in $SCRIPT_DIR — skipping"
    fi
done

# ── Step 5: Add ~/bin to PATH ─────────────────────────────────────────────────
ZSHRC="$HOME/.zshrc"
if ! grep -q 'export PATH="$HOME/bin:$PATH"' "$ZSHRC" 2>/dev/null; then
    info "Adding ~/bin to PATH in ~/.zshrc…"
    echo '' >> "$ZSHRC"
    echo '# secure-dev: personal scripts' >> "$ZSHRC"
    echo 'export PATH="$HOME/bin:$PATH"' >> "$ZSHRC"
    success "PATH updated — restart your shell or run: source ~/.zshrc"
else
    success "~/bin already in PATH"
fi

# ── Step 6: Configure pyenv in .zshrc ────────────────────────────────────────
if ! grep -q 'pyenv init' "$ZSHRC" 2>/dev/null; then
    info "Adding pyenv init to ~/.zshrc…"
    cat >> "$ZSHRC" <<'EOF'

# pyenv
export PYENV_ROOT="$HOME/.pyenv"
export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init -)"
EOF
    success "pyenv configured in ~/.zshrc"
else
    success "pyenv already configured in ~/.zshrc"
fi

# ── Step 7: Install launchd agents ───────────────────────────────────────────
info "Installing launchd agents…"

IDLE_TIMEOUT=$(read_toml "$CONFIG_FILE" idle check_interval_seconds)
IDLE_TIMEOUT="${IDLE_TIMEOUT:-60}"

# Screen lock agent
cat > "$LAUNCHAGENTS_DIR/com.securedev.screenlock.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.securedev.screenlock</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN_DIR/detach.sh</string>
        <string>--trigger</string>
        <string>screenlock</string>
    </array>
    <key>WatchPaths</key>
    <array>
        <string>/private/var/run/com.apple.screensaver.lock</string>
    </array>
    <key>RunAtLoad</key>
    <false/>
    <key>StandardErrorPath</key>
    <string>$CONFIG_DIR/launchd-screenlock.log</string>
</dict>
</plist>
EOF
success "com.securedev.screenlock.plist installed"

# Sleep/lid agent — uses SleepWatcher or pmset hook
cat > "$LAUNCHAGENTS_DIR/com.securedev.sleep.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.securedev.sleep</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN_DIR/detach.sh</string>
        <string>--trigger</string>
        <string>sleep</string>
    </array>
    <key>OnDemand</key>
    <true/>
    <key>StandardErrorPath</key>
    <string>$CONFIG_DIR/launchd-sleep.log</string>
</dict>
</plist>
EOF
success "com.securedev.sleep.plist installed"

# Idle check agent
cat > "$LAUNCHAGENTS_DIR/com.securedev.idle.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.securedev.idle</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN_DIR/detach.sh</string>
        <string>--trigger</string>
        <string>idle</string>
        <string>--check-idle</string>
    </array>
    <key>StartInterval</key>
    <integer>${IDLE_TIMEOUT}</integer>
    <key>RunAtLoad</key>
    <false/>
    <key>StandardErrorPath</key>
    <string>$CONFIG_DIR/launchd-idle.log</string>
</dict>
</plist>
EOF
success "com.securedev.idle.plist installed"

# Load agents
for plist in screenlock sleep idle; do
    launchctl unload "$LAUNCHAGENTS_DIR/com.securedev.${plist}.plist" 2>/dev/null || true
    launchctl load  "$LAUNCHAGENTS_DIR/com.securedev.${plist}.plist"
    success "com.securedev.${plist} loaded"
done

# ── Step 8: Sleep hook via pmset (requires sudo once) ────────────────────────
SLEEP_HOOK="/etc/pm/sleep.d/99-securedev"
if [[ ! -f "$SLEEP_HOOK" ]]; then
    warn "Sleep/lid-close hook requires a one-time sudo write to /etc/pm/sleep.d/"
    echo -e "  Run manually:\n"
    echo '  sudo mkdir -p /etc/pm/sleep.d'
    echo "  sudo tee /etc/pm/sleep.d/99-securedev > /dev/null <<'HOOK'"
    echo '  #!/bin/bash'
    echo '  case "$1" in'
    echo "      sleep|hibernate) $BIN_DIR/detach.sh --trigger sleep ;;"
    echo '  esac'
    echo '  HOOK'
    echo '  sudo chmod +x /etc/pm/sleep.d/99-securedev'
fi

# ── Step 9: Automator Quick Action instructions ───────────────────────────────
echo ""
echo -e "${BOLD}Manual step required — Automator Quick Action:${NC}"
echo ""
echo "  1. Open Automator → New Document → Quick Action"
echo "  2. Set 'Workflow receives' to 'no input' in 'any application'"
echo "  3. Add action: Run Shell Script"
echo "  4. Set shell to /bin/bash, paste:"
echo -e "     ${CYAN}$BIN_DIR/detach.sh --trigger manual${NC}"
echo "  5. Save as: Lock Secure Volume"
echo "  6. Open System Settings → Keyboard → Keyboard Shortcuts → Services"
echo "  7. Find 'Lock Secure Volume' under General, assign your shortcut"
echo ""

# ── Done ──────────────────────────────────────────────────────────────────────
echo -e "${GREEN}${BOLD}Bootstrap complete.${NC}"
echo ""
echo "  Next steps:"
echo "  1. Complete the Automator step above"
echo "  2. Run: source ~/.zshrc"
echo "  3. Run: create-container.sh"
echo "  4. Run: mount-secure.sh"
echo ""
