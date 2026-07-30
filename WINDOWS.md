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
chmod +x ~/bin/sandbox
```

Close Git Bash and open it again once — `~/bin` only lands on PATH if the folder existed
when the shell started.

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
- **Line endings are handled.** The template ships `.devcontainer/.gitattributes` forcing
  LF. Don't remove it: with Git for Windows' default `core.autocrlf=true`, a clone would
  otherwise check out the container's shell scripts with CRLF and break every boot.
- **VS Code "Reopen in Container" works** but delivers no credentials by design — use it
  for attended sessions only; `sandbox` is the credentialed path.

*Host layer (wrapper, sync, initializeCommand, PATH assumptions) verified on a Windows
ARM64 Git Bash bench; container layer verified on physical Windows in field use.*
