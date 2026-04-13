#!/usr/bin/env bash

set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "Usage: claude-subscription-env.sh <claude-bin> [args...]" >&2
  exit 2
fi

claude_bin="$1"
shift

# This bridge is intentionally subscription-only. Ignore Anthropic API credentials
# so the Claude CLI uses the local first-party auth context instead.
unset ANTHROPIC_API_KEY
unset ANTHROPIC_AUTH_TOKEN
unset ANTHROPIC_BEARER_TOKEN
unset ANTHROPIC_CONSOLE_API_KEY
unset ANTHROPIC_CONSOLE_AUTH_TOKEN

exec "$claude_bin" "$@"
