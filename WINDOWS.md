# Windows setup — Git Bash

The supported Windows path is **native Windows + Git Bash**. You do not use WSL as your
working environment; Docker Desktop manages its own internal Linux VM and you never touch it.

Needs a physical Windows machine (or a VM with nested virtualization). Inside an ordinary
VM (UTM, basic VirtualBox/VMware) Docker Desktop's engine cannot start — the error in its
log is `HCS_E_HYPERV_NOT_INSTALLED` and there is no workaround.

## One-time setup

### 1. Install the tools

Open PowerShell **as administrator**: press the Windows key, type `powershell`, right-click
"Windows PowerShell", choose **Run as administrator**. In that window:

```powershell
winget install -s winget --accept-source-agreements --accept-package-agreements Git.Git OpenJS.NodeJS.LTS GitHub.cli Docker.DockerDesktop
```

`-s winget` is not optional: the Microsoft Store source is frequently broken (certificate
error `0x8a15005e`) and without the flag winget stops instead of installing.

Don't trim `OpenJS.NodeJS.LTS` out of that line. The template's `initializeCommand` runs
`node` on the *host* before any container exists, with no shell fallback — see the node
bullet under [Known Windows facts](#known-windows-facts).

### 2. Start Docker Desktop once

Press the Windows key, type `docker desktop`, press Enter. Accept the terms. If it asks to
reboot, reboot. You are done when the whale icon in the system tray (bottom-right, near the
clock) stops animating and Docker Desktop shows **Engine running**.

### 3. Open Git Bash — everything below happens there

Press the Windows key, type `git bash`, press Enter. A terminal with a `$` prompt opens;
that window is where all remaining commands go.

Do **not** paste these into PowerShell: `npm` is blocked there by the default script
execution policy (`npm.ps1 cannot be loaded`). In Git Bash it just works.

```bash
npm install -g @devcontainers/cli
gh auth login --web
```

The `gh` login opens your browser once; approve and come back. No token minting needed.

### 4. Install the sandbox wrapper

```bash
mkdir -p ~/bin
gh api repos/siimvene/devcontainers/contents/sandbox \
  -H "Accept: application/vnd.github.raw" > ~/bin/sandbox
gh api repos/siimvene/devcontainers/contents/sandbox.cmd \
  -H "Accept: application/vnd.github.raw" > ~/bin/sandbox.cmd
chmod +x ~/bin/sandbox
```

Close Git Bash and open it again once — `~/bin` only lands on PATH if the folder existed
when the shell started.

`sandbox.cmd` is a relay so `sandbox` also works when typed into PowerShell or cmd (it
hands off to Git Bash). For those shells to find it, add `~/bin` to your Windows PATH
once — paste into PowerShell:

```powershell
[Environment]::SetEnvironmentVariable('Path', "$env:USERPROFILE\bin;" + [Environment]::GetEnvironmentVariable('Path','User'), 'User')
```

Then open a new terminal window (existing ones keep the old PATH).

### 5. Credentials

```bash
sandbox init
```

Guided setup for `~/.agent/agent.env`. If you don't use 1Password, press **Ctrl+C** when it
checks the 1Password connection — the printed hint says so too — and fill the plain-token or
`AGENT_ENV_COMMAND` alternative from `agent.env.example`.

## Daily use

```bash
cd ~/git/your-repo   # a repo that carries the .devcontainer template
sandbox              # launch: resolves credentials, starts the container, opens the agent
sandbox sync         # pull the latest template, review the git diff, commit
sandbox rebuild      # recreate the container so synced changes actually apply
```

## Known Windows facts

- **No rsync in Git Bash** — expected; `sandbox sync` doesn't need it.
- **`node` on the host PATH is a hard requirement, not a Windows nicety.**
  `initializeCommand` is the array form `["node",".devcontainer/write-env.cjs"]` — it
  writes `.devcontainer/.env` so compose can interpolate the repo name into the mount
  path. The old POSIX `printf` fallback is gone: it only ever ran because the command
  was a shell string, and the shell string is exactly what the array form removes (see
  the "Reopen in Container" bullet for what that string did on Windows). Both `sandbox`
  and the IDE path fail here, before the container exists, if `node` isn't resolvable.
- **Line endings are two separate problems, and the template only solves one.**
  - *The template's own files* are safe: `.devcontainer/.gitattributes` forces LF. Don't
    remove it — with Git for Windows' default `core.autocrlf=true`, a clone would
    otherwise check out the container's shell scripts with CRLF and break every boot.
  - *The repo you're working in* is not, and that's the one an agent actually trips
    over. `core.autocrlf=true` checks tracked files out as CRLF while the index keeps
    LF; the container's git has no autocrlf, so in-container `git diff` reports the
    whole worktree as modified — measured on a real repo: 811 files reported, 796 of
    them pure line-ending noise. An agent told to "commit your changes" commits all of
    it. The boot check now WARNs when it detects this. The fix belongs in that repo and
    is applied on the host: commit a root `.gitattributes` of `* text=auto eol=lf`.
    That alone silences the diff — git normalizes on read once the attribute exists —
    but it leaves CRLF bytes on disk, which still kill anything the container executes
    by shebang (`bad interpreter: /bin/sh^M`). So refresh the worktree too, from a
    clean tree:

    ```bash
    git status --porcelain   # must be empty: the reset below discards worktree state
    printf '* text=auto eol=lf\n' > .gitattributes
    git add .gitattributes && git commit -m "normalize line endings to LF"
    git rm --cached -r . > /dev/null && git reset --hard
    ```

    Setting `core.autocrlf=false` on the host is not a substitute: it only stops the
    *next* checkout from converting, and leaves every already-CRLF file exactly as it
    is.
- **The container's `node_modules` is its own volume from template `2026-08-12a`.**
  Before that the container shared the host's tree through the bind mount, which
  failed both ways: host win32 binaries can't run in the container
  (`Cannot find module '@rollup/rollup-linux-x64-gnu'`), and an in-container
  `npm ci` cleared the HOST's tree before even checking auth (689 → 0 packages,
  every `.cmd`/`.ps1` bin shim gone, husky broken at commit time). Each side now
  owns its install — run `npm ci` once per side.
- **git works inside the container** as of template `2026-08-10a`. The bind mount arrives
  owned by `0:0` on a Windows host, so every in-container git command used to abort with
  `fatal: detected dubious ownership in repository`; `postCreateCommand` now registers a
  `safe.directory` exception for the workspace folder. That is what unblocks the headline
  unattended flow — `sandbox -p "close TICKET-123: implement, test, open the PR"` could
  not stage, commit or push on a Windows host before it.
- **VS Code "Reopen in Container" works from template `2026-08-10a` onward** — on an
  older copy it does not, on Windows specifically. `initializeCommand` used to be an
  inline `node -e` string; the devcontainer CLI hands string commands to `cmd.exe /c`,
  whose legacy first/last quote stripping mangled the argument, so `.devcontainer/.env`
  was never written, compose fell back to its `${SANDBOX_REPO:-app}` default, the repo
  mounted at `/workspaces/app` instead of `/workspaces/<repo>`, and every exec died with
  `chdir to cwd failed`. Seeing that means your copy is behind: check
  `.devcontainer/TEMPLATE_VERSION`, then `sandbox sync` and `sandbox rebuild`. It still
  delivers no credentials by design — use it for attended sessions only; `sandbox` is
  the credentialed path.
- **IntelliJ has no working path into the sandbox on Windows.** Two independent gaps:
  JetBrains' Dev Containers support runs `initializeCommand` through `sh` even on a
  native Windows host, where no `sh` exists on PATH — the build dies with
  `Cannot run program "sh"` (CreateProcess error=2). And attaching to a container
  created outside the IDE is an open, un-roadmapped feature request
  ([IJPL-162762](https://youtrack.jetbrains.com/issue/IJPL-162762), JetBrains
  confirmed June 2025) — VS Code has attach, IntelliJ doesn't. The workable flow:
  open the repo in IntelliJ on the host as a normal project and run the agent with
  `sandbox` in a terminal — same bind-mounted checkout, both sides see every edit
  instantly. Vote the issue if native attach matters to you. (Putting
  `C:\Program Files\Git\bin` on your Windows PATH makes IntelliJ's own build pass,
  but an IDE-launched container carries no session credentials — same caveat as
  VS Code above.)

*Host layer (wrapper, sync, initializeCommand, PATH assumptions) verified on a Windows
ARM64 Git Bash bench; container layer verified on physical Windows in field use.*
