# scope_capture.tcl — drive the fpga-scope instance on the AXC3000 over CSR-over-JTAG-Avalon (#12).
#
# Arms the scope with a "cs_n falling edge" trigger (HyperBus transaction start), kicks one bw_test
# HyperRAM transaction so cs_n actually falls, waits for DONE, and drains the RLE word buffer to a
# text file that fpga/axc3000/reconstruct.py turns into a VCD.
#
# Run inside Quartus System Console (caller holds the board lock):
#   flock -w 600 /tmp/axc3000-devkit.lock system-console --script=sysconsole/scope_capture.tcl [outfile] [pretrig] [len]
#
# CSR maps on the single JTAG-Avalon master (byte offsets, decoded in top_scope.sv):
#   hyperram_bw_test @ 0x000   |   fpga-scope CSR @ 0x400 (m_address[10]) — register k at 0x400+4k

# ---- fpga-scope register byte offsets (base 0x400; scope_pkg word index * 4) ----
set S_ID        0x400   ;# RO magic 0x5C09E001
set S_HWCFG     0x404
set S_CTRL      0x408   ;# W: bit0 arm, bit1 disarm, bit2 force_trig, bit3 soft_rst
set S_STATUS    0x40C   ;# R: [2:0] state, [3] triggered, [4] wrapped, [5] cfg_err, [15:8] windows_done
set S_PRETRIG   0x410
set S_WINDOWS   0x414
set S_RLE_CTRL  0x418   ;# bit0 rle_enable
set S_TRIG_IDX  0x424
set S_TSTRIG_LO 0x428
set S_TSTRIG_HI 0x42C
set S_CMP_SEL   0x43C   ;# [1:0] comparator, [3:2] field (0 mask,1 value,2 edge_mask,3 edge_pol)
set S_CMP_LANE0 0x440   ;# lane 0 (probe bits [31:0]) of the selected comparator field
set S_COMBINE   0x500   ;# TRIG_COMBINE (word 64)
set S_SEQ0      0x504   ;# SEQ_CNT0 (word 65)
set S_BUF_CTRL  0x580   ;# W bit0 = reset drain pointer
set S_BUF_DATA  0x584   ;# R: next 32-bit lane of the current word, auto-advances lane->addr

set STATE_DONE  4

# ---- hyperram_bw_test offsets (to make cs_n fall) ----
set BW_CTRL 0x00
set BW_LEN  0x04
set BW_BASE 0x08
set BW_MAGIC 0x1C

# ---- args ----
set outfile "scope_dump.txt"
set pretrig 64
set len 64
set STATE_ARMED 2
if {$argc >= 1} { set outfile [lindex $argv 0] }
if {$argc >= 2} { set pretrig [expr {int([lindex $argv 1])}] }
if {$argc >= 3} { set len     [expr {int([lindex $argv 2])}] }

proc rd32 {m a} { return [expr {[lindex [master_read_32 $m $a 1] 0] & 0xffffffff}] }

# ---- open the JTAG-to-Avalon master ----
set paths [get_service_paths master]
if {[llength $paths] == 0} {
    puts "ERROR: no Avalon 'master' service. Is the board programmed + USB Blaster III attached?"
    exit 1
}
set m [lindex $paths 0]
open_service master $m
puts "Opened master service: $m"

# ---- identify the scope ----
set id [rd32 $m $S_ID]
puts [format "SCOPE ID   = 0x%08X (expect 0x5C09E001)" $id]
if {$id != 0x5C09E001} {
    puts "ERROR: scope ID mismatch — wrong bitstream / address map."
    close_service master $m
    exit 1
}
set hwcfg [rd32 $m $S_HWCFG]
puts [format "SCOPE HWCFG= 0x%08X (PROBE_W=%d DEPTH_LOG2=%d RLE_EN=%d)" \
        $hwcfg [expr {$hwcfg & 0x3ff}] [expr {($hwcfg >> 10) & 0xf}] [expr {($hwcfg >> 18) & 1}]]
set depth [expr {1 << (($hwcfg >> 10) & 0xf)}]

# ---- soft reset, then configure the trigger: comparator 0 = cs_n (probe bit0) FALLING edge ----
master_write_32 $m $S_CTRL 0x8                 ;# soft_rst (clears cfg_err / drain ptr)
master_write_32 $m $S_PRETRIG $pretrig
master_write_32 $m $S_WINDOWS 1
master_write_32 $m $S_RLE_CTRL 1               ;# enable RLE compression
# cmp0 edge_mask: select {field=edge_mask(2), cmp=0} -> lane0 = bit0
master_write_32 $m $S_CMP_SEL [expr {(2 << 2) | 0}]
master_write_32 $m $S_CMP_LANE0 0x1
# cmp0 edge_pol: {field=edge_pol(3), cmp=0} -> lane0 = 0 (bit0 pol=0 => FALLING)
master_write_32 $m $S_CMP_SEL [expr {(3 << 2) | 0}]
master_write_32 $m $S_CMP_LANE0 0x0
# combine stage 0 selects cmp0 (OR mode); 1 occurrence
master_write_32 $m $S_COMBINE 0x00000001
master_write_32 $m $S_SEQ0 1

set st [rd32 $m $S_STATUS]
if {(($st >> 5) & 1) != 0} { puts "WARNING: cfg_err set after config"; }

# ---- warm up the HyperRAM once (ensures init_done before the captured run) ----
master_write_32 $m $BW_LEN  $len
master_write_32 $m $BW_BASE 0x0
master_write_32 $m $BW_CTRL 0x1
after 20

# ---- ARM and wait until the core is actually in ARMED (FILLING drains the pretrig backlog;
#      with a compressible idle cs_n that can take a moment) BEFORE falling cs_n, or the
#      trigger edge would land in FILLING (ignored) and be missed. ----
master_write_32 $m $S_CTRL 0x1                 ;# arm
set armed 0
for {set i 0} {$i < 100000} {incr i} {
    set st [rd32 $m $S_STATUS]
    if {($st & 0x7) == $STATE_ARMED} { set armed 1; break }
    if {($st & 0x7) == $STATE_DONE}  { set armed 1; break }
}
puts [format "post-arm state=%d (armed_reached=%d)" [expr {$st & 7}] $armed]

# ---- now fall cs_n while ARMED: pulse the bw_test a few times so a falling edge is caught ----
set done 0
for {set i 0} {$i < 64} {incr i} {
    set st [rd32 $m $S_STATUS]
    if {($st & 0x7) == $STATE_DONE} { set done 1; break }
    master_write_32 $m $BW_LEN  $len
    master_write_32 $m $BW_BASE 0x0
    master_write_32 $m $BW_CTRL 0x1            ;# HyperBus burst -> cs_n falling edge
    after 5
}
puts [format "pulsed bw_test; STATUS=0x%08X" $st]

# ---- poll for DONE ----
for {set i 0} {$i < 200000 && !$done} {incr i} {
    set st [rd32 $m $S_STATUS]
    if {($st & 0x7) == $STATE_DONE} { set done 1; break }
}
if {!$done} {
    puts [format "ERROR: scope never reached DONE. STATUS=0x%08X (state=%d triggered=%d)" \
            $st [expr {$st & 7}] [expr {($st >> 3) & 1}]]
    close_service master $m
    exit 1
}
set wrapped   [expr {($st >> 4) & 1}]
set triggered [expr {($st >> 3) & 1}]
set trig_idx  [rd32 $m $S_TRIG_IDX]
set ts_lo     [rd32 $m $S_TSTRIG_LO]
set ts_hi     [rd32 $m $S_TSTRIG_HI]
set rle_flag  [expr {($hwcfg >> 18) & 1}]
puts [format "DONE: triggered=%d wrapped=%d trig_index=%d ts_at_trig=0x%X%08X" \
        $triggered $wrapped $trig_idx $ts_hi $ts_lo]

# ---- drain the RLE word buffer (STORE_W = PROBE_W+1 = 33 bits => 2 lanes/word) ----
master_write_32 $m $S_BUF_CTRL 0x1             ;# reset drain pointer
set fp [open $outfile w]
puts $fp [format "# fpga-scope AXC3000 capture (CSR-over-JTAG)"]
puts $fp [format "probe_w 32"]
puts $fp [format "store_w 33"]
puts $fp [format "rle %d" $rle_flag]
puts $fp [format "wrapped %d" $wrapped]
puts $fp [format "trig_index %d" $trig_idx]
puts $fp [format "pretrig %d" $pretrig]
puts $fp [format "depth %d" $depth]
puts $fp [format "ts_at_trig %d" [expr {($ts_hi << 32) | $ts_lo}]]
puts $fp "# words: one STORE_W value per line, buffer (address) order"
for {set i 0} {$i < $depth} {incr i} {
    set lane0 [rd32 $m $S_BUF_DATA]            ;# word[31:0]
    set lane1 [rd32 $m $S_BUF_DATA]            ;# word[63:32]; bit0 = is_count (bit 32)
    set word  [expr {$lane0 | (($lane1 & 0x1) << 32)}]
    puts $fp $word
}
close $fp
puts [format "DRAINED %d words -> %s" $depth $outfile]
close_service master $m
