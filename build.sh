#!/usr/bin/env bash
# Builds truetone-gamma, the resident client that holds the gamma ramp.
# Needs gcc, wayland-scanner and wayland-client headers, all of which any
# Hyprland system already has.
set -euo pipefail
cd "$(dirname "$0")"

for t in gcc wayland-scanner pkg-config; do
  command -v "$t" >/dev/null || { echo "missing: $t" >&2; exit 1; }
done

wayland-scanner client-header wlr-gamma-control-unstable-v1.xml \
  wlr-gamma-control-unstable-v1-client-protocol.h
wayland-scanner private-code  wlr-gamma-control-unstable-v1.xml \
  wlr-gamma-control-unstable-v1-protocol.c

gcc -O2 -Wall -o truetone-gamma truetone-gamma.c \
  wlr-gamma-control-unstable-v1-protocol.c \
  $(pkg-config --cflags --libs wayland-client) -lm

rm -f wlr-gamma-control-unstable-v1-protocol.c
echo "built: $(pwd)/truetone-gamma"
