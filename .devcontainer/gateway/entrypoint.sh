#!/usr/bin/env bash
# Render the egress allowlist into a tinyproxy filter, then run the proxy in
# the foreground. Allowlist = base set (Anthropic + GitHub + npm) plus
# EXTRA_ALLOWED_DOMAINS (comma-separated). Default-deny: only listed hostnames
# and their subdomains may be CONNECTed to. The allowlist is by HOSTNAME (the
# CONNECT target), not by resolved IP, so a shared-CDN address cannot be used
# to reach an unlisted host.
set -euo pipefail

# The written-down answer to "which systems can this agent reach". Extend via
# EXTRA_ALLOWED_DOMAINS on the gateway service, in a reviewable diff.
BASE_DOMAINS="
  api.anthropic.com
  claude.ai
  platform.claude.com
  statsig.anthropic.com
  github.com
  api.github.com
  objects.githubusercontent.com
  raw.githubusercontent.com
  release-assets.githubusercontent.com
  registry.npmjs.org
  pkg-npm.githubusercontent.com
"
# pkg-npm.githubusercontent.com: GitHub Packages npm tarball CDN —
# npm.pkg.github.com (allowed via the github.com subdomain rule) 302s package
# downloads there, and the specific-subdomain entries above don't cover it.
# sentry.io deliberately absent: it accepts events for ANY tenant
# unauthenticated, so allowing it hands the agent a generic exfil sink. Repos
# that need their own Sentry add their tenant host via EXTRA_ALLOWED_DOMAINS.

FILTER=/tmp/allowlist.filter
: > "$FILTER"
# Anchor each domain: match the domain itself or any subdomain, end-anchored.
emit() {
  local esc
  esc=$(printf '%s' "$1" | sed 's/[.]/\\./g')
  printf '(^|\\.)%s$\n' "$esc" >> "$FILTER"
}

for d in $BASE_DOMAINS; do
  [ -n "$d" ] && emit "$d"
done
IFS=',' read -ra EXTRA <<< "${EXTRA_ALLOWED_DOMAINS:-}"
for d in "${EXTRA[@]}"; do
  d=$(printf '%s' "$d" | tr -d '[:space:]')
  [ -n "$d" ] && emit "$d"
done

cat > /tmp/tinyproxy.conf <<CFG
User nobody
Group nogroup
Port 8888
Listen 0.0.0.0
# Bursty build tasks (e.g. the gradle node-plugin's npmInstall behind a webpack
# task) fan out many parallel CONNECT tunnels. tinyproxy's default MaxClients
# (~100) plus a 600s idle Timeout means those keepalive tunnels are held for up
# to 10 min, the worker pool exhausts, and further connections block — the task
# appears to "stall". Give the pool headroom and release idle tunnels quickly.
MaxClients 512
Timeout 60
# Client ACL: only private-range (docker-network) peers may use the proxy. The
# port is never published to the host, so the public internet cannot reach it.
Allow 10.0.0.0/8
Allow 172.16.0.0/12
Allow 192.168.0.0/16
FilterDefaultDeny Yes
Filter "$FILTER"
FilterExtended On
FilterCaseSensitive Off
# HTTPS (443) and submission-over-TLS (563) only; no arbitrary CONNECT ports.
ConnectPort 443
ConnectPort 563
LogLevel Notice
CFG

echo "egress-gateway: allowlist ($(grep -c . "$FILTER") domains):"
sed 's/^/  /' "$FILTER"

# Optional INGRESS: forward host dev ports into the workload for local testing
# (VS Code does this for you; this is the knob for the headless/sandbox flow).
# DEV_FORWARD_PORTS is comma-separated (e.g. "3000,8080"). Each port must ALSO be
# published on this gateway service in compose (ports:), since only the gateway
# sits on a host-reachable network. This is ingress only — it gives the workload
# no outbound path; egress stays gated by the proxy above.
IFS=',' read -ra FWD <<< "${DEV_FORWARD_PORTS:-}"
for p in "${FWD[@]}"; do
  p=$(printf '%s' "$p" | tr -d '[:space:]')
  [ -z "$p" ] && continue
  case "$p" in *[!0-9]*) echo "gateway: ignoring invalid DEV_FORWARD_PORTS entry '$p'"; continue ;; esac
  echo "gateway: dev-forward :$p -> workload:$p"
  # fork = one child per connection; workload:$p is resolved per connection, so
  # the workload coming up after the gateway is fine.
  socat TCP-LISTEN:"$p",fork,reuseaddr TCP:workload:"$p" &
done

exec tinyproxy -d -c /tmp/tinyproxy.conf
