# shellcheck shell=bash disable=SC2034  # sourced by packaging/build.sh, which uses these vars
# Packaging manifest for metrics-stack-exporter-pve, read by packaging/build.sh.
#
# Unlike the standalone node/smartctl/ipmi exporters, this one is NOT
# PKG_EXPORTER_*-templated: it polls the Proxmox VE API remotely rather
# than exposing local host metrics, so it needs its own postinstall/
# preremove/postremove (registers into scrape_configs.d/, not targets.d/)
# and depends on metrics-stack-common + metrics-stack-prometheus rather
# than installing network-independent.
PKG_NAME="metrics-stack-exporter-pve"
PKG_DESCRIPTION="prometheus-pve-exporter for metrics-stack (Proxmox VE cluster/node metrics via the PVE API), with monitoring-configure-pve for credentials + scrape-job setup. Joins the shared 'metrics' Podman network; depends on metrics-stack-common and metrics-stack-prometheus (uses its scrape_configs.d drop-in support)."
PKG_DEPENDS=(podman metrics-stack-common metrics-stack-prometheus)

# containers/ is staged to /etc/containers/systemd/ by convention (see
# packaging/build.sh) -- only files outside that convention are listed here.
# "mode:src(relative to this package dir):dest(absolute path on target)"
PKG_FILES=(
  "0640:pve-exporter/pve.yml:/etc/pve-exporter/pve.yml"
  "0755:scripts/configure-pve.sh:/usr/bin/monitoring-configure-pve"
)

# Convention-staged files (containers/) are marked config automatically.
PKG_CONFIG_FILES=(
  /etc/pve-exporter/pve.yml
)

PKG_POSTINSTALL="packaging/postinstall.sh"
PKG_PREREMOVE="packaging/preremove.sh"
PKG_POSTREMOVE="packaging/postremove.sh"
