#!/usr/bin/env bash
# quartus_sweep.sh — scope_top utilization across PROBE_W x DEPTH_LOG2 on the Quartus (Agilex 3)
# flow (issue #12). Synthesis + Fit per config (accurate ALM/M20K), then extract the numbers into
# a Markdown table. Runs headless in the Quartus-Pro docker; ~5 min/config.
#
#   bash fpga/util_sweep/quartus_sweep.sh            # full 3x3
#   PWS="32" DLS="12" bash fpga/util_sweep/quartus_sweep.sh   # a subset
#
# Vivado (synth-only, any 7-series/UltraScale part) and Yosys+nextpnr (ECP5) flows are documented in
# fpga/util_sweep/README.md — the scripts mirror this one; only Quartus is installed in this env.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJROOT="$(cd "$HERE/../.." && pwd)"          # fpga-scope repo root
WS=/home/tcovert/projects                       # mounted as /workspace
REL="${HERE#$WS/}"                              # path of util_sweep under /workspace

PWS="${PWS:-32 128 512}"
DLS="${DLS:-8 12 15}"

QPRO() { docker run --rm -i --user "$(id -u):$(id -g)" -e HOME=/tmp \
  -v "$WS":/workspace -v /dev/null:/usr/lib/x86_64-linux-gnu/libudev.so.1 \
  -w "/workspace/$REL" alterafpga/quartus-pro:26.1-agilex3 "$@"; }

OUT="$HERE/utilization_quartus.md"
echo "| PROBE_W | DEPTH_LOG2 | STORE_W | ALMs | M20K | buffer bits |" >  "$OUT"
echo "|---|---|---|---|---|---|"                                       >> "$OUT"

for pw in $PWS; do
  for dl in $DLS; do
    tag="w${pw}_d${dl}"
    echo "=== scope_top PROBE_W=$pw DEPTH_LOG2=$dl ==="
    sed -e "s/^set_parameter -name PROBE_W .*/set_parameter -name PROBE_W $pw/" \
        -e "s/^set_parameter -name DEPTH_LOG2 .*/set_parameter -name DEPTH_LOG2 $dl/" \
        "$HERE/scope_util.qsf" > "$HERE/scope_util.qsf.tmp" && mv "$HERE/scope_util.qsf.tmp" "$HERE/scope_util.qsf"
    rm -rf "$HERE/output_files" "$HERE/db" "$HERE/incremental_db" "$HERE/qdb"
    QPRO quartus_sh --flow compile scope_util -c scope_util > "$HERE/sweep_$tag.log" 2>&1
    rpt="$HERE/output_files/scope_util.fit.rpt"
    cp -f "$rpt" "$HERE/fit_$tag.rpt" 2>/dev/null   # keep each config's report (output_files is wiped next)
    alm=$(grep -m1 "Logic utilization (in ALMs)" "$rpt" 2>/dev/null | grep -oE "[0-9,]+ / [0-9,]+ \( *[0-9]+ %" | head -1)
    m20k=$(grep -m1 "Total RAM Blocks" "$rpt" 2>/dev/null | grep -oE "[0-9]+ / [0-9]+ \( *[0-9]+ %" | head -1)
    store_w=$(( pw + 1 ))            # RLE_EN=1
    bufbits=$(( (1 << dl) * store_w ))
    echo "| $pw | $dl | $store_w | ${alm:-?} | ${m20k:-?} | $bufbits |" >> "$OUT"
    echo "  -> ALMs=[${alm:-?}] M20K=[${m20k:-?}] bufbits=$bufbits"
  done
done
echo "wrote $OUT"
cat "$OUT"
