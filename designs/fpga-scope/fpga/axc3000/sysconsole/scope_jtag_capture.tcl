# scope_jtag_capture.tcl [outfile] — capture over the scope_jtag BYTE bridge on the AXC3000 (#15).
#
# Speaks the framed protocol (0xA5 0x5C | cmd | len | payload | crc16) over the bridge at 0x800
# exactly as the UART/host path does, so the drained bytes feed the UNCHANGED host decoder
# (jtag_decode.py -> frame.parse_all + decode_drain). Mirrors #12's cs_n-falling-edge capture but
# over the byte stream instead of direct CSR. Caller holds /tmp/axc3000-devkit.lock.
#
#   flock -w 300 /tmp/axc3000-devkit.lock system-console --script=sysconsole/scope_jtag_capture.tcl scope_jtag_bytes.txt

set BASE   0x800
set TXDATA $BASE
set RXDATA [expr {$BASE + 4}]
set STATUS [expr {$BASE + 8}]
# bw_test at 0x000 — used to make cs_n fall
set BW_CTRL 0x00
set BW_LEN  0x04
set BW_BASE 0x08

# frame op codes / CSR words (mirror rtl/scope_pkg.sv, host/fpgapa_scope)
set OP_PING 0x01; set OP_RD 0x02; set OP_WR 0x03; set OP_DRAIN 0x04
set W_CTRL 2; set W_STATUS 3; set W_PRETRIG 4; set W_WINDOWS 5; set W_RLE 6
set W_CMP_SEL 15; set W_CMP_LANE 16; set W_COMBINE 64; set W_SEQ0 65

set outfile "scope_jtag_bytes.txt"
if {$argc >= 1} { set outfile [lindex $argv 0] }

proc rd32 {m a} { return [expr {[lindex [master_read_32 $m $a 1] 0] & 0xffffffff}] }

set paths [get_service_paths master]
if {[llength $paths] == 0} { puts "ERROR: no master service"; exit 1 }
set m [lindex $paths 0]
open_service master $m

# ---- byte pump over the bridge ----
proc send_byte {m b} {
    global TXDATA STATUS
    while {([rd32 $m $STATUS] & 0x2) == 0} {}     ;# poll can_write
    master_write_32 $m $TXDATA [expr {$b & 0xff}]
}
proc recv_byte {m} {
    global RXDATA
    for {set i 0} {$i < 2000000} {incr i} {
        set v [rd32 $m $RXDATA]
        if {($v & 0x100) != 0} { return [expr {$v & 0xff}] }
    }
    error "recv_byte timeout"
}

proc crc16 {bytes} {
    set c 0xFFFF
    foreach b $bytes {
        set c [expr {$c ^ (($b & 0xff) << 8)}]
        for {set i 0} {$i < 8} {incr i} {
            if {$c & 0x8000} { set c [expr {(($c << 1) ^ 0x1021) & 0xffff}] } else { set c [expr {($c << 1) & 0xffff}] }
        }
    }
    return $c
}
proc send_frame {m cmd payload} {
    set body [list $cmd [expr {([llength $payload] >> 8) & 0xff}] [expr {[llength $payload] & 0xff}]]
    foreach p $payload { lappend body $p }
    set crc [crc16 $body]
    send_byte $m 0xA5; send_byte $m 0x5C
    foreach b $body { send_byte $m $b }
    send_byte $m [expr {($crc >> 8) & 0xff}]; send_byte $m [expr {$crc & 0xff}]
}
# receive one frame; returns "cmd byte0 byte1 ..." (payload). Also appends every raw byte to ::rawlog if logging.
proc recv_frame {m} {
    while {[recv_byte $m] != 0xA5} {}             ;# hunt sync0
    if {[recv_byte $m] != 0x5C} { error "sync1" }
    set cmd [recv_byte $m]
    set lh [recv_byte $m]; set ll [recv_byte $m]
    set len [expr {($lh << 8) | $ll}]
    set pl [list]
    for {set i 0} {$i < $len} {incr i} { lappend pl [recv_byte $m] }
    recv_byte $m; recv_byte $m                    ;# crc (not re-checked here; host re-checks)
    return [list $cmd $pl]
}
proc write_csr {m word val} {
    global OP_WR
    send_frame $m $OP_WR [list $word [expr {($val>>24)&0xff}] [expr {($val>>16)&0xff}] [expr {($val>>8)&0xff}] [expr {$val&0xff}]]
    recv_frame $m
}
proc read_csr {m word} {
    global OP_RD
    send_frame $m $OP_RD [list $word]
    set r [recv_frame $m]; set pl [lindex $r 1]
    return [expr {([lindex $pl 0]<<24)|([lindex $pl 1]<<16)|([lindex $pl 2]<<8)|[lindex $pl 3]}]
}

# ---- identify ----
puts "sending PING..."; flush stdout
send_frame $m $OP_PING {}
set p [recv_frame $m]; set pl [lindex $p 1]
set idv [expr {([lindex $pl 4]<<24)|([lindex $pl 5]<<16)|([lindex $pl 6]<<8)|[lindex $pl 7]}]
puts [format "PING ID_VALUE=0x%08X (expect 0xA3C30015)" $idv]; flush stdout

# ---- configure: cs_n (probe bit0) FALLING-edge trigger, RLE on, no pretrig ----
write_csr $m $W_CTRL 0x8            ;# soft_rst
write_csr $m $W_PRETRIG 0
write_csr $m $W_WINDOWS 1
write_csr $m $W_RLE 1
write_csr $m $W_CMP_SEL [expr {(2<<2)|0}]; write_csr $m $W_CMP_LANE 0x1   ;# edge_mask bit0
write_csr $m $W_CMP_SEL [expr {(3<<2)|0}]; write_csr $m $W_CMP_LANE 0x0   ;# edge_pol 0 = falling
write_csr $m $W_COMBINE 0x1
write_csr $m $W_SEQ0 1
puts "configured; arming..."; flush stdout

# warm up + arm, wait ARMED, then pulse bw_test so cs_n falls while armed
master_write_32 $m $BW_LEN 64; master_write_32 $m $BW_BASE 0; master_write_32 $m $BW_CTRL 1
after 20
write_csr $m $W_CTRL 0x1
for {set i 0} {$i < 100000} {incr i} { if {([read_csr $m $W_STATUS] & 0x7) == 2} break }
for {set i 0} {$i < 64} {incr i} {
    if {([read_csr $m $W_STATUS] & 0x7) == 4} break
    master_write_32 $m $BW_LEN 64; master_write_32 $m $BW_BASE 0; master_write_32 $m $BW_CTRL 1
    after 5
}
set st [read_csr $m $W_STATUS]
puts [format "STATUS=0x%08X (state=%d triggered=%d)" $st [expr {$st&7}] [expr {($st>>3)&1}]]
if {($st & 0x7) != 4} { puts "ERROR: not DONE"; close_service master $m; exit 1 }

# ---- DRAIN: collect every raw response byte to the file for the host decoder ----
send_frame $m $OP_DRAIN {}
set fp [open $outfile w]
# read frames until the stream goes quiet (a short run of no-byte reads)
set idle 0
while {$idle < 200} {
    set v [rd32 $m $RXDATA]
    if {($v & 0x100) != 0} { puts -nonewline $fp [format "%02x" [expr {$v & 0xff}]]; set idle 0 } else { incr idle }
}
close $fp
puts "DRAINED bytes -> $outfile"
close_service master $m
