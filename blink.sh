#!/usr/bin/env bash
# Development aid. Alternates True Tone off and on so the correction is
# visible as a change rather than as an absolute. A white window helps.
#
#   ./blink.sh          6 cycles of 3s
#   ./blink.sh 10 2     10 cycles of 2s
set -uo pipefail

CYCLES=${1:-6}
SECS=${2:-3}

echo "Watch a white area. OFF and ON alternate every ${SECS}s."
echo

for i in $(seq "$CYCLES"); do
  omarchy-shell truetone disable >/dev/null 2>&1
  printf "  %2d/%s  OFF (neutral)\n" "$i" "$CYCLES"
  sleep "$SECS"
  omarchy-shell truetone enable >/dev/null 2>&1
  sleep 1.2   # the apply lands ~0.8s after enable; read after it, not before
  printf "  %2d/%s  ON   %s\n" "$i" "$CYCLES" "$(cat ~/.local/state/omarchy-truetone/gains 2>/dev/null)"
  sleep "$SECS"
done

echo
echo "Left on. If you could not see the difference, the correction is too"
echo "subtle for you and STRENGTH should go up."
