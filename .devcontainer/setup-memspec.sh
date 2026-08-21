#!/usr/bin/env bash
# Install the memspec engine (optional agent memory backend) and initialize the
# container-local scratch store. Runs at postCreate, same layer as
# setup-cross-vendor.sh, so the CLI is present before check-agent-env.sh
# (postStart) wires the session hook and the MCP server launches.
#
# NON-FATAL BY DESIGN: memory is an enhancement, never a boot dependency. Every
# failure path warns and exits 0 — an offline npm registry or a broken native
# build must not brick the sandbox.
#
# Supply-chain: PINNED to an exact version — no range. Bump deliberately and
# review the diff; never float. npm reaches registry.npmjs.org through the
# gateway allowlist (base set). memspec pulls better-sqlite3, a NATIVE module
# that compiles via node-gyp at install — lifecycle/install scripts are REQUIRED,
# so --ignore-scripts is intentionally NOT passed here (it would leave a
# non-functional better-sqlite3). Everything else in the tree is pure JS.

MEMSPEC_VERSION="0.10.0"

if command -v memspec >/dev/null 2>&1 && [ "$(memspec --version 2>/dev/null || echo x)" = "$MEMSPEC_VERSION" ]; then
  echo "memspec: $MEMSPEC_VERSION already installed"
else
  echo "memspec: installing memspec@$MEMSPEC_VERSION (native better-sqlite3 build; scripts required)"
  if npm install -g "memspec@$MEMSPEC_VERSION" >/dev/null 2>&1; then
    echo "memspec: $(memspec --version 2>/dev/null || echo '?') installed"
  else
    echo "WARN: memspec install failed (offline registry or native build error) — memory layer absent this container; boot continues"
    exit 0
  fi
fi

# Container-local scratch store: the agent's writable working memory
# (~/.memspec — the engine's global layer, merged automatically at retrieval).
# Disposable by definition: lives in the container home, never synced, never
# committed. Without a writable layer, `memspec remember` has no target and the
# whole agent write path is dead — this init is what arms it.
# --no-install-hooks is deliberate: memspec init installs a Claude Code
# SessionStart hook GLOBALLY by default, but ~/.claude is the machine-wide
# volume — a global hook would fire for every repo on the machine, opted-in or
# not, and double-inject alongside the per-repo hook check-agent-env.sh writes.
# The opt-in boundary is the committed .memspec.yaml pointer, enforced per-repo
# in the boot check; the hook must never be global.
if [ ! -d "$HOME/.memspec/memory" ]; then
  if memspec init --cwd "$HOME/.memspec" --no-interactive --skip-import --skip-patch --no-install-hooks --search-engine fts5 >/dev/null 2>&1; then
    echo "memspec: scratch store initialized at ~/.memspec (disposable working memory)"
  else
    echo "WARN: memspec scratch-store init failed — agent memory writes will have no target; boot continues"
  fi
else
  echo "memspec: scratch store present at ~/.memspec"
fi
exit 0
