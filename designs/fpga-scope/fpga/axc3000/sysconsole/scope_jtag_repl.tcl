# scope_jtag_repl.tcl <BASE_hex> — a byte pump for the scope_jtag bridge, driven line-by-line from
# stdin (issue #15). The Python host (fpgapa_scope.jtag.JtagTransport) spawns
#   system-console --script=scope_jtag_repl.tcl <BASE>
# and moves whole frames through it, so the ordinary frame codec + decode_drain work unchanged.
#
# BASE = byte address of the scope_jtag register window on the JTAG-Avalon master.
#   TXDATA = BASE+0  RXDATA = BASE+4  STATUS = BASE+8   (word-addressed; see rtl/if/scope_jtag.sv)
#
# stdin protocol (one command per line; each prints exactly one reply line, then flushes):
#   W <hex> [<hex> ...]  -> write each byte to TXDATA (poll STATUS.can_write first) -> "OK"
#   R <n>                -> up to n RXDATA reads, collect available bytes           -> "D <hex...>"
#   Q                    -> quit

set BASE 0x400
if {$argc >= 1} { set BASE [expr {[lindex $argv 0]}] }
set TXDATA $BASE
set RXDATA [expr {$BASE + 4}]
set STATUS [expr {$BASE + 8}]

proc rd32 {m a} { return [expr {[lindex [master_read_32 $m $a 1] 0] & 0xffffffff}] }

set paths [get_service_paths master]
if {[llength $paths] == 0} { puts "ERR no master"; flush stdout; exit 1 }
set m [lindex $paths 0]
open_service master $m

while {[gets stdin line] >= 0} {
    set line [string trim $line]
    if {$line eq ""} { continue }
    set tok [split $line]
    set op [lindex $tok 0]
    switch -- $op {
        W {
            foreach h [lrange $tok 1 end] {
                # wait for space in the 1-deep tx buffer
                while {([rd32 $m $STATUS] & 0x2) == 0} {}
                master_write_32 $m $TXDATA [expr {"0x$h" & 0xff}]
            }
            puts "OK"
        }
        R {
            set n [expr {int([lindex $tok 1])}]
            set out ""
            for {set i 0} {$i < $n} {incr i} {
                set v [rd32 $m $RXDATA]
                if {($v & 0x100) != 0} { append out [format "%02x" [expr {$v & 0xff}]] } else { break }
            }
            puts "D $out"
        }
        Q { break }
        default { puts "ERR bad" }
    }
    flush stdout
}
close_service master $m
