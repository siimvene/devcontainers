// Writes .devcontainer/.env so compose can interpolate ${SANDBOX_REPO} — compose
// cannot substitute devcontainer variables, so the repo name has to be handed to
// it out of band. Runs on the host as initializeCommand, before any container.
//
// A file, not an inline `node -e` script: the devcontainer CLI spawns a string
// initializeCommand through `cmd.exe /c` (no /s) on Windows, and cmd's legacy
// first/last quote stripping mangles a heavily quoted -e argument. Array form
// plus a real file means no host shell parses anything.
//
// .cjs, not .js, and that extension is load-bearing: node resolves module type
// from the nearest package.json walking up from this file, which lands on the
// CONSUMING repo's. In a `"type": "module"` repo a .js file is ESM, `require`
// throws, and .env is never written — the same wrong-mount failure this file
// exists to prevent, on a repo shape that is common in exactly the JS/TS
// projects this template targets.
//
// Target path is __dirname-based so it lands next to this file regardless of the
// caller's cwd. The repo NAME must stay process.cwd()-derived: the CLI runs
// initializeCommand with cwd = the workspace folder, which is exactly what
// localWorkspaceFolderBasename (and therefore workspaceFolder) resolves from.
// Deriving it from __dirname's parent would silently disagree whenever
// .devcontainer is nested below the workspace root, remounting the repo at a
// path no exec can chdir into.
//
// No fallback and no try/catch on purpose: an unwritable .devcontainer must fail
// loudly and non-zero here. A silent failure leaves compose defaulting the mount
// path, which surfaces much later as "chdir to cwd failed" on every exec.
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

// SANDBOX_VOL_ID names the per-repo node_modules volume. The basename alone is
// wrong twice over: it is not unique (~/org-a/frontend and ~/org-b/frontend
// would share one volume — cross-repo code visibility, and a `compose down -v`
// in one deletes the other's cache) and not guaranteed valid as a docker volume
// name (spaces are legal in checkout dirs, [a-zA-Z0-9_.-] is not negotiable).
// Sanitized basename for legibility, 8 hex of the full-path hash for identity.
//
// Volume identity must also be launch-path invariant. On Windows the drive
// letter's case differs between launchers — the `sandbox` wrapper (Git Bash)
// yields `C:\…`, VS Code/Cursor "Reopen in Container" yields `c:\…` — so
// deriving identity from cwd verbatim splits one repo into two node_modules
// volumes, one per launch path. Normalize exactly the observed variance (the
// drive letter — never case-sensitive) and nothing more: NTFS supports
// per-directory case sensitivity, where `Repo` and `repo` are DISTINCT
// checkouts that whole-path lowercasing would merge onto one volume —
// cross-repo contamination, the very failure this hash exists to prevent.
// POSIX paths are untouched for the same reason. SANDBOX_REPO stays verbatim —
// it becomes the container mount path, which has to match workspaceFolder's
// ${localWorkspaceFolderBasename} casing exactly on the case-sensitive side.
const cwd = process.cwd();
const volCwd = process.platform === 'win32' ? cwd.replace(/^[A-Za-z]:/, (d) => d.toLowerCase()) : cwd;
const repo = path.basename(cwd);
const safe = repo.replace(/[^a-zA-Z0-9_.-]/g, '-').replace(/^[_.-]+/, '') || 'repo';
const volId = `${safe}-${crypto.createHash('sha256').update(volCwd).digest('hex').slice(0, 8)}`;

fs.writeFileSync(
  path.join(__dirname, '.env'),
  `SANDBOX_REPO=${repo}\nSANDBOX_VOL_ID=${volId}\n`
);

// Pre-create the machine-wide volumes compose declares `external: true` (so a
// `compose down -v` in one repo can never delete another repo's vendor logins).
// External volumes are never created by compose, so a fresh machine needs them
// made here — `docker volume create` is idempotent, ~10ms each when they exist.
// The union across variants on purpose: this file is shared, and an unused
// empty volume is harmless while a missing one fails the up. Failure is
// non-fatal by design — if docker itself is broken, compose fails next with
// its own clearer error, and this must not mask it.
const { execFileSync } = require('child_process');
for (const v of [
  'agent-claude-config',
  'agent-codex-config',
  'agent-bash-history',
  'agent-npm-config',
  'agent-gradle-cache',
]) {
  try {
    execFileSync('docker', ['volume', 'create', v], { stdio: 'ignore' });
  } catch {
    console.warn(`write-env: could not pre-create volume ${v} — is docker running?`);
  }
}
