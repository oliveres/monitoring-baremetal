#!/usr/bin/env bash
#
# monitoring-baremetal installer
# Target: Proxmox VE 9 (Debian 13) on Supermicro X12 / AST2600 BMC
#
# Installs a native Prometheus agent + exporters on the hypervisor and points
# them at the central stack. No Docker: the hypervisor is not a Docker host,
# and monitoring it from a VM that runs on it is a circular dependency.
#
# Usage:  cp .env.example .env && edit && sudo ./install.sh

set -euo pipefail

CONF_DIR=/etc/prometheus-baremetal
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARCH=amd64

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run as root"
[[ -f "$SRC_DIR/.env" ]] || die "missing .env - copy .env.example and fill it in"

# shellcheck disable=SC1091
set -a; source "$SRC_DIR/.env"; set +a

: "${HOSTNAME:?set HOSTNAME in .env}"
: "${CENTRAL_PROMETHEUS_URL:?set CENTRAL_PROMETHEUS_URL in .env}"

# Optional targets default to empty so the corresponding scrape jobs get
# dropped by the regex '^$' relabel rule, same convention as monitoring-edge.
export PVE_API_HOST="${PVE_API_HOST:-}"
export PVE_EXPORTER_TARGET="${PVE_EXPORTER_TARGET:-localhost:9221}"
export SMARTCTL_EXPORTER_TARGET="${SMARTCTL_EXPORTER_TARGET:-}"
export BASIC_AUTH_USER="${BASIC_AUTH_USER:-}"
export BASIC_AUTH_PASSWORD="${BASIC_AUTH_PASSWORD:-}"
export CENTRAL_LOKI_URL="${CENTRAL_LOKI_URL:-}"

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
log "Checking IPMI device"
if [[ ! -c /dev/ipmi0 ]]; then
  warn "/dev/ipmi0 missing - loading modules"
  modprobe ipmi_si ipmi_devintf || true
  printf 'ipmi_msghandler\nipmi_devintf\nipmi_si\n' > /etc/modules-load.d/ipmi.conf
  sleep 2
fi
[[ -c /dev/ipmi0 ]] || die "no /dev/ipmi0 - BMC not reachable over KCS"

log "Installing distro packages"
apt-get update -qq
apt-get install -y -qq prometheus-node-exporter freeipmi-tools curl jq gettext-base

# ---------------------------------------------------------------------------
# Binaries (latest upstream release, resolved at install time)
# ---------------------------------------------------------------------------
latest_tag() {  # repo -> tag without leading v
  curl -fsSL "https://api.github.com/repos/$1/releases/latest" | jq -r .tag_name | sed 's/^v//'
}

fetch_tgz() {  # url, binary-name
  local url=$1 bin=$2 tmp
  tmp=$(mktemp -d)
  curl -fsSL "$url" | tar xz -C "$tmp" --strip-components=1
  install -m 0755 "$tmp/$bin" "/usr/local/bin/$bin"
  rm -rf "$tmp"
}

if [[ ! -x /usr/local/bin/prometheus ]]; then
  V=$(latest_tag prometheus/prometheus)
  log "Installing Prometheus $V"
  fetch_tgz "https://github.com/prometheus/prometheus/releases/download/v${V}/prometheus-${V}.linux-${ARCH}.tar.gz" prometheus
fi

if [[ ! -x /usr/local/bin/ipmi_exporter ]]; then
  V=$(latest_tag prometheus-community/ipmi_exporter)
  log "Installing ipmi_exporter $V"
  fetch_tgz "https://github.com/prometheus-community/ipmi_exporter/releases/download/v${V}/ipmi_exporter-${V}.linux-${ARCH}.tar.gz" ipmi_exporter
fi

# Agent mode was promoted to stable in Prometheus 3.0: the `agent` feature flag
# was removed in favour of a plain --agent argument. Detect rather than assume.
PROM_MAJOR=$(/usr/local/bin/prometheus --version 2>&1 | head -1 | grep -oP '\d+' | head -1)
if [[ "$PROM_MAJOR" -ge 3 ]]; then
  PROM_AGENT_FLAG="--agent"
else
  PROM_AGENT_FLAG="--enable-feature=agent"
fi
log "Prometheus major version $PROM_MAJOR -> using $PROM_AGENT_FLAG"

# ---------------------------------------------------------------------------
# Users, dirs, configs
# ---------------------------------------------------------------------------
id prometheus &>/dev/null || useradd --system --no-create-home --shell /usr/sbin/nologin prometheus
install -d -o prometheus -g prometheus -m 0750 /var/lib/prometheus-agent
install -d -m 0750 "$CONF_DIR"

log "Rendering configs"
envsubst < "$SRC_DIR/prometheus/agent.yml.template" > "$CONF_DIR/agent.yml"
install -m 0644 "$SRC_DIR/ipmi/ipmi_exporter.yml" "$CONF_DIR/ipmi_exporter.yml"
echo "PROM_AGENT_FLAG=$PROM_AGENT_FLAG" > "$CONF_DIR/agent.env"
chmod 0640 "$CONF_DIR/agent.yml"          # contains remote-write credentials
chown root:prometheus "$CONF_DIR/agent.yml"

install -m 0644 "$SRC_DIR/systemd/prometheus-agent.service" /etc/systemd/system/
install -m 0644 "$SRC_DIR/systemd/ipmi-exporter.service" /etc/systemd/system/

# ---------------------------------------------------------------------------
# Optional: promtail -> central Loki
# ---------------------------------------------------------------------------
if [[ -n "$CENTRAL_LOKI_URL" ]]; then
  if [[ ! -x /usr/local/bin/promtail ]]; then
    V=$(latest_tag grafana/loki)
    log "Installing promtail $V"
    apt-get install -y -qq unzip
    tmp=$(mktemp -d)
    curl -fsSL "https://github.com/grafana/loki/releases/download/v${V}/promtail-linux-${ARCH}.zip" -o "$tmp/p.zip"
    (cd "$tmp" && unzip -qo p.zip && install -m 0755 "promtail-linux-${ARCH}" /usr/local/bin/promtail)
    rm -rf "$tmp"
  fi
  id promtail &>/dev/null || useradd --system --no-create-home --shell /usr/sbin/nologin promtail
  install -d -o promtail -g promtail -m 0750 /var/lib/promtail
  envsubst < "$SRC_DIR/promtail/promtail.yml.template" > "$CONF_DIR/promtail.yml"
  chmod 0640 "$CONF_DIR/promtail.yml"; chown root:promtail "$CONF_DIR/promtail.yml"
  install -m 0644 "$SRC_DIR/systemd/promtail-baremetal.service" /etc/systemd/system/
  systemctl enable --now promtail-baremetal.service
else
  warn "CENTRAL_LOKI_URL empty - skipping promtail"
fi

# ---------------------------------------------------------------------------
# Optional: pve-exporter
# ---------------------------------------------------------------------------
if [[ -n "$PVE_API_HOST" ]]; then
  : "${PVE_TOKEN_NAME:?set PVE_TOKEN_NAME when PVE_API_HOST is set}"
  : "${PVE_TOKEN_VALUE:?set PVE_TOKEN_VALUE when PVE_API_HOST is set}"
  log "Installing prometheus-pve-exporter"
  apt-get install -y -qq python3-venv
  id pve-exporter &>/dev/null || useradd --system --no-create-home --shell /usr/sbin/nologin pve-exporter
  [[ -d /opt/pve-exporter ]] || python3 -m venv /opt/pve-exporter
  /opt/pve-exporter/bin/pip install -q --upgrade prometheus-pve-exporter
  cat > "$CONF_DIR/pve.yml" <<EOF
default:
  user: ${PVE_TOKEN_USER:-prometheus@pve}
  token_name: ${PVE_TOKEN_NAME}
  token_value: ${PVE_TOKEN_VALUE}
  verify_ssl: false
EOF
  chmod 0640 "$CONF_DIR/pve.yml"; chown root:pve-exporter "$CONF_DIR/pve.yml"
  install -m 0644 "$SRC_DIR/systemd/pve-exporter.service" /etc/systemd/system/
  systemctl enable --now pve-exporter.service
else
  warn "PVE_API_HOST empty - skipping pve-exporter (scrape job self-drops)"
fi

# ---------------------------------------------------------------------------
# Start
# ---------------------------------------------------------------------------
log "Starting services"
systemctl daemon-reload
systemctl enable --now prometheus-node-exporter.service
systemctl enable --now ipmi-exporter.service
systemctl enable --now prometheus-agent.service

sleep 3
log "Verifying"
curl -fsS localhost:9290/metrics | grep -c '^ipmi_' | xargs -I{} echo "  ipmi_exporter: {} metrics"
curl -fsS localhost:9100/metrics | grep -c '^node_' | xargs -I{} echo "  node_exporter: {} metrics"
curl -fsS localhost:9090/-/ready && echo "  agent: ready"

cat <<EOF

Done. Metrics are streaming to ${CENTRAL_PROMETHEUS_URL} as host="${HOSTNAME}".

Check delivery on the central Prometheus:
  ipmi_temperature_celsius{host="${HOSTNAME}"}
  ipmi_fan_speed_rpm{host="${HOSTNAME}"}

If nothing arrives, look at the agent's own queue metrics:
  curl -s localhost:9090/metrics | grep prometheus_remote_storage_samples_pending
EOF
