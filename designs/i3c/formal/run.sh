#!/usr/bin/env bash
# Run all (or selected) SymbiYosys proofs and print a pass/fail summary.
#   ./run.sh                 # run every *.sby in this dir
#   ./run.sh i3c_sda_mux     # run one (basename, no .sby)
set -u
cd "$(dirname "$0")"
source ../tools/env.sh >/dev/null 2>&1 || { echo "toolchain not loaded"; exit 1; }

if [ $# -gt 0 ]; then SBYS=("$@"); else SBYS=(); for f in *.sby; do SBYS+=("${f%.sby}"); done; fi

rc_all=0
printf "\n%-24s %-8s %s\n" "PROOF" "TASK" "RESULT"
printf -- "------------------------------------------------\n"
for name in "${SBYS[@]}"; do
  [ -f "$name.sby" ] || { echo "missing $name.sby"; rc_all=1; continue; }
  sby -f "$name.sby" >/dev/null 2>&1
  # one workdir per task: <name>_<task>
  for d in "${name}"_*/; do
    [ -d "$d" ] || continue
    task="$(basename "$d" | sed "s/^${name}_//")"
    res="$(grep -hoE "DONE \((PASS|FAIL|UNKNOWN|ERROR)" "$d/logfile.txt" 2>/dev/null | tail -1 | sed 's/DONE (//')"
    [ -z "$res" ] && res="NORUN"
    printf "%-24s %-8s %s\n" "$name" "$task" "$res"
    [ "$res" = "PASS" ] || rc_all=1
  done
done
printf -- "------------------------------------------------\n"
[ $rc_all -eq 0 ] && echo "ALL GREEN" || echo "SOME FAILURES"
exit $rc_all
