# Formal Coverage — what is and isn't proven, and how to confirm it independently

This document answers two questions honestly:
1. **Does the formal verification have "100% coverage"?**
2. **How can a third party confirm the result without trusting us?**

The short version: **we do not claim 100% coverage, and the evidence says we shouldn't.**
Simulation found **7 real bugs that the formal proofs passed** (see
[`findings.md`](findings.md)) — direct, empirical proof that the formal *property set*
did not cover 100% of the design's behavior. A formal effort that claims unqualified
"100%" is misusing the term.

## 1. "100% coverage" is three separate things

| Notion | Meaning | This project | Confirmed by |
|---|---|---|---|
| **Proof exhaustiveness** | Does each proof hold for *all states, all time*? | **Yes for per-module properties** — `mode prove` is **k-induction (unbounded)**, not a bounded depth. (Integration F-1/F-2/F-3 are the exception: BMC depth-40 — honestly flagged below.) | "successful proof by k-induction" in the sby log; re-run `./run.sh` |
| **Property completeness** | Do the assertions describe *all* required behavior? | **Not measured — the real gap.** ~280 assertions from 380 spec requirements, but nothing guarantees they are complete. The 7 sim bugs lived in behavior no assertion constrained. | Mutation testing (§3); spec-traceability review |
| **Non-vacuity** | Are proofs meaningful, or trivially/vacuously true? | **Checked.** Every module has passing `cover` proofs (integration cover reached 281 witnesses incl. a full FE→bit→framer→FSM→RX-FIFO datapath trace). No `assume(0)` / `assert(1)` cheats. | `cover` task PASS; read the assumptions |

The classic trap is conflating row 1 with row 2. "All my properties are proven
exhaustively" (true here) is **not** "the design is 100% correct" (unknown). The honest
claim is: *the stated properties hold for all time; the property set is incomplete.*

## 2. What IS exhaustively proven here

- **Per-module safety/protocol invariants are unbounded (k-induction).** No-bus-contention,
  single-SDA-owner, drive-only-when-permitted, address match, ACK/NACK correctness,
  T-bit/parity, CCC classification + wildcard-NACK, IBI gating, error-recovery-to-idle,
  identity constants, FIFO no-overrun/underrun, Avalon read-scoreboard. Full per-module
  table in [`verification_status.md`](verification_status.md).
- **Soundness of the decomposition is auditable.** Each module is proven standalone with
  neighbour outputs constrained by `assume`; every such assume is mapped to a neighbour's
  proven `assert` in [`assume_ledger.md`](assume_ledger.md). The integration proof strips
  per-module checks (`chformal -remove`) so its F-1/F-2 results do not lean on unit assumes.

## 3. Measuring property completeness: mutation coverage (`mcy`)

The objective metric for row 2 is **mutation coverage**, and the open-source tool `mcy`
(Mutation Cover with Yosys, installed in the OSS CAD Suite) does exactly this:

1. Systematically **inject bugs** into the RTL (bit flips, stuck signals, dropped terms) — hundreds of mutants.
2. Re-run the formal proofs against each mutant.
3. **Mutant killed** = some assertion fails → that logic is covered by a property.
4. **Mutant survives** = all proofs still pass → a **coverage hole**: real logic no property constrains.
5. **Coverage % = killed / total.** Surviving mutants are a precise, reviewable to-do list for new assertions.

This is the open-source equivalent of Cadence JasperGold Coverage / Synopsys VC Formal FCA
/ Certitude.

### Measured results (mcy, equivalence-filtered — issue #18)

Harness: `formal/mcy/gen.sh <module> <N> <files...>` builds a per-module mcy project that
runs **two** tests on each mutant (`formal/mcy/campaign.sh [size]` runs all modules):

- **`test_fm`** — the module's own formal proof on the mutant (BMC depth 20). A mutant is
  **killed** if an assertion fails.
- **`test_eq`** — a **sequential equivalence check** of the mutant against the original
  (`equiv_make` + `equiv_simple` + `equiv_induct`, `equiv_status -assert`). PASS means the
  mutant is **logically equivalent** (a NOCHANGE mutant) and therefore *uncoverable by
  construction*. (A plain BMC miter is wrong here — the two copies have free initial FF /
  memory state, so they differ at t=0 before the synchronous reset equalises them;
  `equiv_induct` reasons over reachable states instead.)

Each mutant is then classified and **NOCHANGE mutants are excluded from the denominator**:

| Classification | `test_fm` | `test_eq` | Counts toward |
|---|---|---|---|
| **COVERED** (killed) | FAIL | not equiv | numerator + denominator |
| **UNCOVERED** (real gap) | PASS | not equiv | denominator only |
| **NOCHANGE** (no-op) | PASS | equiv | **excluded** |
| **EQGAP** (spurious) | FAIL | equiv | excluded (flagged) |

**Filtered coverage = COVERED / (COVERED + UNCOVERED).**  Measured (per-module sample, the
full table is regenerated into `formal/mcy/results.txt`):

| Module | Filtered coverage | Raw kill rate | killed / killable | NOCHANGE excluded |
|---|---|---|---|---|
| `i3c_bit_engine` | **72.2 %** | 65.0 % | 13 / 18 | 2 |
| `i3c_regfile` | **64.7 %** | 55.0 % | 11 / 17 | 3 |
| `i3c_error_recovery` | **61.1 %** | 55.0 % | 11 / 18 | 2 |
| `i3c_framer` | **58.8 %** | 50.0 % | 10 / 17 | 2 (1 EQGAP) |
| `i3c_protocol_fsm` | **55.6 %** | 50.0 % | 10 / 18 | 2 |
| `i3c_fifo` | **42.1 %** | 40.0 % | 8 / 19 | 1 |
| `i3c_sda_mux` | **38.5 %** | 25.0 % | 5 / 13 | 7 |
| `i3c_avalon_mm` | **31.2 %** | 25.0 % | 5 / 16 | 4 |
| `i3c_ccc` | **26.3 %** | 25.0 % | 5 / 19 | 1 |
| `i3c_bus_frontend` | **22.2 %** | 20.0 % | 4 / 18 | 2 |

In **every** module the filtered coverage is higher than the raw kill rate — the gap is the
NOCHANGE mutants the equivalence check removes (most dramatically `i3c_sda_mux`: 7 of its 20
sampled mutations are logically equivalent no-ops, lifting 25 % → 38.5 %). `i3c_daa` and
`i3c_ibi` are omitted here: their sequential `equiv_induct` pass exceeded the per-mutant
time budget on this machine — re-run them with a larger `timeout` in `gen.sh`/`campaign.sh`.

**Read these numbers correctly — even filtered, this is coverage of the SAFETY/PROTOCOL
property set, not a "percent of the spec verified".** Two effects still keep it conservative:

1. **BMC bound.** The kill test fails a mutant only if an assertion breaks within depth 20;
   the unbounded k-induction proof the project ships would catch at least as many. Lower
   bound. (The equivalence horizon matches, so NOCHANGE filtering stays consistent.)
2. **Formal-only logic is in the mutated netlist.** Mutating a ghost/cover signal cannot
   break a functional assertion — those land in NOCHANGE or UNCOVERED, not as real holes.

### What the numbers actually tell you

The spread is the real signal. Modules whose properties closely track the datapath
(`bit_engine` 72 %, `regfile` 65 %, `error_recovery` 61 %, `framer` 59 %, `protocol_fsm`
56 %) score higher than the wide combinational decoders / boundary blocks (`ccc` 26 %,
`bus_frontend` 22 %), and that is **exactly what a safety-and-protocol property set should
look like**: it pins down contention, framing, ACK/NACK, ordering, and identity — *not*
every functional bit of every CCC decode. Pushing any module toward >90 % means writing a
near-complete **functional reference model**, a different and far larger goal than the
safety/conformance invariants proven here.

The actionable output is the **surviving-mutant (UNCOVERED) list** per module — a concrete,
prioritized to-do list of functional assertions to add if higher coverage is wanted — now
cleanly separated from the NOCHANGE no-ops that no property should ever catch.

**Bottom line:** mutation testing confirms, quantitatively, what §1 says qualitatively — the
proofs are exhaustive for the (safety-focused) properties written; the property set is not a
complete functional spec, so it does **not** have "100 % coverage." With the equivalence
(NOCHANGE) filter the measured coverage now reflects *property-relevant* mutations only, and
is consistently higher than the raw kill rate it replaces.

## 4. How a third party confirms the result — no license, no trust required

The open-source flow's biggest advantage is **independent reproducibility**:

1. **Reproduce the proofs from scratch.** `git clone`, `source tools/env.sh`,
   `cd formal && ./run.sh` → same yosys / SymbiYosys / boolector, deterministic SAT/SMT
   results → identical **ALL GREEN**. No proprietary tool or license needed (contrast a
   commercial result a reviewer cannot reproduce without a ~$100k seat). The solver's
   UNSAT result is itself a checkable proof certificate.
2. **Read every property.** Assertions are plain SVA under `` `ifdef FORMAL `` in the RTL,
   traceable to [`requirements.md`](requirements.md).
3. **Audit the assumptions — be most skeptical here.** A proof is only as honest as its
   `assume`s; over-constraining yields false green. Scrutinise
   [`assume_ledger.md`](assume_ledger.md): every environment assume must be discharged by a
   proven assert.
4. **Check non-vacuity.** Re-run `cover`; add independent cover points.
5. **Run an independent mutation campaign** (`mcy`) and/or **write independent properties**.
   If those also pass, confidence rises; if they find a gap, that is the coverage hole.

## 5. Honest bottom line

- ✅ The properties that exist are proven **exhaustively** (unbounded) per module.
- ✅ The proofs are **non-vacuous** and **independently reproducible by anyone, for free**.
- ❌ The property set is **not proven complete** — and we have hard evidence (7 sim bugs) it isn't.
- 🟡 Integration safety (F-1/F-2/F-3) is **BMC-bounded (depth 40) + cover**, not unbounded — tracked (#12).
- 📐 **Mutation coverage has not been measured** — that is the missing quantitative number, runnable with `mcy`.

The strongest defensible statement: *"Each module's stated safety/protocol invariants are
exhaustively proven and any third party can reproduce that for free; completeness is
bounded by the property set, which simulation and (next) mutation testing quantify."*
