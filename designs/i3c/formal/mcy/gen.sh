#!/usr/bin/env bash
# gen.sh <module> <size> <file1.sv> [file2.sv ...]   (<module> = top)
#
# Generates an mcy project with TWO tests per mutant:
#   test_fm : run the module's formal property suite on the mutant (PASS = mutant
#             survived the proof; FAIL = a property caught it -> killed).
#   test_eq : SEQUENTIAL equivalence of the mutant vs the ORIGINAL (database/design.il)
#             via equiv_make + equiv_simple + equiv_induct (PASS = logically EQUIVALENT).
#
# Equivalence-filtered coverage (issue #18): a mutant that survives the proof AND is
# equivalent to the original is a NOCHANGE mutant -- uncoverable by construction, so it
# is EXCLUDED from the denominator instead of being counted as an uncovered survivor.
#   COVERED   : proof FAIL, not equivalent   -> killed
#   UNCOVERED : proof PASS, not equivalent   -> real coverage gap
#   NOCHANGE  : proof PASS, equivalent       -> excluded (no behavioral change)
#   EQGAP     : proof FAIL, equivalent       -> property fired on a no-op mutant (spurious)
#   Filtered coverage = COVERED / (COVERED + UNCOVERED).
set -e
MOD="$1"; SIZE="$2"; shift 2; FILES="$@"
D="$(cd "$(dirname "$0")" && pwd)/$MOD"
RTL="$(cd "$(dirname "$0")/../../rtl" && pwd)"
rm -rf "$D"; mkdir -p "$D"; cd "$D"
READS=""; FLIST=""
for f in $FILES; do cp "$RTL/$f" .; READS="$READS $f"; FLIST="$FLIST$f\n"; done
cat > config.mcy <<CFG
[options]
size $SIZE
tags COVERED UNCOVERED NOCHANGE EQGAP

[script]
read -formal -sv -I. $READS
prep -top $MOD

[files]
$(printf "$FLIST")
[logic]
tb_okay = (result("test_fm") == "PASS")    # mutant survived the property suite
eq_okay = (result("test_eq") == "PASS")     # mutant is equivalent to the original

if tb_okay and not eq_okay:
    tag("UNCOVERED")        # behaviour changed, no property caught it -> real gap
elif not tb_okay and not eq_okay:
    tag("COVERED")          # behaviour changed, a property caught it -> killed
elif tb_okay and eq_okay:
    tag("NOCHANGE")         # equivalent -> uncoverable, excluded from coverage
else:
    tag("EQGAP")            # property fired on an equivalent mutant (spurious)

[report]
killable = tags("COVERED") + tags("UNCOVERED")
total    = killable + tags("NOCHANGE") + tags("EQGAP")
if killable:
    print("Filtered coverage: %.1f%% (%d killed / %d killable; %d NOCHANGE excluded, %d EQGAP, %d total)" % (100.0*tags("COVERED")/killable, tags("COVERED"), killable, tags("NOCHANGE"), tags("EQGAP"), total))
if total:
    print("Raw kill rate: %.1f%% (NOCHANGE counted as survivors)" % (100.0*tags("COVERED")/total))

[test test_fm]
expect PASS FAIL
run bash \$PRJDIR/test_fm.sh

[test test_eq]
expect PASS FAIL
run bash \$PRJDIR/test_eq.sh
CFG

# --- formal-property test (kill check) ---
cat > test_fm.sby <<'SBY'
[options]
mode bmc
depth 20
expect pass,fail

[engines]
smtbmc boolector

[script]
read_rtlil mutated.il

[files]
mutated.il
SBY
cat > test_fm.sh <<'SH'
#!/bin/bash
exec 2>&1
set -ex
bash $SCRIPTS/create_mutated.sh -o mutated.il
ln -s ../../test_fm.sby .
sby -f test_fm.sby
gawk "{ print 1, \$1; }" test_fm/status >> output.txt
exit 0
SH

# --- equivalence test (NOCHANGE detection): SEQUENTIAL equivalence vs the original ---
# Uses equiv_induct (k-induction equivalence) rather than a BMC miter: the two copies
# have free initial FF/memory state, so a plain miter falsely reports a difference at
# t=0 (sync reset only equalizes them at t=1). equiv_induct proves equivalence over all
# reachable states. yosys exit 0 (equiv_status -assert passes) => EQUIVALENT (NOCHANGE).
# Anything else (incl. timeout / unproven partitions) is conservatively NOT equivalent.
cat > test_eq.sh <<SH
#!/bin/bash
exec 2>&1
set -ex
bash \$SCRIPTS/create_mutated.sh -o mutated.il
if timeout 45 yosys -ql equiv.log -p "
     read_rtlil mutated.il;             rename $MOD gate; design -stash b
     read_rtlil ../../database/design.il; rename $MOD gold; design -stash a
     design -reset
     design -copy-from a -as gold gold
     design -copy-from b -as gate gate
     equiv_make gold gate equiv
     hierarchy -top equiv
     equiv_simple -seq 5
     equiv_induct -seq 10
     equiv_status -assert
   "; then
  echo "1 PASS" >> output.txt    # proven equivalent -> NOCHANGE
else
  echo "1 FAIL" >> output.txt    # not equivalent (or unproven/timeout)
fi
exit 0
SH
echo "generated $D"
