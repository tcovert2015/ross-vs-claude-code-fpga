# Assume ↔ Assert Ledger (critique fix F-9)

Each module is proven **standalone**: its neighbours' outputs are free inputs constrained
by `assume(...)`. For the decomposition to be **sound**, every such environment `assume`
must correspond to a property **proven as an `assert`** in the module that actually drives
that signal. This ledger tracks that correspondence.

Status key: ✅ discharged (matching proven assert exists) · ⏳ pending (assert to be added) ·
🔁 discharged-at-integration (the integration proof strips unit checks and drives the signal
with real RTL, so the unit assume is not relied upon there).

> Note: `formal/i3c_integration.sby` runs `chformal -remove t:$check` on every per-module
> check, so the **integration** F-1/F-2/F-3 results do NOT depend on any unit-level assume —
> internal signals are driven by composed RTL. The ledger below matters for trusting each
> **unit** proof in isolation.

## Bus-condition / edge contract (driver: `i3c_bus_frontend`)
| Assumed by | Assume | Discharged by (proven assert) | Status |
|---|---|---|---|
| ccc, ibi, daa, error_recovery, framer, bit_engine | START/Sr/STOP mutually exclusive (`$onehot0`/pairwise) | `i3c_bus_frontend.p_excl`, `p_no_startstop` | ✅ |
| ccc, ibi, error_recovery, … | scl edge exclusivity `!(scl_rising&&scl_falling)` | `i3c_bus_frontend.p_scl_edge` | ✅ |
| ibi | scl rising-from-Low / falling-from-High | edge strobes are `scl_sync&~scl_q` etc. (by construction; add explicit asserts) | ⏳ |
| ccc, ibi | no byte_done coincident with a bus condition | front-end gates conditions by `!sda_oe`; byte_done from bit_engine | 🔁 |
| bit_engine, ibi | START/Sr never coincide with an SCL edge (`am_*_noscl`) | needs a front-end assert relating start to scl level | ⏳ |

## Address / phase contract (driver: `i3c_protocol_fsm`)
| Assumed by | Assume | Discharged by | Status |
|---|---|---|---|
| ccc | `!(match_7e && match_da)` address-match exclusivity | `i3c_protocol_fsm` (A1/A3 region) | ✅ |
| ccc | `!match_da \|\| da_valid` | `i3c_protocol_fsm` A2 | ✅ |
| ccc | `phase != 2'd3` (enum only 0–2) | `i3c_pkg::phase_e` definition (structural) | ✅ |
| protocol_fsm (au_*) | 9th-bit/ack-slot/tbit-slot encoding | `i3c_framer` F1 (9th-bit role) | ✅ |

## Identity / config contract (driver: `i3c_regfile`)
| Assumed by | Assume | Discharged by | Status |
|---|---|---|---|
| ccc | `getcaps` bytes == GETCAP{1,2,4} consts, GETCAP3 reserved bits 0 | `i3c_regfile` (getcaps constant assign + ID asserts) | ✅ |
| daa | PID/BCR/DCR stable while busy | `i3c_regfile` ID1–ID3 stability | ✅ |
| ibi | `max_ibi_payload` stable while busy | `i3c_regfile` (config stable unless SET/whole-reset) | ✅ |

## Error-source context contract (drivers: `i3c_daa`, `i3c_ccc`)
| Assumed by | Assume | Discharged by | Status |
|---|---|---|---|
| error_recovery | TE3/TE4 only inside DAA (`m_te3_daa`,`m_te4_daa`) | `i3c_daa` (par_err/te4 only when daa_active) | ⏳ add explicit asserts |
| error_recovery | TE1/TE2/TE5 only outside DAA (`m_te*_ndaa`) | `i3c_ccc`/`i3c_framer` (sources gated by !daa_active) | ⏳ |

## Avalon master contract (driver: external Avalon master — env, not internal)
| Assumed by | Assume | Discharged by | Status |
|---|---|---|---|
| avalon_mm | command stable under `waitrequest` (`am_hold_*`) | Avalon-MM spec obligation on the **master** (external) | ✅ (spec) |

## Controller bus contract (integration, driver: external I3C controller — env)
| Assumed by | Assume | Discharged by | Status |
|---|---|---|---|
| target_top | `am_scl_dwell` SCL stable ≥2 cyc (idealized edges) | STA/sim (oversampling), not formal | 🔁 sim/STA |
| target_top | `am_ca1..am_ca3` controller releases SDA in Target push-pull / no hard-High vs Target-Low | I3C protocol (controller conformance) + sim | 🔁 sim |

**Open ⏳ items** are the remaining soundness work: add the few explicit driver-side asserts
so every unit assume is backed by a proof, then add a CI check that fails if a labelled
`am_*`/`m_*`/`au_*` assume has no matching asserted property.
