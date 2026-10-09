"""CSR word offsets and ID constants — mirror of rtl/scope_pkg.sv / docs/INTERFACES.md v1.

Register k is at host byte offset 4*k on the CSR bus, or addressed by word index k in the
READ_CSR/WRITE_CSR frame payload. Kept in lockstep with the frozen INTERFACES.md v1 map (#5/#8).
"""
ID_MAGIC = 0x5C09E000
VERSION = 0x01
ID_REG = ID_MAGIC | VERSION

# word offsets (INTERFACES.md v1)
ID = 0
HWCFG = 1
CTRL = 2            # W strobes: bit0 arm, bit1 disarm, bit2 force_trig, bit3 soft_rst
STATUS = 3          # {.., windows_done[15:8], cfg_err[5], wrapped[4], triggered[3], state[2:0]}
PRETRIG = 4
WINDOWS = 5
RLE_CTRL = 6        # bit0 rle_enable
TS_LO = 7
TS_HI = 8
TRIG_INDEX = 9
TSTRIG_LO = 10
TSTRIG_HI = 11
WIN_SEL = 12
WIN_META = 13
SMPL_CTRL = 14     # [23:0] decimation (store 1/(N+1) cycles), [24] qual_en, [26:25] qual_sel (#17/#20)
CMP_SEL = 15        # [1:0] comparator k, [3:2] field (0 mask,1 value,2 edge_mask,3 edge_pol)
CMP_LANE_BASE = 16  # 16..31: lane window of the selected comparator field
CMP_LANE_WORDS = 16
TRIG_COMBINE = 64
SEQ_CNT_BASE = 65   # 65..68 = SEQ_CNT0..3
BUF_CTRL = 96
BUF_DATA = 97

# CTRL strobe bits
CTRL_ARM = 1 << 0
CTRL_DISARM = 1 << 1
CTRL_FORCE_TRIG = 1 << 2
CTRL_SOFT_RST = 1 << 3

# CMP_SEL field codes
CMP_FIELD_MASK = 0
CMP_FIELD_VALUE = 1
CMP_FIELD_EDGE_MASK = 2
CMP_FIELD_EDGE_POL = 3

# STATUS bit positions
STATE_SHIFT = 0
TRIGGERED_BIT = 3
WRAPPED_BIT = 4
CFG_ERR_BIT = 5
WINDOWS_DONE_SHIFT = 8

STATE_IDLE, STATE_FILLING, STATE_ARMED, STATE_TRIGGERED, STATE_DONE = range(5)
STATE_NAMES = {0: "IDLE", 1: "FILLING", 2: "ARMED", 3: "TRIGGERED", 4: "DONE"}


def smpl_ctrl(decim: int = 0, qual_en: bool = False, qual_sel: int = 0) -> int:
    """Pack the SMPL_CTRL word (word 14): decimation store-every-(decim+1) + storage qualification
    on comparator `qual_sel`. decim=0, qual_en=False => sample every cycle, no qualification."""
    return (decim & 0xFFFFFF) | ((1 if qual_en else 0) << 24) | ((qual_sel & 0x3) << 25)


def decode_status(word: int) -> dict:
    return {
        "state": word & 0x7,
        "state_name": STATE_NAMES.get(word & 0x7, "?"),
        "triggered": bool(word & (1 << TRIGGERED_BIT)),
        "wrapped": bool(word & (1 << WRAPPED_BIT)),
        "cfg_err": bool(word & (1 << CFG_ERR_BIT)),
        "windows_done": (word >> WINDOWS_DONE_SHIFT) & 0xFF,
    }
