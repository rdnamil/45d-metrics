#!/bin/sh
# Runs as %post (rpm) / postinst (deb) after package files are laid down.
# POSIX sh -- Debian's /bin/sh is dash, not bash.
set -e

log() { echo "==> $*"; }

mkdir -p /etc/pve-exporter

log "reloading systemd (runs the Quadlet generator)"
systemctl daemon-reload

log "starting pve-exporter (idle -- no real PVE credentials until configured)"
systemctl restart pve-exporter

# Deliberately not opened on the firewall: unlike node/smartctl/ipmi,
# pve-exporter isn't meant to be scraped from outside this host -- it's
# polled by the local Prometheus over the shared 'metrics' Podman network,
# same posture as Alertmanager's 9093.
log "done. pve-exporter listening on :9221 (not opened on the firewall --"
log "reached over the 'metrics' Podman network by Prometheus, not scraped"
log "from outside)"
log "Next: monitoring-configure-pve --help to set PVE API credentials and"
log "register the scrape job"
