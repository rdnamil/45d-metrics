#!/usr/bin/env bash
# managed by metrics-stack-exporter-pve
# Installed as: monitoring-configure-pve
#
# Writes /etc/pve-exporter/pve.yml with PVE API token credentials, writes a
# matching scrape job to /etc/prometheus/targets.d/pve.yml (see
# metrics-stack-prometheus's scrape_configs.d/README.md), validates the
# Prometheus side with promtool, and restarts pve-exporter + prometheus.
#
# Unlike monitoring-add-exporter's targets.d/ (30s live pickup),
# scrape_configs.d/ needs a full Prometheus restart to take effect -- this
# script does that for you.
set -euo pipefail

PVE_CONFIG="/etc/pve-exporter/pve.yml"
SCRAPE_CONFIG="/etc/prometheus/targets.d/pve.yml"
PVE_QUADLET="/etc/containers/systemd/pve-exporter.container"
PROM_QUADLET="/etc/containers/systemd/prometheus.container"

usage() {
  cat <<'EOF'
Usage: monitoring-configure-pve --user USER --token-name NAME [--token-value VALUE]
                                 --targets NODE1[,NODE2,...]
                                 [--module NAME] [--job NAME] [--no-verify-ssl]

Configures the PVE exporter to poll a Proxmox VE cluster via API token, and
registers the matching Prometheus scrape job in scrape_configs.d/.

  --user USER            PVE API user, e.g. prometheus@pve
  --token-name NAME      PVE API token ID (e.g. from 'pveum user token add')
  --token-value VALUE    PVE API token secret (prompted if omitted)
  --targets NODE1,...    Comma-separated PVE node IP(s)/hostname(s) to scrape.
                          Any node in the cluster returns the same cluster-wide
                          metrics; list every node you also want complete
                          per-node metrics from.
  --module NAME          Config module name in pve.yml (default: default)
  --job NAME             Prometheus job name (default: pve)
  --no-verify-ssl        Disable TLS certificate verification (self-signed certs)

Example:
  monitoring-configure-pve --user prometheus@pve --token-name monitoring \
    --targets 10.0.0.11,10.0.0.12,10.0.0.13 --no-verify-ssl
EOF
}

user=""
token_name=""
token_value=""
targets=""
module="default"
job="pve"
verify_ssl="true"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) user="$2"; shift 2 ;;
    --token-name) token_name="$2"; shift 2 ;;
    --token-value) token_value="$2"; shift 2 ;;
    --targets) targets="$2"; shift 2 ;;
    --module) module="$2"; shift 2 ;;
    --job) job="$2"; shift 2 ;;
    --no-verify-ssl) verify_ssl="false"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument '$1'" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$user" || -z "$token_name" || -z "$targets" ]]; then
  echo "error: --user, --token-name, and --targets are required" >&2
  usage
  exit 1
fi

if [[ -z "$token_value" ]]; then
  read -r -s -p "PVE API token value for ${user}!${token_name}: " token_value
  echo
fi

if [[ -z "$token_value" ]]; then
  echo "error: token value cannot be empty" >&2
  exit 1
fi

if [[ ! "$job" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  echo "error: job name must match [a-zA-Z0-9_-]+" >&2
  exit 1
fi

if [[ ! "$module" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  echo "error: module name must match [a-zA-Z0-9_-]+" >&2
  exit 1
fi

if [[ $EUID -ne 0 ]]; then
  echo "error: must be run as root (writes to $PVE_CONFIG and $SCRAPE_CONFIG)" >&2
  exit 1
fi

# Render a value as a YAML single-quoted scalar; a literal ' inside one is
# escaped by doubling it, so a token/user string containing one can't break
# the generated config.
yaml_sq() { printf "'%s'" "${1//\'/\'\'}"; }

tmp_pve="$(mktemp)"
tmp_scrape="$(mktemp)"
trap 'rm -f "$tmp_pve" "$tmp_scrape"' EXIT

# --- pve.yml (credentials) ---
if [[ -f "$PVE_CONFIG" ]]; then
  backup="$PVE_CONFIG.bak.$(date +%Y%m%d%H%M%S)"
  cp -p "$PVE_CONFIG" "$backup"
  echo "backed up existing config to $backup"
fi

{
  echo "# managed by metrics-stack-exporter-pve: monitoring-configure-pve"
  echo "$module:"
  echo "  user: $(yaml_sq "$user")"
  echo "  token_name: $(yaml_sq "$token_name")"
  echo "  token_value: $(yaml_sq "$token_value")"
  echo "  verify_ssl: $verify_ssl"
} > "$tmp_pve"

# --- scrape_configs.d/pve.yml (Prometheus scrape job) ---
# Shape follows prometheus-pve-exporter's own documented example:
# https://github.com/prometheus-pve/prometheus-pve-exporter#prometheus-configuration
# pve-exporter and prometheus both join the shared 'metrics' Podman
# network, so the container name resolves for __address__ -- same pattern
# as alertmanager:9093.
IFS=',' read -r -a target_list <<< "$targets"
{
  echo "# managed by metrics-stack-exporter-pve: monitoring-configure-pve"
  echo "- job_name: $(yaml_sq "$job")"
  echo "  metrics_path: /pve"
  echo "  params:"
  echo "    module: [$(yaml_sq "$module")]"
  echo "    cluster: ['1']"
  echo "    node: ['1']"
  echo "  static_configs:"
  echo "    - targets:"
  for t in "${target_list[@]}"; do
    echo "        - $(yaml_sq "$t")"
  done
  echo "  relabel_configs:"
  echo "    - source_labels: [__address__]"
  echo "      target_label: __param_target"
  echo "    - source_labels: [__param_target]"
  echo "      target_label: instance"
  echo "    - target_label: __address__"
  echo "      replacement: pve-exporter:9221"
} > "$tmp_scrape"

if [[ -f "$PROM_QUADLET" ]]; then
  prom_image="$(grep '^Image=' "$PROM_QUADLET" | head -1 | cut -d'=' -f2-)"
  echo "validating Prometheus config (via $prom_image), with the new pve.yml overlaid"
  # Mount the real /etc/prometheus read-only, then overlay just this one
  # file at its target path with the *candidate* content -- validates the
  # effective config exactly as it will look after this script writes it,
  # without touching the real scrape_configs.d/pve.yml yet.
  if ! podman run --rm \
      -v "/etc/prometheus:/etc/prometheus:ro,Z" \
      -v "$tmp_scrape:/etc/prometheus/targets.d/pve.yml:ro,Z" \
      --entrypoint promtool "$prom_image" \
      check config /etc/prometheus/prometheus.yml; then
    echo "error: generated scrape config failed promtool check-config, aborting" >&2
    exit 1
  fi
else
  echo "warning: $PROM_QUADLET not found -- is metrics-stack-prometheus installed on this host?" >&2
  echo "         skipping validation; writing config anyway" >&2
fi

# mode 0640 root:root on the host; pve-exporter.container mounts
# /etc/pve-exporter with ':U', which chowns it to the container's internal
# UID so pve-exporter can still read it despite the restrictive host perms.
install -o root -g root -m 0640 "$tmp_pve" "$PVE_CONFIG"
echo "wrote $PVE_CONFIG"

mkdir -p "$(dirname "$SCRAPE_CONFIG")"
install -m 0644 "$tmp_scrape" "$SCRAPE_CONFIG"
echo "wrote $SCRAPE_CONFIG"

if [[ -f "$PVE_QUADLET" ]]; then
  echo "restarting pve-exporter"
  systemctl restart pve-exporter
else
  echo "warning: pve-exporter service not found -- is metrics-stack-exporter-pve installed?" >&2
fi

if [[ -f "$PROM_QUADLET" ]]; then
  echo "restarting prometheus (scrape_configs.d needs a full reload, unlike targets.d)"
  systemctl restart prometheus
fi

echo "done. Check http://<host>:9090/api/v1/targets (job=$job) to confirm scraping."
