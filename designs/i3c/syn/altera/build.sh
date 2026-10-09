#!/usr/bin/env bash
# Stage the RTL on the Windows side and run Quartus Prime Pro (synthesis [+ fit + STA]).
# Quartus runs as a Windows process, so the project lives under C:\ (not \\wsl$).
#   syn/altera/build.sh            # full: syn + fit + sta
#   syn/altera/build.sh syn        # synthesis only (fast synthesizability check)
set -u
STAGE=/mnt/c/i3c_quartus
QBIN=/mnt/c/altera_pro/25.3/quartus/bin64
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
MODE="${1:-all}"

mkdir -p "$STAGE"
cp "$REPO"/rtl/*.sv "$STAGE"/
cp "$REPO"/rtl/altera/*.sv "$STAGE"/
cp "$REPO"/syn/altera/i3c_target.qsf "$STAGE"/
cp "$REPO"/syn/altera/i3c_target.sdc "$STAGE"/

cd "$STAGE"
echo "=== Quartus Analysis & Synthesis ==="
"$QBIN/quartus_syn.exe" i3c_target 2>&1 | tr -d '\r' | tail -25
rc=${PIPESTATUS[0]}
[ "$rc" -ne 0 ] && { echo "SYNTH FAILED ($rc)"; exit "$rc"; }
[ "$MODE" = "syn" ] && { echo "SYNTH OK (syn-only mode)"; exit 0; }

echo "=== Quartus Fitter (place & route) ==="
"$QBIN/quartus_fit.exe" i3c_target 2>&1 | tr -d '\r' | tail -15
echo "=== Quartus STA ==="
"$QBIN/quartus_sta.exe" i3c_target 2>&1 | tr -d '\r' | tail -40
