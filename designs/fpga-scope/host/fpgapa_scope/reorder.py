"""Time-order reconstruction — the normative issue-#7 host math (docs/DESIGN.md), proven by
tb_pretrig. The core stores a circular slice and does no reordering; the host restores time
order from `trig_index`, `wrapped`, and `PRETRIG_EFF`.
"""
from __future__ import annotations


def reorder_window(slice_buf, trig_index_rel: int, wrapped: bool, pretrig_eff: int):
    """Return (ordered_samples, trigger_position). `slice_buf` is one window's samples in raw
    buffer (address) order; `trig_index_rel` is the trigger address relative to the slice base.

        post   = SLICE - PRETRIG_EFF                     # trigger sample included in post
        oldest = wrapped ? (trig_index + post) % SLICE : 0
        ordered[i] = slice_buf[(oldest + i) % SLICE]
    """
    n = len(slice_buf)
    if n == 0:
        return [], 0
    post = n - pretrig_eff
    oldest = (trig_index_rel + post) % n if wrapped else 0
    ordered = [slice_buf[(oldest + i) % n] for i in range(n)]
    trig_pos = pretrig_eff if wrapped else trig_index_rel
    return ordered, trig_pos
