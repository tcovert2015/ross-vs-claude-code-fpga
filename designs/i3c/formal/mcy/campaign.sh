#!/usr/bin/env bash
# Full equivalence-filtered mutation-coverage campaign (issue #18).
# For each module: gen the mcy project (test_fm + test_eq), run it, and record both the
# RAW kill rate and the NOCHANGE-FILTERED coverage. Writes formal/mcy/results.txt.
cd "$(dirname "$0")/../.."
source tools/env.sh >/dev/null 2>&1
SIZE="${1:-60}"
LOG="$(pwd)/formal/mcy/results.txt"      # absolute: the per-module appends run inside a `cd "$mod"` subshell
{
  echo "# mcy mutation coverage -- equivalence-filtered (issue #18)"
  echo "# Per mutant: test_fm (formal property suite) + test_eq (sequential equivalence vs original: equiv_make+equiv_simple+equiv_induct)."
  echo "# NOCHANGE = mutant proven equivalent to the original -> EXCLUDED from the denominator."
  echo "# Filtered coverage = COVERED / (COVERED + UNCOVERED).  Run: formal/mcy/campaign.sh [size]"
  echo "#"
  printf "# %-20s %8s %8s %9s %9s %8s %7s\n" module filtered raw covered uncovered nochange eqgap
} > "$LOG"
for mod in i3c_sda_mux i3c_bit_engine i3c_framer i3c_bus_frontend i3c_fifo \
           i3c_protocol_fsm i3c_daa i3c_ccc i3c_ibi i3c_error_recovery \
           i3c_regfile i3c_avalon_mm; do
  case "$mod" in
    i3c_bus_frontend) FILES="i3c_bus_frontend.sv" ;;
    *)                FILES="i3c_pkg.sv ${mod}.sv" ;;
  esac
  formal/mcy/gen.sh "$mod" "$SIZE" $FILES >/dev/null 2>&1
  ( cd "formal/mcy/$mod" && mcy init >/dev/null 2>&1 && timeout 1500 mcy run -j8 >/dev/null 2>&1
    s="$(mcy status 2>&1)"
    filt="$(printf '%s' "$s" | grep -oE 'Filtered coverage: [0-9.]+%' | grep -oE '[0-9.]+%' | head -1)"
    raw="$(printf '%s' "$s" | grep -oE 'Raw kill rate: [0-9.]+%' | grep -oE '[0-9.]+%' | head -1)"
    cov="$(printf '%s' "$s" | grep -oE 'as "COVERED"' | wc -l)"   # fallback; use tag lines below
    get(){ printf '%s' "$s" | grep -oE "as \"$1\"\\.?" >/dev/null; printf '%s' "$s" | sed -nE "s/.*Tagged ([0-9]+) mutations as \"$1\".*/\\1/p" | head -1; }
    C="$(get COVERED)"; U="$(get UNCOVERED)"; N="$(get NOCHANGE)"; E="$(get EQGAP)"
    printf "%-22s %8s %8s %9s %9s %8s %7s\n" "$mod" "${filt:-NA}" "${raw:-NA}" "${C:-0}" "${U:-0}" "${N:-0}" "${E:-0}" >> "$LOG" )
done
echo "# CAMPAIGN DONE" >> "$LOG"
