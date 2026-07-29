#!/usr/bin/env bash
# Boot check: print which identity the agent will read company data as, and refuse
# personal accounts. The lazy path must be the narrow path — if the scoped service
# identity isn't provisioned yet, the fix is provisioning it, not borrowing yours.
set -uo pipefail

echo "── agent environment check ──"

# Template freshness (best effort, never blocks): .devcontainer/TEMPLATE_VERSION
# line 1 = version, line 2 = "<owner>/<repo> <path-in-repo>". Compared against
# the same file on the source repo's default branch via api.github.com (in the
# gateway base allowlist; GITHUB_TOKEN needed for private sources). Any failure
# is silent — this is a nag, not a gate.
VFILE="$(dirname "${BASH_SOURCE:-$0}")/TEMPLATE_VERSION"
if [ -f "$VFILE" ] && [ -n "${GITHUB_TOKEN:-}" ]; then
  t_local=$(sed -n 1p "$VFILE")
  t_src=$(sed -n 2p "$VFILE")
  t_slug=${t_src%% *}; t_path=${t_src#* }; t_path=${t_path%/}; [ "$t_path" = "." ] && t_path="" || t_path="$t_path/"
  t_up=$(curl -sf --max-time 4 -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github.raw" \
    "https://api.github.com/repos/${t_slug}/contents/${t_path}.devcontainer/TEMPLATE_VERSION" 2>/dev/null | sed -n 1p)
  if [ -n "$t_up" ] && [ "$t_up" != "$t_local" ]; then
    echo "WARN: devcontainer template ${t_local} — upstream is ${t_up}. Run 'sandbox sync' on the host, review the diff, commit."
  fi
fi

# Plugin freshness — refresh-always: marketplace metadata + installed plugins
# update BEFORE the session exists, so Claude's "restart required to apply" is
# satisfied by construction. The consent boundary for a rules/behavior change
# is the marketplace PR (reviewed there); attended sessions lose only the
# update-nag click, unattended runs gain currency they otherwise never get.
# Best-effort with hard timeouts: offline = run cached versions, say so.
if command -v claude >/dev/null 2>&1 && command -v node >/dev/null 2>&1; then
  if timeout -k 5 25 claude plugin marketplace update </dev/null >/dev/null 2>&1; then
    updated=""
    while read -r pid pscope; do
      [ -n "$pid" ] || continue
      out=$(timeout -k 5 25 claude plugin update "$pid" --scope "$pscope" </dev/null 2>&1) || continue
      printf '%s' "$out" | grep -qiE 'already|up.to.date|latest' || updated="$updated $pid"
    done < <(timeout -k 5 15 claude plugin list --json </dev/null 2>/dev/null | node -e '
      let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{
        try{ for (const p of JSON.parse(d)) if (p.enabled && p.id && p.scope) console.log(p.id, p.scope) }catch(e){}
      })')
    if [ -n "$updated" ]; then
      echo "plugins: updated${updated} — applied for this session"
    else
      echo "plugins: marketplace refreshed, all current"
    fi
  else
    echo "plugins: refresh skipped (offline?) — running cached versions"
  fi
fi

# First-run wizard skip: when Claude auth comes from the environment, seed the
# onboarding flag on a fresh volume so interactive claude goes straight to the
# prompt instead of forcing the login wizard (which ignores env tokens).
if [ ! -f "$HOME/.claude/.claude.json" ] && \
   { [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] || [ -n "${ANTHROPIC_API_KEY:-}" ] || [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]; }; then
  mkdir -p "$HOME/.claude" && \
    echo '{"hasCompletedOnboarding":true}' > "$HOME/.claude/.claude.json" && \
    echo "claude: onboarding pre-seeded (env auth — no first-run wizard)"
fi

# In-box sessions default to auto mode — autonomy lives in the sandbox (host
# stays prompts-on via managed settings). Repo settings can't grant auto mode
# (by design); user scope in the volume can. Merged once, user-overridable.
mkdir -p "$HOME/.claude"
# HUD statusline wrapper — lives in the volume so every repo sandbox shares it.
# Resolves claude-hud from git-marketplace cache (versioned copies) OR from
# directory-source marketplaces, which run plugins in place with no cache copy.
# Rewritten every boot so wrapper fixes propagate.
cat > "$HOME/.claude/hud-statusline.sh" <<'HUD'
#!/usr/bin/env bash
cols=${COLUMNS:-120}
export COLUMNS=$(( cols > 4 ? cols - 4 : 116 ))
cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
d=$(ls -d "$cfg"/plugins/cache/*/claude-hud/*/ "$cfg"/plugins/cache/*/claude-hud/ 2>/dev/null | sort -V | tail -1)
if [ -z "$d" ] || [ ! -f "${d}dist/index.js" ]; then
  d=$(node -e '
    const fs=require("fs"),cfg=process.env.CLAUDE_CONFIG_DIR||process.env.HOME+"/.claude";
    try{const m=JSON.parse(fs.readFileSync(cfg+"/plugins/known_marketplaces.json","utf8"));
      for(const k in m){const p=(m[k].installLocation||"")+"/plugins/claude-hud/";
        if(fs.existsSync(p+"dist/index.js")){console.log(p);break}}}catch{}' 2>/dev/null)
fi
[ -n "$d" ] && [ -f "${d}dist/index.js" ] && exec node "${d}dist/index.js"
exit 0
HUD
chmod +x "$HOME/.claude/hud-statusline.sh"
node -e '
  const fs=require("fs"),f=process.env.HOME+"/.claude/settings.json";
  let s={};try{s=JSON.parse(fs.readFileSync(f,"utf8"))}catch{}
  const msgs=[];
  s.permissions=s.permissions||{};
  if(!s.permissions.defaultMode){s.permissions.defaultMode="auto";
    msgs.push("claude: default permission mode set to auto (volume user settings)")}
  if(!s.statusLine){
    s.statusLine={type:"command",command:"bash "+process.env.HOME+"/.claude/hud-statusline.sh"};
    msgs.push("claude: HUD statusline wired")}
  if(msgs.length){fs.writeFileSync(f,JSON.stringify(s,null,2)+"\n");msgs.forEach(m=>console.log(m))}
' 2>/dev/null || true
if command -v codex >/dev/null; then
  cfg="$HOME/.codex/config.toml"
  if ! grep -q '^approval_policy' "$cfg" 2>/dev/null; then
    # Top-level TOML keys must precede any [table] sections — prepend.
    { printf 'approval_policy = "on-failure"\nsandbox_mode = "workspace-write"\n\n'; cat "$cfg" 2>/dev/null; } > "$cfg.tmp" \
      && mv "$cfg.tmp" "$cfg" \
      && echo "codex: defaults set to full-auto (workspace-write, approve on-failure)"
  fi
fi

# Egress containment self-check: the box is closed by the docker topology (the
# workload has no internet route except the gateway proxy), so prove it on every
# boot — an allowlisted host must be reachable, a non-allowlisted one must not.
# A warm container that came up without the gateway fails the second test here
# instead of leaking mid-task. curl routes through the gateway via HTTPS_PROXY.
if command -v curl >/dev/null; then
  if curl -s --max-time 10 -o /dev/null https://api.anthropic.com; then
    echo "egress: gateway reachable (api.anthropic.com allowed)"
  else
    echo "egress WARNING: allowlisted host unreachable — gateway down or misconfigured"
  fi
  if curl -s --max-time 6 -o /dev/null https://example.com 2>/dev/null; then
    echo "egress WARNING: default-deny NOT active (example.com reachable) — containment breached"
  else
    echo "egress: default-deny active (non-allowlisted host blocked)"
  fi
fi

# LLM auth preflight — vendor logins expire; fail before the task starts, not
# mid-run. AGENT_REQUIRE_AUTH=1 (unattended repos/CI) turns warnings into exit 1.
auth_missing=0

if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] || [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ] || [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  echo "claude: token/gateway auth from environment"
elif claude auth status 2>/dev/null | grep -q '"loggedIn": *true'; then
  echo "claude: logged in (volume)"
else
  echo "claude: NOT authenticated — run 'claude login' once (attended); the volume persists it"
  auth_missing=1
fi

# Cross-vendor status (present only when the repo opted in via EXTRA_ALLOWED_DOMAINS)
if command -v codex >/dev/null; then
  if [ -n "${OPENAI_API_KEY:-}" ]; then
    echo "codex: API-key auth from environment"
  elif codex login status >/dev/null 2>&1; then
    echo "codex: logged in (volume)"
  else
    echo "codex: NOT authenticated — run 'codex login' once (attended) before unattended runs"
    auth_missing=1
  fi
fi

if [ "$auth_missing" = 1 ] && [ "${AGENT_REQUIRE_AUTH:-0}" = "1" ]; then
  echo "REFUSED: AGENT_REQUIRE_AUTH=1 and a vendor login is missing/expired (see above)."
  exit 1
fi

# GitHub identity — PR/commit delegation runs as this principal; make it visible.
if [ -n "${GITHUB_TOKEN:-}" ]; then
  # Token TYPE gate: fine-grained PATs (github_pat_*) are org-scopable — bound
  # to one resource owner, can't write outside it, forced expiry. Classic PATs
  # (ghp_*) grant every repo the account can reach and never expire: a leaked
  # one is the account. OAuth app tokens (gho_*) are a person, not a bot.
  case "$GITHUB_TOKEN" in
    github_pat_*) echo "github: fine-grained PAT (org-scopable) — good" ;;
    ghp_*)  echo "WARN: classic PAT detected — cannot be limited to the org; use a fine-grained PAT (resource owner: your org, selected repos, forced expiry)" ;;
    gho_*)  echo "WARN: OAuth user token detected — this is a personal login, not a bot credential" ;;
    *)      echo "github: unrecognized token format — verify it is a fine-grained PAT or app installation token" ;;
  esac
  gh_login=$(curl -s --max-time 10 -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    https://api.github.com/user | grep -o '"login": *"[^"]*"' | head -1 | cut -d'"' -f4)
  if [ -n "$gh_login" ]; then
    echo "github: PRs/commits will run as '${gh_login}'"
    # Wire git push over HTTPS through the same token (idempotent).
    command -v gh >/dev/null && gh auth setup-git >/dev/null 2>&1 || true
  else
    echo "WARN: GITHUB_TOKEN set but identity could not be verified — git/gh calls will fail the same way"
  fi
fi

if [ -z "${ATLASSIAN_AGENT_TOKEN:-}" ]; then
  echo "profile: base (no MCP data sources wired) — agent reaches code + allowlisted registries only"
  exit 0
fi

: "${ATLASSIAN_URL:?with-atlassian variant needs ATLASSIAN_URL (e.g. https://yourorg.atlassian.net)}"
: "${ATLASSIAN_AGENT_EMAIL:?with-atlassian variant needs ATLASSIAN_AGENT_EMAIL (the service account)}"

# Who does this token actually authenticate as?
me=$(curl -s --max-time 10 -u "${ATLASSIAN_AGENT_EMAIL}:${ATLASSIAN_AGENT_TOKEN}" \
  "${ATLASSIAN_URL}/rest/api/2/myself" 2>/dev/null)
name=$(printf '%s' "$me" | grep -o '"displayName":"[^"]*"' | head -1 | cut -d'"' -f4)
email=$(printf '%s' "$me" | grep -o '"emailAddress":"[^"]*"' | head -1 | cut -d'"' -f4)

if [ -z "$name" ]; then
  echo "WARN: could not verify the Atlassian identity (network or credentials)."
  echo "      MCP calls will fail the same way — fix before an unattended run."
  exit 0
fi

echo "agent reads Jira/Confluence as: ${name} <${email:-unknown}>"

# Service accounts match AGENT_IDENTITY_PATTERN (default: svc-/bot-/agent- prefix or +agent alias).
PATTERN="${AGENT_IDENTITY_PATTERN:-^(svc|bot|agent)[-._]|\\+agent@}"
if printf '%s\n' "$email" | grep -Eqi "$PATTERN"; then
  echo "identity check: service account — ok"
else
  echo ""
  echo "REFUSED: '${email}' does not look like a scoped service account."
  echo "A personal token in an unattended container reads everything YOU can read."
  echo "Provision a read-only, space-allowlisted service identity instead."
  echo "(override for a supervised experiment: AGENT_ALLOW_PERSONAL=1)"
  [ "${AGENT_ALLOW_PERSONAL:-0}" = "1" ] || exit 1
  echo "override active: AGENT_ALLOW_PERSONAL=1 — do NOT leave this on for unattended runs"
fi
