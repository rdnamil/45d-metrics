#!/bin/sh
# Runs as %postun (rpm) / postrm (deb) after package files are removed.
#
# Quadlet generates the real systemd unit from the .container file at
# daemon-reload time, so after that file is gone we reload once more or
# systemd keeps the stale generated unit around until something else
# reloads. Harmless on upgrade too -- reload is idempotent.
systemctl daemon-reload 2>/dev/null || true
