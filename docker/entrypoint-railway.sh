#!/bin/sh
set -e

# Seed Claude Code credentials from env var if provided
if [ -n "$CLAUDE_CREDENTIALS_JSON" ]; then
  mkdir -p "$HOME/.claude"
  echo "$CLAUDE_CREDENTIALS_JSON" > "$HOME/.claude/.credentials.json"
  echo "[entrypoint] Seeded Claude credentials to $HOME/.claude/.credentials.json"
fi

exec "$@"
