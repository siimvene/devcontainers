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

# Supply-chain age gate BEFORE the global install it must guard: postStart
# (check-agent-env.sh) writes this same npmrc, but that runs after postCreate —
# too late for the codex install below. Write it here, byte-consistent with the
# postStart version so that later write is a no-op. npm-side enforcement starts
# once the repo's npm is >= 11.6 (the image ships 10.9.8, which only warns).
for rc in "$HOME/.npmrc" ${NPM_CONFIG_USERCONFIG:+"$NPM_CONFIG_USERCONFIG"}; do
  mkdir -p "$(dirname "$rc")" 2>/dev/null || true
  for k in "min-release-age=30" "minimum-release-age=43200"; do
    grep -qx "$k" "$rc" 2>/dev/null || echo "$k" >> "$rc"
  done
done

if command -v codex >/dev/null; then
  echo "cross-vendor: codex already installed ($(codex --version 2>/dev/null || echo unknown))"
else
  echo "cross-vendor: installing Codex CLI"
  # Pinned (repo doctrine forbids unpinned installs); 0.145.0 is the newest stable
  # that clears the 30-day age gate written above — a fresher pin the gate refuses.
  # Guarded: under set -e a registry hiccup here would abort the whole postCreate
  # chain (memspec, gradle toolchains). Degrade to a named warning instead.
  if npm install -g @openai/codex@0.145.0 >/dev/null; then
    echo "cross-vendor: codex $(codex --version 2>/dev/null || echo '?') installed"
  else
    echo "cross-vendor: WARN codex install failed (registry hiccup?) — continuing without it; rerun 'npm i -g @openai/codex@0.145.0'"
  fi
fi

# Auth persists in the agent-codex-config volume; first run on a fresh volume
# needs a one-time `codex login` (browser flow) from an attended session.
if [ -f "$HOME/.codex/auth.json" ]; then
  echo "cross-vendor: codex auth present (volume)"
else
  echo "cross-vendor: no codex auth yet — run 'codex login' once (attended) to seed the volume"
fi
