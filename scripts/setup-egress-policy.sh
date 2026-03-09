#!/bin/bash
# setup-egress-policy.sh
#
# One-time setup script. Run as root on the server before starting the stack.
#
# What it does:
#   1. Configures Docker to allocate job networks from 10.89.0.0/16 so
#      runner containers have a predictable, dedicated subnet.
#   2. Adds iptables rules in the DOCKER-USER chain to restrict traffic
#      from that subnet: DNS and HTTPS only, private networks blocked.
#   3. Persists the rules across reboots via iptables-persistent.
#
# The controller/deployer compose services are explicitly assigned 172.20.0.0/24
# (see docker-compose.yml) and are NOT affected by these rules.
set -euo pipefail

RUNNER_SUBNET="10.89.0.0/16"
DAEMON_CONFIG="/etc/docker/daemon.json"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: must run as root" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 1. Patch Docker daemon config to use dedicated address pool for job networks
# ---------------------------------------------------------------------------

echo "Configuring Docker address pool..."

if [[ -f "${DAEMON_CONFIG}" ]]; then
  # Merge into existing config — preserve any other settings
  if ! command -v jq &>/dev/null; then
    echo "ERROR: jq is required. Install with: apt-get install -y jq" >&2
    exit 1
  fi
  jq '. + {"default-address-pools": [{"base": "10.89.0.0/16", "size": 24}]}' \
    "${DAEMON_CONFIG}" > "${DAEMON_CONFIG}.tmp"
  mv "${DAEMON_CONFIG}.tmp" "${DAEMON_CONFIG}"
else
  cat > "${DAEMON_CONFIG}" <<'EOF'
{
  "default-address-pools": [
    {"base": "10.89.0.0/16", "size": 24}
  ]
}
EOF
fi

echo "  Written to ${DAEMON_CONFIG}"
echo "  NOTE: Docker must be restarted for the address pool to take effect."
echo "        Run: systemctl restart docker"
echo "        Existing networks are unaffected; only new networks use the pool."
echo

# ---------------------------------------------------------------------------
# 2. Set up iptables rules in DOCKER-USER
#
# DOCKER-USER is jumped to first in the FORWARD chain and persists across
# Docker restarts (Docker flushes its own chains but not DOCKER-USER).
# ---------------------------------------------------------------------------

echo "Configuring iptables egress policy for ${RUNNER_SUBNET}..."

# Ensure DOCKER-USER chain exists (Docker creates it, but may not exist yet
# if Docker hasn't run). Create it if missing.
if ! iptables -L DOCKER-USER &>/dev/null; then
  iptables -N DOCKER-USER
fi

# Flush existing DOCKER-USER rules to make this script idempotent
iptables -F DOCKER-USER

# Allow established/related connections (must be first — applies to all traffic)
iptables -A DOCKER-USER \
  -m conntrack --ctstate ESTABLISHED,RELATED \
  -j ACCEPT

# --- Runner egress allowlist (source: 10.89.0.0/16) ---

# Block runners from reaching private/internal networks
# (prevents lateral movement to host services, other containers, LAN)
iptables -A DOCKER-USER -s "${RUNNER_SUBNET}" -d 10.0.0.0/8     -j DROP
iptables -A DOCKER-USER -s "${RUNNER_SUBNET}" -d 172.16.0.0/12  -j DROP
iptables -A DOCKER-USER -s "${RUNNER_SUBNET}" -d 192.168.0.0/16 -j DROP
iptables -A DOCKER-USER -s "${RUNNER_SUBNET}" -d 169.254.0.0/16 -j DROP  # link-local / cloud metadata

# Allow DNS (required for hostname resolution)
iptables -A DOCKER-USER -s "${RUNNER_SUBNET}" -p udp --dport 53 -j ACCEPT
iptables -A DOCKER-USER -s "${RUNNER_SUBNET}" -p tcp --dport 53 -j ACCEPT

# Allow HTTPS only — covers GitHub API, GHCR, Docker Hub, git over HTTPS
# HTTP (80) and git+ssh (22) are intentionally blocked.
# To allow git+ssh: add -p tcp --dport 22 -j ACCEPT before the DROP rule.
iptables -A DOCKER-USER -s "${RUNNER_SUBNET}" -p tcp --dport 443 -j ACCEPT

# Block all other egress from runners
iptables -A DOCKER-USER -s "${RUNNER_SUBNET}" -j DROP

# Pass non-runner traffic back to Docker's own chains unchanged
iptables -A DOCKER-USER -j RETURN

echo "  Rules applied."
echo

# ---------------------------------------------------------------------------
# 3. Persist rules across reboots
# ---------------------------------------------------------------------------

echo "Persisting iptables rules..."

if ! command -v netfilter-persistent &>/dev/null; then
  echo "  Installing iptables-persistent..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q iptables-persistent
fi

netfilter-persistent save
echo "  Rules saved to /etc/iptables/rules.v4"
echo

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo "Done. Egress policy active."
echo
echo "Runner containers (${RUNNER_SUBNET}) may only reach:"
echo "  - DNS     : UDP/TCP port 53"
echo "  - HTTPS   : TCP port 443"
echo
echo "Blocked from runners:"
echo "  - Private networks (10/8, 172.16/12, 192.168/16, 169.254/16)"
echo "  - All other ports and protocols"
echo
echo "Next step: restart Docker to activate the address pool."
echo "  systemctl restart docker"
echo "  docker compose up -d"
