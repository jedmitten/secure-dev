#!/usr/bin/env bash
# github-init.sh — Create a private GitHub repo and push secure-dev scripts
# Requires: gh (GitHub CLI), git
# Run from the directory containing the secure-dev scripts.
set -euo pipefail

# ── Colours ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[info]${NC}  $*"; }
success() { echo -e "${GREEN}[ok]${NC}    $*"; }
die()     { echo -e "${RED}[error]${NC} $*" >&2; exit 1; }

# ── Config — edit if desired ───────────────────────────────────────────────────
REPO_NAME="secure-dev"
REPO_DESC="Encrypted APFS Python dev environment — mount/detach automation with YubiKey + Bitwarden"
VISIBILITY="private"   # private | public
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Preflight ──────────────────────────────────────────────────────────────────
command -v gh  &>/dev/null || die "GitHub CLI not found. Install: brew install gh"
command -v git &>/dev/null || die "git not found."

# Ensure gh is authenticated
gh auth status &>/dev/null || die "Not authenticated. Run: gh auth login"

GH_USER=$(gh api user --jq '.login')
info "GitHub user: $GH_USER"

# ── Init git repo ──────────────────────────────────────────────────────────────
cd "$SCRIPT_DIR"

if [[ ! -d .git ]]; then
    info "Initialising git repo..."
    git init
    git branch -M main
fi

# ── .gitignore ─────────────────────────────────────────────────────────────────
if [[ ! -f .gitignore ]]; then
    cat > .gitignore <<'EOF'
# Never commit secrets or derived key material
*.salt
hmac.salt
detach.log
last_mount
launchd-*.log
.DS_Store

# Never commit the sparsebundle itself
*.sparsebundle/
EOF
    success ".gitignore created"
fi

# ── Initial commit ─────────────────────────────────────────────────────────────
git add .
if git diff --cached --quiet; then
    info "Nothing new to commit — repo already up to date"
else
    git commit -m "Initial commit: secure-dev automation scripts"
    success "Initial commit created"
fi

# ── Create GitHub repo and push ───────────────────────────────────────────────
if gh repo view "$GH_USER/$REPO_NAME" &>/dev/null; then
    info "Repo $GH_USER/$REPO_NAME already exists — pushing to existing remote..."
else
    info "Creating $VISIBILITY GitHub repo: $GH_USER/$REPO_NAME..."
    gh repo create "$REPO_NAME" \
        --"$VISIBILITY" \
        --description "$REPO_DESC" \
        --source=. \
        --remote=origin \
        --push
    success "Repo created: https://github.com/$GH_USER/$REPO_NAME"
fi

# Push (handles case where repo existed and remote already set)
git remote get-url origin &>/dev/null || \
    git remote add origin "https://github.com/$GH_USER/$REPO_NAME.git"

git push -u origin main

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}Done.${NC}"
echo ""
echo "  Repo : https://github.com/$GH_USER/$REPO_NAME"
echo "  Clone on a new machine:"
echo "  gh repo clone $GH_USER/$REPO_NAME ~/bin/secure-dev && ~/bin/secure-dev/install.sh"
echo ""