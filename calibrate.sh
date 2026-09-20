#!/usr/bin/env bash
# Calibration aid, for development only. Not part of the product.
#
# Puts the display at a given adaptation strength immediately so it can be
# compared against a reference, a Mac with True Tone on, in the same room.
# Once a value looks right, set STRENGTH in TrueToneModel.js to match and
# restart the shell.
#
#   ./calibrate.sh 0.14     apply that strength using the live sensor reading
#   ./calibrate.sh sweep    step through a range, pausing at each
#   ./calibrate.sh off      hand control back to the service
set -uo pipefail
cd "$(dirname "$0")"

GAINS="$HOME/.local/state/omarchy-truetone/gains"

usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
[ $# -ge 1 ] || usage

restore() {
  omarchy-shell truetone enable >/dev/null 2>&1
  omarchy-shell truetone refresh >/dev/null 2>&1
  echo "service back in control"
}

apply_strength() {
  local s="$1"
  node -e '
    var M = require("./TrueToneModel.js"), fs = require("fs");
    var S = parseFloat(process.argv[1]);
    var d = "/sys/bus/iio/devices/iio:device2";
    var rd = function (f) { return parseFloat(fs.readFileSync(d + "/" + f, "utf8")) * 0.001; };
    var cct = rd("in_colortemp_raw"), lux = rd("in_illuminance_raw");
    var x = rd("in_chromaticity_x_raw"), y = rd("in_chromaticity_y_raw");

    // Same maths as the model, with STRENGTH overridden for the trial.
    var D65x = 0.3127, D65y = 0.3290;
    if (cct > 6500) { x = D65x; y = D65y; }
    var g = M.xyToGains(D65x + S * (x - D65x), D65y + S * (y - D65y));
    var out = g.r.toFixed(3) + " " + g.g.toFixed(3) + " " + g.b.toFixed(3);
    fs.writeFileSync(process.argv[2], out + "\n");
    console.log("  strength " + S.toFixed(2) +
      "  room " + Math.round(cct) + "K/" + Math.round(lux) + "lux" +
      "  ->  gains " + out +
      "   (green -" + Math.round((1 - g.g) * 100) + "%, blue -" + Math.round((1 - g.b) * 100) + "%)");
  ' "$s" "$GAINS"
}

case "$1" in
  off)
    restore
    ;;
  sweep)
    # Stop the service writing over the trial values.
    omarchy-shell truetone disable >/dev/null 2>&1
    sleep 1
    echo "Comparing against the Mac. Ctrl-C when one matches, then set that"
    echo "STRENGTH in TrueToneModel.js."
    echo
    for s in 0.00 0.06 0.10 0.14 0.20 0.28 0.40; do
      apply_strength "$s"
      sleep 6
    done
    echo
    echo "sweep done"
    restore
    ;;
  *)
    omarchy-shell truetone disable >/dev/null 2>&1
    sleep 1
    apply_strength "$1"
    echo
    echo "Held. Run './calibrate.sh off' to give the service control back."
    ;;
esac
