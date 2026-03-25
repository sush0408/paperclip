#!/usr/bin/env bash
#
# Push Claude Code credentials from Mac Keychain to a remote VM via SSH.
# Credentials are piped over SSH — never written to local disk.
#
# Usage:
#   ./scripts/push-credentials-to-vm.sh user@vm-ip
#   ./scripts/push-credentials-to-vm.sh user@vm-ip --railway  # also sync to Railway
#
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <ssh-destination> [--railway]"
  echo ""
  echo "Examples:"
  echo "  $0 root@65.109.x.x"
  echo "  $0 deploy@my-hetzner.example.com --railway"
  exit 1
fi

SSH_DEST="$1"
SYNC_RAILWAY=false
[[ "${2:-}" == "--railway" ]] && SYNC_RAILWAY=true

readonly KEYCHAIN_SERVICE="Claude Code-credentials"
KEYCHAIN_ACCOUNT="$(whoami)"

# ── Read from Keychain ────────────────────────────────
CREDS="$(security find-generic-password \
  -s "$KEYCHAIN_SERVICE" \
  -a "$KEYCHAIN_ACCOUNT" \
  -w 2>/dev/null)" || {
  echo "ERROR: Could not read Claude credentials from Keychain." >&2
  echo "       Make sure you are logged in to Claude Code." >&2
  exit 1
}

# ── Validate ──────────────────────────────────────────
if ! echo "$CREDS" | jq -e '.claudeAiOauth.accessToken' &>/dev/null; then
  echo "ERROR: Invalid credentials JSON." >&2
  exit 1
fi

EXPIRES_AT="$(echo "$CREDS" | jq -r '.claudeAiOauth.expiresAt // 0')"
NOW_MS="$(date +%s)000"
if [[ "$EXPIRES_AT" -le "$NOW_MS" ]]; then
  echo "ERROR: Token expired. Run 'claude' locally to refresh, then retry." >&2
  exit 1
fi

EXPIRES_HUMAN="$(date -r "$((EXPIRES_AT / 1000))" '+%Y-%m-%d %H:%M %Z' 2>/dev/null || echo "unknown")"
SUB_TYPE="$(echo "$CREDS" | jq -r '.claudeAiOauth.subscriptionType // "unknown"')"
echo "Token OK ($SUB_TYPE, expires: $EXPIRES_HUMAN)"

# ── Push to VM via SSH ────────────────────────────────
echo "Pushing credentials to $SSH_DEST..."
echo "$CREDS" | ssh "$SSH_DEST" '
  mkdir -p ~/.claude
  cat > ~/.claude/.credentials.json
  chmod 600 ~/.claude/.credentials.json
  echo "Credentials saved to ~/.claude/.credentials.json"
'
echo "Done — VM credentials updated."

# ── Optionally sync to Railway too ────────────────────
if "$SYNC_RAILWAY"; then
  echo ""
  echo "Syncing to Railway..."
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  "$SCRIPT_DIR/sync-claude-credentials.sh" --no-restart
  echo "Railway credentials updated (no restart — next heartbeat uses new creds)."
fi
