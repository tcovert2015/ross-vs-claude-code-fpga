#!/usr/bin/env bash
# soak.sh — random-config soak (issue #13, acceptance gate 1). Runs N seeded random configs
# through the Verilator co-simulation of the real scope_top and checks each end-to-end against
# scope_ref.py. On demand + nightly (not per-PR — it's minutes-long). Auto-skips without verilator.
#
#   bash sim/soak.sh              # 20 configs (default)
#   CONFIGS=100 SEED=1 bash sim/soak.sh
set -eu
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 "$ROOT/host/tests/soak.py" --configs "${CONFIGS:-20}" --seed "${SEED:-0x50A4}"
