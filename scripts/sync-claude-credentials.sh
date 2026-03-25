#!/usr/bin/env bash
#
# Sync local Claude Code OAuth credentials to Railway Paperclip service.
#
# Reads credentials from macOS Keychain (never touches disk),
# sets them as an encrypted Railway env var, and optionally
# restarts the service.
#
# Usage:
#   ./scripts/sync-claude-credentials.sh              # sync + restart
#   ./scripts/sync-claude-credentials.sh --no-restart  # sync only
#   ./scripts/sync-claude-credentials.sh --dry-run     # validate only
#
set -euo pipefail

readonly KEYCHAIN_SERVICE="Claude Code-credentials"
readonly RAILWAY_VAR="CLAUDE_CREDENTIALS_JSON"
readonly RAILWAY_SERVICE="Paperclip"

# ── Flags ──────────────────────────────────────────────
RESTART=true
DRY_RUN=false

for arg in "$@"; do
  case "$arg" in
    --no-restart) RESTART=false ;;
    --dry-run)    DRY_RUN=true ;;
    --help|-h)
      echo "Usage: $0 [--no-restart] [--dry-run]"
      echo ""
      echo "  --no-restart  Set the env var but skip service redeploy"
      echo "  --dry-run     Validate credentials without pushing to Railway"
      exit 0
      ;;
    *) echo "Unknown flag: $arg"; exit 1 ;;
  esac
done

# ── Preflight checks ──────────────────────────────────
if [[ "$(uname)" != "Darwin" ]]; then
  echo "ERROR: This script reads from macOS Keychain. Run it on your Mac." >&2
  exit 1
fi

if ! command -v railway &>/dev/null; then
  echo "ERROR: Railway CLI not found. Install with: brew install railway" >&2
  exit 1
fi

if ! command -v jq &>/dev/null; then
  echo "ERROR: jq not found. Install with: brew install jq" >&2
  exit 1
fi

# ── Read credentials from Keychain ────────────────────
KEYCHAIN_ACCOUNT="$(whoami)"
CREDS="$(security find-generic-password \
  -s "$KEYCHAIN_SERVICE" \
  -a "$KEYCHAIN_ACCOUNT" \
  -w 2>/dev/null)" || {
  echo "ERROR: Could not read '$KEYCHAIN_SERVICE' from Keychain." >&2
  echo "       Make sure you are logged in to Claude Code locally." >&2
  exit 1
}

# ── Validate JSON structure (without printing secrets) ─
if ! echo "$CREDS" | jq -e '.claudeAiOauth.accessToken' &>/dev/null; then
  echo "ERROR: Credentials JSON missing 'claudeAiOauth.accessToken'." >&2
  exit 1
fi

# ── Check token expiry ────────────────────────────────
EXPIRES_AT="$(echo "$CREDS" | jq -r '.claudeAiOauth.expiresAt // 0')"
NOW_MS="$(date +%s)000"

if [[ "$EXPIRES_AT" -le "$NOW_MS" ]]; then
  echo "WARNING: Access token has expired (expiresAt: $EXPIRES_AT)." >&2
  echo "         Run 'claude' locally first to refresh your session," >&2
  echo "         then re-run this script." >&2
  exit 1
fi

EXPIRES_HUMAN="$(date -r "$((EXPIRES_AT / 1000))" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || echo "unknown")"
SUB_TYPE="$(echo "$CREDS" | jq -r '.claudeAiOauth.subscriptionType // "unknown"')"

echo "Claude credentials OK"
echo "  Subscription: $SUB_TYPE"
echo "  Expires:      $EXPIRES_HUMAN"

if "$DRY_RUN"; then
  echo ""
  echo "[dry-run] Would set $RAILWAY_VAR on Railway service '$RAILWAY_SERVICE'."
  exit 0
fi

# ── Push to Railway (encrypted at rest) ───────────────
echo ""
echo "Setting $RAILWAY_VAR on Railway..."

railway variables set "$RAILWAY_VAR=$CREDS" --service "$RAILWAY_SERVICE" 2>&1 | \
  grep -v -i "token\|secret\|password\|credential" || true

echo "Credentials synced to Railway."

# ── Restart service ───────────────────────────────────
if "$RESTART"; then
  echo "Redeploying $RAILWAY_SERVICE..."
  railway service redeploy --service "$RAILWAY_SERVICE" --yes 2>&1 || {
    echo "WARNING: Redeploy command failed. The env var is set — the next deploy will pick it up." >&2
  }
  echo "Done. Service is redeploying with fresh credentials."
else
  echo "Done. Credentials will take effect on next deploy."
fi
