#!/usr/bin/env bash
#
# Hetzner VM agent setup for Paperclip
#
# Sets up a Hetzner (or any Linux) VM to run Paperclip agents
# with GitHub access and Claude Code authentication.
#
# Run on the target VM:
#   curl -fsSL <raw-url> | bash
# Or copy this file to the VM and run it.
#
set -euo pipefail

# ── Configuration (edit these) ─────────────────────────
PAPERCLIP_API_URL="${PAPERCLIP_API_URL:-https://paperclip-production-6e7c.up.railway.app}"
PAPERCLIP_COMPANY_ID="${PAPERCLIP_COMPANY_ID:-0b6f4079-56cd-4b4f-ae38-0467d75b00fd}"

# Agent to run (default: CEO). Override with env var.
PAPERCLIP_AGENT_NAME="${PAPERCLIP_AGENT_NAME:-CEO}"

# ── Colors ─────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[info]${NC}  $*"; }
ok()    { echo -e "${GREEN}[ok]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[warn]${NC}  $*"; }
fail()  { echo -e "${RED}[error]${NC} $*" >&2; exit 1; }

# ── 1. System dependencies ────────────────────────────
info "Installing system dependencies..."
if command -v apt-get &>/dev/null; then
  sudo apt-get update -qq
  sudo apt-get install -y -qq curl git jq unzip ca-certificates gnupg
elif command -v dnf &>/dev/null; then
  sudo dnf install -y curl git jq unzip ca-certificates
else
  warn "Unknown package manager. Ensure curl, git, jq are installed."
fi
ok "System dependencies ready"

# ── 2. Node.js (via nvm) ──────────────────────────────
if ! command -v node &>/dev/null; then
  info "Installing Node.js via nvm..."
  curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
  export NVM_DIR="$HOME/.nvm"
  # shellcheck source=/dev/null
  [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
  nvm install --lts
  ok "Node.js $(node --version) installed"
else
  ok "Node.js $(node --version) already installed"
fi

# ── 3. pnpm ───────────────────────────────────────────
if ! command -v pnpm &>/dev/null; then
  info "Installing pnpm..."
  corepack enable 2>/dev/null || npm install -g pnpm
  ok "pnpm installed"
else
  ok "pnpm $(pnpm --version) already installed"
fi

# ── 4. Claude Code CLI ────────────────────────────────
if ! command -v claude &>/dev/null; then
  info "Installing Claude Code CLI..."
  npm install -g @anthropic-ai/claude-code@latest
  ok "Claude Code installed"
else
  ok "Claude Code already installed"
fi

# ── 5. GitHub CLI ─────────────────────────────────────
if ! command -v gh &>/dev/null; then
  info "Installing GitHub CLI..."
  if command -v apt-get &>/dev/null; then
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
    sudo apt-get update -qq && sudo apt-get install -y -qq gh
  else
    curl -fsSL https://github.com/cli/cli/releases/latest/download/gh_$(curl -s https://api.github.com/repos/cli/cli/releases/latest | jq -r .tag_name | tr -d v)_linux_amd64.tar.gz \
      | sudo tar xz -C /usr/local --strip-components=1
  fi
  ok "GitHub CLI installed"
else
  ok "GitHub CLI $(gh --version | head -1) already installed"
fi

# ── 6. Paperclip CLI ──────────────────────────────────
if ! command -v paperclipai &>/dev/null; then
  info "Installing Paperclip CLI..."
  npm install -g paperclipai@latest
  ok "Paperclip CLI installed"
else
  ok "Paperclip CLI already installed"
fi

# ── 7. Create agent workspace ─────────────────────────
AGENT_HOME="$HOME/paperclip-agent"
mkdir -p "$AGENT_HOME"
ok "Agent workspace: $AGENT_HOME"

# ── 8. Credential setup prompts ───────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Credential Setup"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# -- GitHub auth --
if ! gh auth status &>/dev/null 2>&1; then
  warn "GitHub CLI not authenticated."
  echo "  Option A: Run interactively:  gh auth login"
  echo "  Option B: Set GITHUB_TOKEN:   export GITHUB_TOKEN=ghp_..."
  echo ""
  read -rp "Enter your GitHub token (or press Enter to skip for now): " GH_TOKEN
  if [[ -n "$GH_TOKEN" ]]; then
    echo "$GH_TOKEN" | gh auth login --with-token
    ok "GitHub authenticated"
  else
    warn "Skipped GitHub auth. Set GITHUB_TOKEN before running agents."
  fi
else
  ok "GitHub already authenticated"
fi

# -- Claude credentials --
CLAUDE_DIR="$HOME/.claude"
CLAUDE_CREDS="$CLAUDE_DIR/.credentials.json"
if [[ -f "$CLAUDE_CREDS" ]]; then
  ok "Claude credentials found at $CLAUDE_CREDS"
else
  warn "No Claude credentials found."
  echo ""
  echo "  Paste the JSON from your Mac (run on Mac first):"
  echo "    security find-generic-password -s 'Claude Code-credentials' -a \$(whoami) -w"
  echo ""
  read -rp "Paste credentials JSON (or press Enter to skip): " CREDS_JSON
  if [[ -n "$CREDS_JSON" ]]; then
    mkdir -p "$CLAUDE_DIR"
    echo "$CREDS_JSON" > "$CLAUDE_CREDS"
    chmod 600 "$CLAUDE_CREDS"
    ok "Claude credentials saved (chmod 600)"
  else
    warn "Skipped. Set ANTHROPIC_API_KEY or paste credentials later."
  fi
fi

# ── 9. Write agent env file ───────────────────────────
ENV_FILE="$AGENT_HOME/.env"
cat > "$ENV_FILE" << EOF
# Paperclip Agent Environment
# Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)

PAPERCLIP_API_URL=$PAPERCLIP_API_URL
PAPERCLIP_COMPANY_ID=$PAPERCLIP_COMPANY_ID
PAPERCLIP_AGENT_NAME=$PAPERCLIP_AGENT_NAME

# Uncomment and set if using API key instead of OAuth:
# ANTHROPIC_API_KEY=sk-ant-...

# GitHub token (if not using gh auth):
# GITHUB_TOKEN=ghp_...
EOF
chmod 600 "$ENV_FILE"
ok "Agent env file: $ENV_FILE"

# ── 10. Write systemd service ─────────────────────────
SYSTEMD_DIR="$HOME/.config/systemd/user"
mkdir -p "$SYSTEMD_DIR"

# Resolve paths for systemd
NODE_PATH="$(command -v node)"
NPX_PATH="$(command -v npx)"
PAPERCLIP_PATH="$(command -v paperclipai 2>/dev/null || echo "$NPX_PATH paperclipai")"

cat > "$SYSTEMD_DIR/paperclip-agent.service" << EOF
[Unit]
Description=Paperclip Agent Heartbeat Runner
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=$ENV_FILE
WorkingDirectory=$AGENT_HOME
ExecStart=$PAPERCLIP_PATH heartbeat run --agent-name \${PAPERCLIP_AGENT_NAME}
StandardOutput=append:$AGENT_HOME/agent.log
StandardError=append:$AGENT_HOME/agent-error.log

# Security hardening
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=$AGENT_HOME $HOME/.claude $HOME/.config

[Install]
WantedBy=default.target
EOF

cat > "$SYSTEMD_DIR/paperclip-agent.timer" << EOF
[Unit]
Description=Run Paperclip Agent heartbeat every 5 minutes

[Timer]
OnBootSec=30s
OnUnitActiveSec=5min
RandomizedDelaySec=30s
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl --user daemon-reload
ok "Systemd service + timer created"

# ── 11. Write credential sync script ──────────────────
SYNC_SCRIPT="$AGENT_HOME/sync-credentials.sh"
cat > "$SYNC_SCRIPT" << 'SYNCEOF'
#!/usr/bin/env bash
# Receives Claude credentials JSON via stdin or first argument.
# Usage:
#   echo '{"claudeAiOauth":...}' | ./sync-credentials.sh
#   ./sync-credentials.sh '{"claudeAiOauth":...}'
set -euo pipefail

CLAUDE_CREDS="$HOME/.claude/.credentials.json"

if [[ $# -gt 0 ]]; then
  CREDS="$1"
else
  CREDS="$(cat)"
fi

if ! echo "$CREDS" | jq -e '.claudeAiOauth.accessToken' &>/dev/null; then
  echo "ERROR: Invalid credentials JSON" >&2
  exit 1
fi

EXPIRES_AT="$(echo "$CREDS" | jq -r '.claudeAiOauth.expiresAt // 0')"
SUB_TYPE="$(echo "$CREDS" | jq -r '.claudeAiOauth.subscriptionType // "unknown"')"

mkdir -p "$(dirname "$CLAUDE_CREDS")"
echo "$CREDS" > "$CLAUDE_CREDS"
chmod 600 "$CLAUDE_CREDS"

echo "Credentials saved ($SUB_TYPE, expires: $(date -d @$((EXPIRES_AT / 1000)) '+%Y-%m-%d %H:%M' 2>/dev/null || echo 'check manually'))"
SYNCEOF
chmod +x "$SYNC_SCRIPT"
ok "Credential sync script: $SYNC_SCRIPT"

# ── 12. Summary ───────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Setup Complete"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Paperclip API: $PAPERCLIP_API_URL"
echo "  Company:       $PAPERCLIP_COMPANY_ID"
echo "  Agent:         $PAPERCLIP_AGENT_NAME"
echo "  Workspace:     $AGENT_HOME"
echo ""
echo "  Next steps:"
echo ""
echo "  1. Clone your repos into $AGENT_HOME:"
echo "     cd $AGENT_HOME && gh repo clone <your-org>/<your-repo>"
echo ""
echo "  2. Start the agent timer:"
echo "     systemctl --user enable --now paperclip-agent.timer"
echo ""
echo "  3. Or run a single heartbeat manually:"
echo "     paperclipai heartbeat run --agent-name $PAPERCLIP_AGENT_NAME"
echo ""
echo "  4. Sync credentials from your Mac (run on Mac, pipe to VM):"
echo "     security find-generic-password -s 'Claude Code-credentials' \\"
echo "       -a \$(whoami) -w | ssh <vm> '$AGENT_HOME/sync-credentials.sh'"
echo ""
echo "  5. View logs:"
echo "     tail -f $AGENT_HOME/agent.log"
echo ""
