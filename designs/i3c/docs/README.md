# Documentation Index

Documentation for the formally-verified **MIPI I3C Basic v1.2 SDR + In-Band-Interrupt
Target (endpoint)** — a device-agnostic SystemVerilog core with an Avalon-MM application
interface. Start with the project [README](../README.md), then dive in by topic below.

Status at a glance: **formal ALL GREEN** (14 modules + integration, 41 proof tasks,
~280 assertions) · **simulation 29/29 PASS** (Icarus controller BFM) · **Quartus Prime
Pro 25.3** internal logic meets 125 MHz (reg-to-reg +2.15 ns, Fmax ≈ 244 MHz; readdata registered (2-cycle); residual avs_waitrequest −1.81 ns is required-combinational, pad-buffer-limited only standalone — see syn/altera/README) on Cyclone 10 GX, 528 ALMs / 348 regs / 2 RAM.

## Overview

- [`../README.md`](../README.md) — Project overview: features, top-level datapath, quickstart, and the integration guide.
- [`architecture.md`](architecture.md) — Module hierarchy, top-level block diagram, clocking/CDC strategy, the Avalon-MM register map, and the full formal property plan.

## Design

- [`requirements.md`](requirements.md) — Extracted MIPI I3C Basic v1.2 (SDR + IBI) requirements — the source of every proof obligation.
- [`design_decisions.md`](design_decisions.md) — The v1 freeze (BCR/DCR, DA methods, clocking, critique fixes F-1..F-9) and the remaining open product decisions.
- [`diagrams.md`](diagrams.md) — Per-module FSM state diagrams and transaction sequence diagrams (ENTDAA / private write / private read / GETSTATUS / IBI).
- [`critique.md`](critique.md) — Completeness & risk review of the requirements and architecture (origin of the F-1..F-9 fixes).
- [`open_questions.md`](open_questions.md) — Design questions collected during requirements extraction (resolved and still-open product decisions).

## Verification

- [`verification_status.md`](verification_status.md) — Per-module proof matrix, the three-way cross-check (formal / sim / STA), and the honest known-gaps list.
- [`findings.md`](findings.md) — The 8 integration bugs simulation caught that the per-module formal proofs missed (all 8 fixed and re-verified).
- [`coverage.md`](coverage.md) — What "100% coverage" does and doesn't mean here, mutation coverage (`mcy`), and how a third party independently confirms the proofs.
- [`assume_ledger.md`](assume_ledger.md) — The assume↔assert ledger (F-9): every standalone-proof `assume` mapped to a neighbour's proven `assert`.
- [`../sim/README.md`](../sim/README.md) — Icarus controller-BFM testbench structure and results (29/29 PASS).
- [`../syn/altera/README.md`](../syn/altera/README.md) — Quartus Prime Pro build, device, and STA timing results (Cyclone 10 GX).

## Reference

- [`modules.md`](modules.md) — Per-module reference: responsibility, load-bearing ports/parameters, and the key formal properties each module proves.
- [`interfaces.md`](interfaces.md) — The frozen module port lists and the top-level connectivity contract.

---

*Spec reference: MIPI I3C Basic Specification v1.2 (public edition), included at the repo
root as `MIPI-I3C-Basic-Specification-v1-2-public-edition-er01.pdf`.*
