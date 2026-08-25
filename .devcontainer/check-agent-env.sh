#!/usr/bin/env bash
# Boot check: print which identity the agent will read company data as, and warn
# on personal accounts. Personal tokens are acceptable (owner policy); the nag
# stays because a scoped service identity is still the right shape for fleets.
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
  # Ordered, not != : versions are zero-padded ISO dates (+letter), so string
  # order IS version order. A repo AHEAD of the distribution point (template
  # development, a PR branch) must stay silent — the old inequality check told
  # exactly those repos to 'sandbox sync', which rolls the template BACK.
  if [ -n "$t_up" ] && [[ "$t_up" > "$t_local" ]]; then
    echo "WARN: devcontainer template ${t_local} — upstream is ${t_up}. Run 'sandbox sync' on the host, review the diff, commit."
  fi
fi

# CRLF-worktree tripwire (Windows hosts): the host cloned with core.autocrlf=true,
# so the bind-mounted files carry CRLF while the index holds LF — and git in here
# converts nothing, so EVERY tracked file reads as modified and the agent can no
# longer find its own diff (measured: 811 "changed", 796 pure line-ending noise).
# Warn only, deliberately: setting core.autocrlf or renormalizing from inside the
# container would rewrite the host developer's checkout through the bind mount.
if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  # Index-LF vs worktree-CRLF, split by which harm applies, because the two halves
  # of the repo-side fix land separately and the symptoms are not the same:
  # Three states, because both the symptom and the cure differ between them:
  #   noisy  — no text attribute at all. Git converts nothing, so it reports every
  #            file as modified (measured on a real repo: 811 reported, 796 noise).
  #   nopolicy — 'text=auto' but no 'eol=lf'. Git normalizes on read, so `git diff`
  #            is clean; the CRLF bytes stay on disk and break shebangs. A plain
  #            refresh is NOT enough here — under host core.autocrlf=true it just
  #            re-checks them out as CRLF, so the eol=lf half has to land first.
  #   stale  — eol=lf is in effect but the worktree was never refreshed. Same
  #            broken-shebang symptom, and a refresh alone does fix it.
  # Files git is TOLD to keep CRLF (attr eol=crlf, or stored CRLF in the index like
  # sandbox.cmd) are intentional — never counted.
  # Timeout-bounded: ls-files --eol reads every tracked file's content, ~8s on a
  # large tree over a Windows bind mount, and this runs in postStartCommand.
  # Split on TAB: git prints "i/x w/y attr/..." as one blob, then a tab, then the
  # path — and the attr blob can hold several space-separated tokens, so matching
  # on a whitespace-split field would only ever see its first token.
  eol_counts=$(timeout -k 5 20 git ls-files --eol 2>/dev/null | awk -F'\t' '
    $1 ~ /^i\/lf[[:space:]]/ && $1 ~ /w\/crlf/ && $1 !~ /eol=crlf/ {
      if ($1 ~ /eol=lf/) stale++; else if ($1 ~ /text/) nopolicy++; else noisy++
    }
    END { printf "%d %d %d", noisy+0, nopolicy+0, stale+0 }') || true
  # Parameter expansion, not `set --`: this script runs under `set -u`, where a
  # short split would leave $2/$3 unbound and abort the whole boot check. awk's
  # END always prints three integers; an empty value means the pipeline failed.
  case $eol_counts in ''|*[!0-9\ ]*) eol_counts="0 0 0" ;; esac
  noisy=${eol_counts%% *}; eol_rest=${eol_counts#* }
  nopolicy=${eol_rest%% *}; stale=${eol_rest##* }
  eol_fix="commit a root .gitattributes '* text=auto eol=lf', then refresh the worktree from a clean"
  eol_fix2="tree ('git rm --cached -r . && git reset --hard'). See WINDOWS.md 'Line endings'."
  if [ "${noisy:-0}" -gt 0 ]; then
    echo "WARN: $noisy tracked files are CRLF in the worktree with no eol policy — in-container 'git diff'"
    echo "      reports them ALL as modified, burying the real changes. Fix in the repo, from the host:"
    echo "      $eol_fix"
    echo "      $eol_fix2"
  elif [ "${nopolicy:-0}" -gt 0 ]; then
    echo "WARN: $nopolicy tracked files hold CRLF bytes under a 'text' attribute with no eol=lf — 'git diff'"
    echo "      looks clean, but shebang scripts fail in here with 'bad interpreter: /bin/sh^M'. A refresh"
    echo "      alone won't hold while the host has core.autocrlf=true. From the host: $eol_fix"
    echo "      $eol_fix2"
  elif [ "${stale:-0}" -gt 0 ]; then
    echo "WARN: $stale tracked files still hold CRLF bytes though .gitattributes says eol=lf — 'git diff' looks"
    echo "      clean, but shebang scripts fail in here with 'bad interpreter: /bin/sh^M'. Finish the fix on"
    echo "      the host: 'git rm --cached -r . && git reset --hard'. See WINDOWS.md 'Line endings'."
  fi
fi

# Supply-chain age gate: userland packages younger than 30 days are the
# Shai-Hulud-class worm attack window — refuse them by default.
# Keys: min-release-age (npm, DAYS as a bare number), minimum-release-age (pnpm,
# MINUTES; npm warns unknown-key and proceeds), bunfig minimumReleaseAge (bun).
# The npm value must not carry a unit suffix: npm >= 11.6 validates it as
# "null | numeric value" and a "30d" both fails the gate AND breaks every npm
# command with "Invalid time value" — verified on npm 11.17. Older npm (the
# image currently ships 10.9.8) does not know the key at all and only warns, so
# npm-side enforcement starts when a repo upgrades its own npm.
# Toolchain itself is exempt by design — this gates project installs, not the image.
# Both files on purpose: with NPM_CONFIG_USERCONFIG set (compose points it into
# the per-machine volume) npm reads ONLY that file and ignores ~/.npmrc — while
# pnpm's config chain still consults ~/.npmrc. Appending the missing keys to
# both keeps the gate on whichever file a given tool resolves.
for rc in "$HOME/.npmrc" ${NPM_CONFIG_USERCONFIG:+"$NPM_CONFIG_USERCONFIG"}; do
  mkdir -p "$(dirname "$rc")" 2>/dev/null || true
  for k in "min-release-age=30" "minimum-release-age=43200"; do
    grep -qx "$k" "$rc" 2>/dev/null || echo "$k" >> "$rc"
  done
done
if command -v bun >/dev/null 2>&1 && ! grep -q "minimumReleaseAge" "$HOME/.bunfig.toml" 2>/dev/null; then
  # Never append a second [install]: TOML forbids redeclaring a table, and an
  # unparseable bunfig breaks every later bun command. Add the key under the
  # existing table when there is one, otherwise create the table.
  if grep -q '^\[install\]' "$HOME/.bunfig.toml" 2>/dev/null; then
    awk '{print} /^\[install\]/ && !d {print "minimumReleaseAge = \"30d\""; d=1}' \
      "$HOME/.bunfig.toml" > "$HOME/.bunfig.toml.tmp" && mv "$HOME/.bunfig.toml.tmp" "$HOME/.bunfig.toml"
  else
    printf '[install]\nminimumReleaseAge = "30d"\n' >> "$HOME/.bunfig.toml"
  fi
fi
echo "supply-chain: 30-day release-age gate configured (pnpm/bun enforce it; npm from 11.6)"

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
# Merge, never create-if-absent: the plugin refresh above is itself a `claude`
# invocation and already wrote .claude.json (firstStartTime, no onboarding key),
# so an existence guard here is dead code on exactly the fresh machine it was
# written for. Env-auth gate stays: on the IDE path there are no session secrets
# and the wizard is wanted — it's how the user runs 'claude login' once.
if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] || [ -n "${ANTHROPIC_API_KEY:-}" ] || [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]; then
  mkdir -p "$HOME/.claude"
  node -e '
    const fs=require("fs"),f=process.env.HOME+"/.claude/.claude.json";
    // Absent and unparseable must not collapse into the same branch: this file
    // lives in the machine-wide agent-claude-config volume and holds the vendor
    // login plus per-project trust. Rewriting it wholesale on a parse error
    // would destroy that for EVERY repo on the machine, permanently. Missing =
    // seed; corrupt = say so and touch nothing.
    let raw=null;try{raw=fs.readFileSync(f,"utf8")}catch{}
    let c={};
    if(raw!==null){try{c=JSON.parse(raw)}catch{
      console.log("WARN: ~/.claude/.claude.json is unparseable — leaving it alone; expect the first-run wizard");
      process.exit(0)}}
    if(c.hasCompletedOnboarding!==true){c.hasCompletedOnboarding=true;
      // Write to a temp file and rename: rename is atomic, so a concurrent
      // sandbox start on the same machine (this volume is shared) or a crash
      // mid-write can never leave a half-written .claude.json behind. A
      // truncating write in place can, and the vendor login lives here.
      // Random suffix, not the pid: containers have their own PID namespaces, so
      // two simultaneous starts can BOTH be pid 42 and interleave into one temp
      // path — which would corrupt the very file this is protecting.
      // Residual, accepted: two concurrent writers can still drop one unrelated
      // edit (last rename wins). Claude rewrites this file itself constantly, so
      // a lost key comes back; a truncated file would not.
      // No apostrophes in here: this whole program is a single-quoted shell
      // string, and one would terminate it.
      const t=f+".tmp-"+require("crypto").randomBytes(6).toString("hex");
      fs.writeFileSync(t,JSON.stringify(c,null,2)+"\n");
      fs.renameSync(t,f);
      console.log("claude: onboarding pre-seeded (env auth — no first-run wizard)")}
  ' 2>/dev/null || true
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
  // Absent and unparseable must not collapse into the same branch (same
  // contract as the .claude.json seeder above): rewriting a corrupt file as
  // {} would destroy every user setting in the shared volume. Missing =
  // start fresh; corrupt = say so and touch nothing.
  let raw=null;try{raw=fs.readFileSync(f,"utf8")}catch{}
  let s={};
  if(raw!==null){try{s=JSON.parse(raw)}catch{
    console.log("WARN: ~/.claude/settings.json is unparseable — leaving it alone; defaultMode/statusLine not reconciled");
    process.exit(0)}}
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
    # Unconditional: a proven-open box must never launch. Gateway-down above is
    # warn-only (fail-closed for the agent); this is the opposite failure.
    echo "REFUSED: default-deny NOT active (example.com reachable) — containment breached; fix the gateway topology before launching"
    exit 1
  else
    echo "egress: default-deny active (non-allowlisted host blocked)"
  fi
  # Second axis: the deny above was answered BY the proxy, so it proves the
  # filter, not the topology. A workload with a direct route (e.g. a dormant
  # `networks: [egress]` in an override) would still pass it — probe once more
  # bypassing the proxy; in a contained workload this has no route and fails.
  if curl -s --noproxy '*' --max-time 6 -o /dev/null https://example.com 2>/dev/null; then
    echo "REFUSED: workload has a DIRECT internet route (example.com reachable without the proxy) — the gateway boundary is bypassed; fix the compose topology before launching"
    exit 1
  else
    echo "egress: no direct route (proxy is the only path out)"
  fi
elif [ "${AGENT_REQUIRE_AUTH:-0}" = "1" ]; then
  # The image ships curl; its absence in an unattended workload means the layer
  # was tampered with. Refuse rather than skip the containment probes silently.
  echo "REFUSED: curl is missing — cannot verify egress containment for an unattended run (AGENT_REQUIRE_AUTH=1)"
  exit 1
else
  echo "WARN: curl missing — egress containment not verified"
fi

# Sandbox-immutability tripwire: a container created before the template gained
# the read-only .devcontainer overlay keeps a WRITABLE .devcontainer through the
# bind mount — an agent write there runs on the HOST at the next up
# (initializeCommand). 'sandbox' self-heals this by recreating, but IDE-launched
# warm containers reach this check with the old topology intact — so probe the
# actual behavior (can THIS user write?) and refuse, same class as proven-open
# egress above.
selfdir=$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)
# mktemp with a random suffix, not a predictable $$ name: an agent in an OLD
# writable container could pre-plant .rw-probe.<pid> so a create fails and we
# mis-read that as read-only. mktemp CREATES the file (fails only when the dir
# rejects writes) and the name is unguessable, so a successful create is proof
# the dir is writable → refuse.
if rwprobe=$(mktemp "$selfdir/.rw-probe.XXXXXX" 2>/dev/null); then
  rm -f "$rwprobe"
  echo "REFUSED: .devcontainer is WRITABLE from the workload — an agent write here is host code execution at the next relaunch; recreate the container ('sandbox rebuild' on the host) to pick up the read-only mount"
  exit 1
fi

# Credential-shape tripwires: catch host-side resolution failures HERE with a
# name, instead of letting auth fail downstream with generic 401s/login links.
# Unattended (AGENT_REQUIRE_AUTH=1) a tripwire hit is fatal — the credential
# WILL fail downstream, so failing here with a name is the whole point.
cred_tripwire=0
for v in CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN OPENAI_API_KEY GITHUB_TOKEN ATLASSIAN_AGENT_TOKEN; do
  val=$(eval "printf '%s' \"\${$v:-}\"")
  [ -z "$val" ] && continue
  case "$val" in
    op://*) echo "WARN: $v is an UNRESOLVED op:// reference — 1Password resolution failed on the host (op CLI missing, locked, or not integrated); launch via 'sandbox', not directly"; cred_tripwire=1 ;;
  esac
  if printf '%s' "$val" | grep -q "$(printf '\r')"; then
    echo "WARN: $v contains a carriage return — the host env file was saved with Windows line endings; re-save ~/.agent/agent.env with LF (or rerun 'sandbox init')"
    cred_tripwire=1
  fi
done
if [ "$cred_tripwire" = 1 ] && [ "${AGENT_REQUIRE_AUTH:-0}" = "1" ]; then
  echo "REFUSED: AGENT_REQUIRE_AUTH=1 and a credential failed the shape tripwires (see above)."
  exit 1
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
elif [ -n "${OPENAI_API_KEY:-}" ]; then
  # OPENAI_API_KEY set but codex absent = the cross-vendor install failed
  # (setup-cross-vendor.sh warns, does not abort). The repo intends a second
  # vendor; an unattended run must fail here, not discover it mid-task.
  echo "codex: NOT installed but OPENAI_API_KEY is set — cross-vendor tooling missing (install failed?)"
  auth_missing=1
fi

if [ "$auth_missing" = 1 ] && [ "${AGENT_REQUIRE_AUTH:-0}" = "1" ]; then
  echo "REFUSED: AGENT_REQUIRE_AUTH=1 and a vendor login is missing/expired (see above)."
  exit 1
fi

# Live credential validation (unattended only): presence is not validity —
# tokens expire and revoke silently, and an unattended run then burns its whole
# budget on 401s. One cheap curl per PRESENT token, against hosts already in
# the gateway base allowlist. A definitive vendor rejection (401) is fatal;
# 403 is NOT one — GitHub answers 403 on valid tokens (endpoint out of scope,
# secondary rate limits) — and no response is warn-only; gateway health is the
# egress check's job, not this one's. Deliberately NOT probed: CLAUDE_CODE_OAUTH_TOKEN (not a raw API
# credential — a 401 here would be a false negative) and OPENAI_API_KEY
# (api.openai.com is not in the base allowlist).
if [ "${AGENT_REQUIRE_AUTH:-0}" = "1" ] && ! command -v curl >/dev/null; then
  # curl gone in an unattended workload = tampering; don't skip validation silently.
  echo "REFUSED: curl is missing — cannot live-validate credentials for an unattended run (AGENT_REQUIRE_AUTH=1)"
  exit 1
fi
if [ "${AGENT_REQUIRE_AUTH:-0}" = "1" ] && command -v curl >/dev/null; then
  # ANTHROPIC_BASE_URL rewires the Anthropic credentials to a different
  # gateway — a vendor 401 would then be a false negative that bricks a valid
  # boot, and the gateway host is not in the base allowlist. Skip those probes.
  case "${ANTHROPIC_BASE_URL:-}" in ''|https://api.anthropic.com|https://api.anthropic.com/) anth_direct=1 ;; *) anth_direct=0 ;; esac
  # GitHub probes /rate_limit, not /user: app installation tokens (ghs_*) — the
  # natural unattended credential — 403 on /user by design; /rate_limit answers
  # every valid shape and still 401s a bad one.
  for spec in "ANTHROPIC_API_KEY|https://api.anthropic.com/v1/models|x-api-key" \
              "ANTHROPIC_AUTH_TOKEN|https://api.anthropic.com/v1/models|Authorization: Bearer" \
              "GITHUB_TOKEN|https://api.github.com/rate_limit|Authorization: Bearer"; do
    v=${spec%%|*}; rest=${spec#*|}; url=${rest%%|*}; hdr=${rest#*|}
    case "$url" in *api.anthropic.com*) [ "$anth_direct" = 1 ] || continue ;; esac
    val=$(eval "printf '%s' \"\${$v:-}\"")
    [ -z "$val" ] && continue
    if [ "$hdr" = "x-api-key" ]; then hdr="x-api-key: $val"; else hdr="$hdr $val"; fi
    # anthropic-version is required by the Anthropic API and ignored by GitHub.
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
      -H "$hdr" -H "anthropic-version: 2023-06-01" "$url")
    case "$code" in
      401)     echo "REFUSED: $v rejected by ${url#https://} (HTTP 401) — expired or revoked; rotate it before an unattended run"; exit 1 ;;
      403)     echo "WARN: $v answered 403 on ${url#https://} — not proof of revocation (scope or a secondary rate limit); verify manually if downstream auth fails" ;;
      2??)     echo "auth: $v accepted by ${url#https://}" ;;
      *)       echo "WARN: $v not validated (${url#https://} answered HTTP ${code:-000}) — see the egress check above for gateway health" ;;
    esac
  done
fi

# GitHub identity — PR/commit delegation runs as this principal; make it visible.
if [ -n "${GITHUB_TOKEN:-}" ]; then
  # Token TYPE gate: fine-grained PATs (github_pat_*) are org-scopable — bound
  # to one resource owner, can't write outside it, forced expiry. Classic PATs
  # (ghp_*) grant every repo the account can reach and never expire: a leaked
  # one is the account. OAuth app tokens (gho_*) are a person, not a bot.
  # The counterweight: GitHub Packages accepts only classic/OAuth tokens, so
  # on a repo with private npm/maven deps a fine-grained PAT E403s at install
  # — neither shape wins on both axes; say the tradeoff out loud.
  case "$GITHUB_TOKEN" in
    github_pat_*) echo "github: fine-grained PAT (org-scopable) — good for git/API; NOTE: GitHub Packages rejects this shape — private npm/maven installs need a classic/OAuth token with read:packages" ;;
    ghp_*)  echo "WARN: classic PAT detected — required for GitHub Packages but cannot be limited to the org; keep scopes minimal (read:packages + repo) with forced expiry" ;;
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
  # Builds that pull private packages (GitHub Packages maven/npm) read the
  # username from GITHUB_USER; gradle's credentials{} fails on a null username
  # even though the registry only checks the token.
  [ -z "${GITHUB_USER:-}" ] && \
    echo "note: GITHUB_USER not set — private package registries need it as basic-auth username; rerun 'sandbox init' on the host to capture it"

  # IDE sessions (java variant): env-injected credentials exist only in
  # wrapper-launched sessions, but builds started from IntelliJ/VS Code read
  # ~/.gradle/gradle.properties in the persisted gradle volume. Materialize the
  # GitHub Packages pair there so both workflows resolve private deps — same
  # at-rest class as the vendor logins in agent-claude-config. Upsert, never
  # append: token rotation propagates, toolchain lines survive. Username falls
  # back to "token": the registry ignores it, gradle only refuses null.
  if mountpoint -q "$HOME/.gradle" 2>/dev/null; then
    # Same injection refusal as the npm write below: whitespace in the pair
    # would smuggle extra property lines into gradle.properties. `case`, not
    # grep, for the same embedded-newline reason.
    case "${GITHUB_TOKEN}${GITHUB_USER:-}" in *[[:space:]]*) gp_ws=1 ;; *) gp_ws=0 ;; esac
    if [ "$gp_ws" = 1 ]; then
      echo "WARN: GITHUB_TOKEN/GITHUB_USER contains whitespace — gradle credentials NOT written (malformed secret; re-run 'sandbox init')"
    else
      gp="$HOME/.gradle/gradle.properties"
      # chmod the temp file BEFORE the rename: the swap must never expose a
      # world-readable window on the credential.
      { [ -f "$gp" ] && grep -vE '^(githubUser|gitHubPrivateToken|gpr\.user|gpr\.key)=' "$gp" || true
        echo "githubUser=${GITHUB_USER:-token}"
        echo "gitHubPrivateToken=${GITHUB_TOKEN}"
        echo "gpr.user=${GITHUB_USER:-token}"
        echo "gpr.key=${GITHUB_TOKEN}"
      } > "$gp.tmp" && chmod 600 "$gp.tmp" && mv "$gp.tmp" "$gp" \
        && echo "gradle: GitHub Packages credentials written to gradle.properties (volume) — IDE-launched builds resolve private deps"
    fi
  fi

  # npm: same materialization contract. npm never reads GITHUB_TOKEN from the
  # env — GitHub Packages needs an _authToken line in the npm userconfig, which
  # compose points into the per-machine volume (NPM_CONFIG_USERCONFIG), so the
  # credential a wrapper session writes here is what IDE-launched sessions and
  # every `npm ci` read. Token as _authToken, no username (the registry ignores
  # it for npm). Upsert, never append: rotation propagates. The scope→registry
  # mapping (@yourorg:registry=https://npm.pkg.github.com) is REPO config —
  # commit it in the repo's .npmrc; it holds no secret.
  if [ -n "${NPM_CONFIG_USERCONFIG:-}" ] && mountpoint -q "$(dirname "$NPM_CONFIG_USERCONFIG")" 2>/dev/null; then
    case "$GITHUB_TOKEN" in *[[:space:]]*) tok_ws=1 ;; *) tok_ws=0 ;; esac
    if [ "$tok_ws" = 1 ]; then
      # A token with embedded whitespace written verbatim would smuggle extra
      # lines — i.e. arbitrary npm config directives — into the userconfig.
      # Tokens never legitimately contain whitespace; refuse, don't sanitize.
      # `case`, not grep: grep reads line-by-line, so the one character that
      # matters most (an embedded newline) is a separator it never sees.
      echo "WARN: GITHUB_TOKEN contains whitespace — npm credential NOT written (malformed secret; re-run 'sandbox init')"
    else
      nrc="$NPM_CONFIG_USERCONFIG"
      # Random tmp suffix, not a fixed name or $$: this file sits in the shared
      # machine volume and containers have their own PID namespaces, so two
      # concurrent sandbox starts can both be pid 42 (same reasoning as the
      # .claude.json seeder). Rename stays atomic within the volume.
      ntmp="$nrc.tmp-$(head -c6 /dev/urandom | od -An -tx1 | tr -d ' \n')"
      { [ -f "$nrc" ] && grep -v '^//npm\.pkg\.github\.com/:_authToken=' "$nrc" || true
        echo "//npm.pkg.github.com/:_authToken=${GITHUB_TOKEN}"
      } > "$ntmp" && chmod 600 "$ntmp" && mv "$ntmp" "$nrc" \
        && echo "npm: GitHub Packages credential written to npm userconfig (volume) — private-scope installs resolve on both launch paths"
    fi
  else
    # The guard holds today; this line exists so a future regression (override
    # unsetting the var, base image dropping `mountpoint`, volume not mounted)
    # surfaces here instead of as an unexplained E401 mid-`npm ci` — same
    # contract as the plugins NOT-added message below.
    echo "WARN: npm credential NOT written — NPM_CONFIG_USERCONFIG unset or not on a mounted volume; private-scope 'npm ci' will fail with E401"
  fi
fi

# Org plugin provisioning — marketplaces and baseline plugins live in the
# per-MACHINE volume, so a fresh machine has neither no matter how many repos
# it clones. Add what the repo declares (compose x-plugin-* anchors) and is
# missing. Runs after the github section: private marketplace clones need the
# git credentials `gh auth setup-git` just wired. On IDE-launched sessions
# (no GITHUB_TOKEN) a private add fails with a pointer to `sandbox`; the
# volume keeps whatever the first wrapper session provisions.
if command -v claude >/dev/null 2>&1; then
  mkts_file="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/known_marketplaces.json"
  IFS=','
  for m in ${PLUGIN_MARKETPLACES:-}; do
    m=$(printf '%s' "$m" | tr -d ' '); [ -z "$m" ] && continue
    grep -qs "\"repo\": *\"$m\"" "$mkts_file" && continue
    out=$(timeout -k 5 60 claude plugin marketplace add "$m" </dev/null 2>&1) \
      && echo "plugins: marketplace '$m' added (machine volume)" \
      || printf '%s' "$out" | grep -qi 'already' \
      || echo "plugins: marketplace '$m' NOT added — private repo needs GITHUB_TOKEN; run 'sandbox' once to provision this machine"
  done
  for p in ${PLUGIN_BASELINE:-}; do
    p=$(printf '%s' "$p" | tr -d ' '); [ -z "$p" ] && continue
    # Anchored on the id boundary (name then @marketplace or end-quote): an
    # unanchored substring match let 'foo' shadow 'foo-bar' and skip installs.
    timeout -k 5 15 claude plugin list --json </dev/null 2>/dev/null \
      | grep -qE "\"id\": *\"${p%%@*}[@\"]" && continue
    out=$(timeout -k 5 60 claude plugin install "$p" </dev/null 2>&1) \
      && echo "plugins: '$p' installed (volume)" \
      || printf '%s' "$out" | grep -qi 'already' \
      || echo "plugins: '$p' NOT installed — is its marketplace available (see above)?"
  done
  unset IFS
fi

# ── memspec wiring (optional agent memory) ─────────────────────────────────
# A repo opts in by committing a .memspec.yaml pointer. Two boot-time actions,
# both gated on the pointer + engine, both non-blocking (set -e is off; exit
# codes swallowed so a memory hiccup never fails boot or CI).
memspec_wired=0
if [ -f "$PWD/.memspec.yaml" ]; then
  if command -v memspec >/dev/null 2>&1; then
    memspec_wired=1
    # SessionStart hook — inject memory at session start so agents never have to
    # remember to search. Written to PROJECT-scope .claude/settings.local.json
    # (per-checkout, gitignored) via the same idempotent settings-reconcile
    # idiom this script already uses for statusLine (~/.claude/settings.json) —
    # the native Claude Code `hooks` key, not a bespoke runner. `memspec
    # context` emits a token-budgeted memory digest to stdout, which Claude Code
    # feeds into the session. Set once (deduped by command); safe to re-run.
    node -e '
      const fs=require("fs"),path=require("path");
      const dir=path.join(process.cwd(),".claude"),f=path.join(dir,"settings.local.json");
      // Absent and unparseable must not collapse into the same branch: a
      // corrupt file rewritten as {} would destroy every unrelated setting in
      // it. Missing = start fresh; corrupt = WARN and touch nothing.
      let raw=null;try{raw=fs.readFileSync(f,"utf8")}catch{}
      let s={};
      if(raw!==null){try{s=JSON.parse(raw)}catch{
        console.log("WARN: .claude/settings.local.json is unparseable — memspec SessionStart hook NOT written and the file left untouched; fix the JSON by hand");
        process.exit(0)}}
      const CMD="memspec context";
      s.hooks=s.hooks||{};
      const list=Array.isArray(s.hooks.SessionStart)?s.hooks.SessionStart:[];
      const has=list.some(g=>g&&Array.isArray(g.hooks)&&g.hooks.some(h=>h&&h.command===CMD));
      if(has)process.exit(0);
      list.push({hooks:[{type:"command",command:CMD}]});
      s.hooks.SessionStart=list;
      fs.mkdirSync(dir,{recursive:true});
      const t=f+".tmp-"+require("crypto").randomBytes(6).toString("hex");
      fs.writeFileSync(t,JSON.stringify(s,null,2)+"\n");fs.renameSync(t,f);
      console.log("memspec: SessionStart hook (memspec context) wired via .claude/settings.local.json");
    ' 2>/dev/null || echo "note: memspec SessionStart hook not wired (settings.local.json write failed) — add a SessionStart hook running 'memspec context' by hand"
    # Scratch hygiene nag — boot is the calendar (there is no scheduled sweep).
    # Stale-flagged claims surface as a one-line nag; removal stays operator-run
    # (memspec sweep is interactive, the only path that deletes memories).
    if [ -d "$HOME/.memspec/memory" ]; then
      stale_ct="$(cd "$HOME/.memspec" && timeout -k 5 20 memspec sweep --dry-run 2>/dev/null | grep -c 'ms_')" || stale_ct=0
      if [ "${stale_ct:-0}" -gt 0 ]; then
        echo "note: $stale_ct stale-flagged scratch claim(s) — run 'memspec sweep' (interactive) to retire them"
      fi
    fi
  else
    # engine absent — the pinned postCreate install (setup-memspec.sh) did not
    # run or failed. Single-line note; never blocks.
    echo "note: .memspec.yaml present but 'memspec' CLI not found — memory session injection skipped (expected: pinned install at postCreate)"
  fi
fi
if [ "$memspec_wired" = 0 ] && [ -f "$PWD/.claude/settings.local.json" ] && command -v node >/dev/null 2>&1; then
  # Wiring inactive (pointer removed, never present, or engine absent) but a
  # previous boot may have persisted the SessionStart hook — a broken hook hits
  # every session start; reconcile it away. Same idempotent node idiom as
  # the writer: only OUR exact "memspec context" command entry is removed;
  # unparseable JSON is left untouched (nothing of ours can be reliably found
  # in it, and rewriting would clobber unrelated settings).
  node -e '
    const fs=require("fs"),path=require("path");
    const f=path.join(process.cwd(),".claude","settings.local.json");
    let raw=null;try{raw=fs.readFileSync(f,"utf8")}catch{process.exit(0)}
    let s;try{s=JSON.parse(raw)}catch{process.exit(0)}
    const CMD="memspec context";
    if(!s||!s.hooks||!Array.isArray(s.hooks.SessionStart))process.exit(0);
    let changed=false;
    const kept=[];
    for(const g of s.hooks.SessionStart){
      if(g&&Array.isArray(g.hooks)){
        const hs=g.hooks.filter(h=>!(h&&h.type==="command"&&h.command===CMD));
        if(hs.length!==g.hooks.length){
          changed=true;
          if(hs.length>0){g.hooks=hs;kept.push(g)}
          continue;
        }
      }
      kept.push(g);
    }
    if(!changed)process.exit(0);
    if(kept.length>0)s.hooks.SessionStart=kept;else delete s.hooks.SessionStart;
    if(Object.keys(s.hooks).length===0)delete s.hooks;
    const t=f+".tmp-"+require("crypto").randomBytes(6).toString("hex");
    fs.writeFileSync(t,JSON.stringify(s,null,2)+"\n");fs.renameSync(t,f);
    console.log("memspec: stale SessionStart hook (memspec context) removed from .claude/settings.local.json (memspec wiring inactive)");
  ' 2>/dev/null || true
fi
# ── end memspec wiring ─────────────────────────────────────────────────────

# Ignore hygiene: this boot may write .claude/settings.local.json (the memspec
# hook) and relies on the Claude Code convention that it is gitignored — but
# nothing guarantees the repo actually ignores it, and a committed copy leaks
# machine-local wiring. Enforce LOCALLY via .git/info/exclude (worktree-aware
# via --git-path); never touch the repo's .gitignore — that file is the team's,
# not the template's.
if [ -f "$PWD/.claude/settings.local.json" ] \
   && command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
   && ! git check-ignore -q .claude/settings.local.json 2>/dev/null; then
  excl="$(git rev-parse --git-path info/exclude 2>/dev/null)"
  if [ -n "$excl" ]; then
    mkdir -p "$(dirname "$excl")" 2>/dev/null || true
    echo ".claude/settings.local.json" >> "$excl" 2>/dev/null \
      && echo "git: .claude/settings.local.json added to .git/info/exclude (local-only ignore)" \
      || echo "WARN: .claude/settings.local.json is NOT gitignored and .git/info/exclude could not be written — add it to .gitignore to avoid committing machine-local settings"
  fi
fi

if [ -z "${ATLASSIAN_AGENT_TOKEN:-}" ]; then
  # A truly base repo sets NO Atlassian vars. If URL/email are set but the token
  # is empty, the credential failed to resolve (e.g. an unresolved op:// ref) —
  # that is NOT the base profile; an enabled MCP would fail mid-task.
  if [ -n "${ATLASSIAN_URL:-}" ] || [ -n "${ATLASSIAN_AGENT_EMAIL:-}" ]; then
    if [ "${AGENT_REQUIRE_AUTH:-0}" = "1" ]; then
      echo "REFUSED: ATLASSIAN_URL/EMAIL are set but ATLASSIAN_AGENT_TOKEN is empty — the Atlassian credential did not resolve; fix before an unattended run."
      exit 1
    fi
    echo "WARN: Atlassian URL/email set but token is empty — MCP calls will fail; not treating this as the base profile."
    exit 0
  fi
  echo "profile: base (no MCP data sources wired) — agent reaches code + allowlisted registries only"
  exit 0
fi

: "${ATLASSIAN_URL:?with-atlassian variant needs ATLASSIAN_URL (e.g. https://yourorg.atlassian.net)}"
: "${ATLASSIAN_AGENT_EMAIL:?with-atlassian variant needs ATLASSIAN_AGENT_EMAIL (the service account)}"

# Who does this token actually authenticate as? Capture the HTTP status so a
# rejected credential is distinguishable from a gateway flake — validate the
# CREDENTIAL, the identity below is informational.
me=$(curl -s --max-time 10 -w '\n%{http_code}' -u "${ATLASSIAN_AGENT_EMAIL}:${ATLASSIAN_AGENT_TOKEN}" \
  "${ATLASSIAN_URL}/rest/api/2/myself" 2>/dev/null)
me_code=${me##*$'\n'}
me=${me%$'\n'*}
name=$(printf '%s' "$me" | grep -o '"displayName":"[^"]*"' | head -1 | cut -d'"' -f4)
email=$(printf '%s' "$me" | grep -o '"emailAddress":"[^"]*"' | head -1 | cut -d'"' -f4)

case "$me_code" in
  401|403)
    if [ "${AGENT_REQUIRE_AUTH:-0}" = "1" ]; then
      echo "REFUSED: Atlassian token rejected (HTTP $me_code) — expired or revoked; rotate it before an unattended run."
      exit 1
    fi
    echo "WARN: Atlassian token rejected (HTTP $me_code) — expired or revoked; MCP calls will fail the same way."
    exit 0 ;;
esac

# Only a 2xx makes the response body trustworthy. A non-2xx (5xx, 000, redirect,
# 404) can still carry a stale/cached user-shaped body with "displayName" — do
# NOT let that parse as a valid identity. Indeterminate = fail closed unattended.
case "$me_code" in
  2??) : ;;
  *)
    if [ "${AGENT_REQUIRE_AUTH:-0}" = "1" ]; then
      echo "REFUSED: Atlassian check returned HTTP ${me_code:-000} — credential validity indeterminate; fix before an unattended run."
      exit 1
    fi
    echo "WARN: Atlassian check returned HTTP ${me_code:-000} — credential validity not established; MCP may fail."
    exit 0 ;;
esac

if [ -z "$name" ]; then
  # Indeterminate: timeout, wrong URL (404), 5xx, or an unparseable 2xx body —
  # credential validity was NOT established. Under the unattended contract that
  # is a boot failure (fail here, not mid-task); attended it stays a warning.
  if [ "${AGENT_REQUIRE_AUTH:-0}" = "1" ]; then
    echo "REFUSED: could not establish Atlassian credential validity (HTTP ${me_code:-000} — network, timeout, wrong URL, or unparseable response); an unattended run must not open with unverified MCP auth."
    exit 1
  fi
  echo "WARN: could not verify the Atlassian identity (network or response shape)."
  echo "      MCP calls will fail the same way — fix before an unattended run."
  exit 0
fi

echo "agent reads Jira/Confluence as: ${name} <${email:-unknown}>"

# Service accounts match AGENT_IDENTITY_PATTERN (default: svc-/bot-/agent- prefix or +agent alias).
PATTERN="${AGENT_IDENTITY_PATTERN:-^(svc|bot|agent)[-._]|\\+agent@}"
if printf '%s\n' "$email" | grep -Eqi "$PATTERN"; then
  echo "identity check: service account — ok"
else
  # Personal identities are acceptable (owner policy) — warn, don't gate.
  echo "WARN: '${email}' does not look like a scoped service account."
  echo "      A personal token in an unattended container reads everything YOU can read —"
  echo "      recommend a read-only, space-allowlisted service identity for unattended fleets."
fi
