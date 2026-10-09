"""RLE decode — mirror of sim/model/scope_ref.py rle_decode (issue #9).

A DRAIN with rle_flag=1 delivers PROBE_W+1-bit words `{is_count, value}`. Decode expands them
back to the raw sample stream; the host then applies the issue-#7 reorder math in the raw domain.
"""
from __future__ import annotations


def rle_decode_words(words, probe_w: int):
    """`words`: list of ints, each is_count in bit `probe_w`, value in bits [probe_w-1:0].

    A reordered RLE window can begin mid-run (its opening count word's data value lives in a
    word outside the window — e.g. a word-domain PRETRIG slice that starts partway through a
    run). Those leading repeats are unreconstructable, so a count word seen before any data
    word is skipped rather than emitting undefined samples. A complete stream (which always
    opens with a data word) is unaffected, so this matches scope_ref.rle_decode there."""
    mask = (1 << probe_w) - 1
    out = []
    cur = None
    for w in words:
        is_count = (w >> probe_w) & 1
        val = w & mask
        if is_count == 0:
            cur = val
            out.append(cur)
        elif cur is not None:
            out.extend([cur] * val)
    return out
