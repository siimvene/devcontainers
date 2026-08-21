#!/usr/bin/env bash
# Opt-in cross-vendor tooling (Codex CLI for cross-vendor Claude+Codex repos).
# Gated on the egress decision: if the repo's EXTRA_ALLOWED_DOMAINS doesn't name
# an OpenAI domain, the second vendor was not chosen — install nothing.
# npm reaches registry.npmjs.org through the gateway (allowlisted in the base
# set), so the install works under the default-deny egress policy.
set -euo pipefail

case "${EXTRA_ALLOWED_DOMAINS:-}" in
  *openai.com*|*chatgpt.com*) ;;
  *)
    echo "cross-vendor: not enabled (no OpenAI domain in EXTRA_ALLOWED_DOMAINS) — skipping"
    exit 0 ;;
esac

if command -v codex >/dev/null; then
  echo "cross-vendor: codex already installed ($(codex --version 2>/dev/null || echo unknown))"
else
  echo "cross-vendor: installing Codex CLI"
  npm install -g @openai/codex >/dev/null
  echo "cross-vendor: codex $(codex --version 2>/dev/null || echo '?') installed"
fi

# Auth persists in the agent-codex-config volume; first run on a fresh volume
# needs a one-time `codex login` (browser flow) from an attended session.
if [ -f "$HOME/.codex/auth.json" ]; then
  echo "cross-vendor: codex auth present (volume)"
else
  echo "cross-vendor: no codex auth yet — run 'codex login' once (attended) to seed the volume"
fi
