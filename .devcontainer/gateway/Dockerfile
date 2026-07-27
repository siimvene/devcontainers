# Egress gateway: an allowlist forward proxy that the workload routes ALL
# outbound through. Built from a trusted base + apt (no third-party proxy
# image), per the org supply-chain rules. Holds NO credentials, and the
# workload cannot reach its config — it is a separate container the agent has
# no root on. This is what makes the egress boundary host-enforced rather than
# something a root agent in the workload can flush.
FROM debian:bookworm-slim

# tinyproxy = egress allowlist proxy; socat = optional ingress dev-port forwarders.
RUN apt-get update \
 && apt-get install -y --no-install-recommends tinyproxy ca-certificates socat \
 && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /usr/local/bin/gateway-entrypoint.sh
RUN chmod +x /usr/local/bin/gateway-entrypoint.sh

# tinyproxy drops to `nobody` itself (User directive in the rendered config).
ENTRYPOINT ["/usr/local/bin/gateway-entrypoint.sh"]
