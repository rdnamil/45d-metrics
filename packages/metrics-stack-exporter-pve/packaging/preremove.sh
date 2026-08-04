#!/bin/sh
# Runs as %preun (rpm) / prerm (deb) before package files are removed.
set -e

# Only act on a real uninstall, never on upgrade -- see the equivalent
# comment in metrics-stack-alertmanager's preremove.sh for the rpm/deb
# scriptlet-ordering reasoning this guards against.
case "${1:-0}" in
  0|remove) ;;
  *) exit 0 ;;
esac

systemctl stop pve-exporter 2>/dev/null || true

# If monitoring-configure-pve registered a scrape job in
# metrics-stack-prometheus's scrape_configs.d/, clean it up too so
# Prometheus doesn't keep trying (and failing) to scrape a target that no
# longer exists. This package doesn't depend on metrics-stack-prometheus,
# so only restart it if it's actually present and running.
if [ -f /etc/prometheus/targets.d/pve.yml ]; then
  rm -f /etc/prometheus/targets.d/pve.yml
  if systemctl is-active --quiet prometheus 2>/dev/null; then
    systemctl restart prometheus 2>/dev/null || true
  fi
fi
