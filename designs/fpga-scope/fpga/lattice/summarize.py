#!/usr/bin/env python3
"""summarize.py — scrape fpga/lattice/reports/<cfg>/ into the markdown tables used in README.md.

Every number printed comes from a report file: map.mrp (utilization, EBR instances, map
warnings), synthesis.srr (Synplify @W/@N counts), par.par (PAR warnings, routing) and
timing.twr (post-route STA: Fmax, worst setup/hold slack, constraint coverage).
Usage: python fpga/lattice/summarize.py [> fpga/lattice/reports/summary.md]
"""
import collections
import pathlib
import re
import sys

sys.stdout.reconfigure(encoding="utf-8", newline=chr(10))

HERE = pathlib.Path(__file__).resolve().parent
CFGS = [(32, 8), (32, 12), (32, 15)]


def rd(p):
    return p.read_text(errors="replace")


def one(pat, text, flags=0):
    m = re.search(pat, text, flags)
    if not m:
        sys.exit(f"pattern not found: {pat}")
    return m.groups() if m.lastindex and m.lastindex > 1 else m.group(1)


def section(text, start, end):
    """text between the body heading `start` and the body heading `end` (last occurrences
    of each, so the table of contents at the top of the .twr is skipped)."""
    a = text.rindex(start)
    b = text.rindex(end) if end else len(text)
    return text[a:b]


def slacks(sec):
    return [float(x) for x in re.findall(r"\|\s+(-?\d+\.\d+) ns", sec)]


rows = []
for pw, dl in CFGS:
    d = HERE / "reports" / f"w{pw}_d{dl}"
    mrp, srr, par, twr = (rd(d / n) for n in ("map.mrp", "synthesis.srr", "par.par", "timing.twr"))
    r = {"pw": pw, "dl": dl, "cfg": d.name}
    r["reg"], r["reg_tot"] = one(r"Number of registers:\s+(\d+) out of\s+(\d+)", mrp)
    r["lut"], r["lut_tot"] = one(r"Number of LUT4s:\s+(\d+) out of\s+(\d+)", mrp)
    r["lut_logic"] = one(r"Number used as logic LUT4s:\s+(\d+)", mrp)
    r["lut_dram"] = one(r"Number used as distributed RAM:\s+(\d+)", mrp)
    r["lut_ripple"] = one(r"Number used as ripple logic:\s+(\d+)", mrp)
    r["ebr"], r["ebr_tot"] = one(r"Number of Block RAMs:\s+(\d+) out of\s+(\d+)", mrp)
    r["lram"] = one(r"Number of Large RAMs:\s+(\d+) out of", mrp)
    r["pio"] = one(r"Number of PIOs used:\s+(\d+)", mrp)
    # ASIC Components section: "Instance Name: <inst>" / "Type: EBR_CORE" pairs (a page break
    # may separate a pair, so instances and types are counted independently and cross-checked)
    asic = mrp[mrp.index("ASIC Components"):mrp.index("Constraint Summary")]
    ebr = re.findall(r"Instance Name: (\S+)", asic)
    assert len(ebr) == len(re.findall(r"Type: EBR_CORE", asic)) == int(r["ebr"]), d
    r["ebr_buf"] = sum("u_core/u_buf/" in e for e in ebr)
    r["ebr_meta"] = sum("u_core/u_win_meta/" in e for e in ebr)
    r["ebr_other"] = len(ebr) - r["ebr_buf"] - r["ebr_meta"]
    r["buf_bits"] = (1 << dl) * (pw + 1)
    # warnings
    r["syn_w"] = collections.Counter(re.findall(r"^@W: ?(\w+)", srr, re.M))
    r["syn_n"] = len(re.findall(r"^@N", srr, re.M))
    r["syn_e"] = len(re.findall(r"^@E:", srr, re.M))
    r["map_w"] = one(r"Number of warnings:\s+(\d+)", mrp)
    r["map_c"] = one(r"Number of criticals:\s+(\d+)", mrp)
    r["map_e"] = one(r"Number of errors:\s+(\d+)", mrp)
    r["map_ids"] = collections.Counter(re.findall(r"^WARNING <(\d+)>", mrp, re.M))
    r["par_w"] = len(re.findall(r"^WARNING", par, re.M))
    r["par_e"] = one(r"PAR_SUMMARY::Number of errors = (\d+)", par)
    r["unrouted"] = one(r"PAR_SUMMARY::Number of unrouted conns = (\d+)", par)
    # timing
    r["cov"] = one(r"Constraint Coverage: ([\d.]+)%", twr)
    r["errs"] = re.findall(r"^ (Setup|Hold) at .*?Timing Errors: (\d+) endpoints;  Total Negative Slack: ([\d.]+) ns", twr, re.M)
    fm = re.findall(r"Actual \(all paths\) \|\s+([\d.]+) ns \|\s+([\d.]+) MHz", twr)
    r["period"], r["fmax"] = max(fm, key=lambda x: float(x[0]))
    s85 = slacks(section(twr, "2.2  Endpoint slacks", "2.3  Detailed Report"))
    s0 = slacks(section(twr, "3.2  Endpoint slacks", "3.3  Detailed Report"))
    hold = slacks(section(twr, "4.1  Endpoint slacks", "4.2  Detailed Report"))
    r["setup85"], r["setup0"], r["hold"] = min(s85), min(s0), min(hold)
    r["setup"] = min(r["setup85"], r["setup0"])
    r["loops"] = "none" if re.search(r"1\.5\s+Combinational Loop\s*\n=+\s*\nNone", twr) else "SEE REPORT"
    rows.append(r)

P = print
P("## Utilization (map report, `reports/<cfg>/map.mrp`)\n")
P("| PROBE_W | Depth (2ᴺ) | LUT4 | of which logic / ripple / distributed RAM | registers | EBR blocks | of which capture buffer / win-meta | buffer bits |")
P("|---|---|---|---|---|---|---|---|")
for r in rows:
    P(f"| {r['pw']} | {1 << r['dl']} (N={r['dl']}) | {int(r['lut']):,} / {int(r['lut_tot']):,} | "
      f"{r['lut_logic']} / {r['lut_ripple']} / {r['lut_dram']} | {int(r['reg']):,} / {int(r['reg_tot']):,} | "
      f"{r['ebr']} / {r['ebr_tot']} | {r['ebr_buf']} / {r['ebr_meta']}"
      f"{'' if not r['ebr_other'] else ' (+%d other)' % r['ebr_other']} | {r['buf_bits']:,} |")
P("\nLarge RAMs (LRAM) used: " + ", ".join(f"{r['cfg']}: {r['lram']}" for r in rows) + ".\n")

P("## Timing (post-route STA, `reports/<cfg>/timing.twr`, clk = 10.000 ns)\n")
P("| cfg | worst setup slack | setup slack 85 °C / 0 °C | Fmax (worst corner) | worst hold slack | timing errors (setup 85 / setup 0 / hold) | constraint coverage | comb. loops |")
P("|---|---|---|---|---|---|---|---|")
for r in rows:
    P(f"| {r['cfg']} | {r['setup']:.3f} ns | {r['setup85']:.3f} / {r['setup0']:.3f} ns | "
      f"{r['fmax']} MHz ({r['period']} ns) | {r['hold']:.3f} ns | "
      f"{' / '.join(e[1] for e in r['errs'])} | {r['cov']}% | {r['loops']} |")

P("\n## Warnings\n")
P("| cfg | Synplify @E | Synplify @W | Synplify @N | map errors / criticals / warnings | PAR errors / warnings | unrouted |")
P("|---|---|---|---|---|---|---|")
for r in rows:
    P(f"| {r['cfg']} | {r['syn_e']} | {sum(r['syn_w'].values())} | {r['syn_n']} | "
      f"{r['map_e']} / {r['map_c']} / {r['map_w']} | {r['par_e']} / {r['par_w']} | {r['unrouted']} |")
P("\nSynplify @W by message ID:\n")
ids = sorted({k for r in rows for k in r["syn_w"]})
P("| cfg | " + " | ".join(ids) + " |")
P("|---|" + "---|" * len(ids))
for r in rows:
    P(f"| {r['cfg']} | " + " | ".join(str(r["syn_w"].get(k, 0)) for k in ids) + " |")
P("\nMap warnings by message ID: " + "; ".join(
    f"{r['cfg']}: " + ", ".join(f"{k} ×{v}" for k, v in sorted(r["map_ids"].items())) for r in rows) + ".")
