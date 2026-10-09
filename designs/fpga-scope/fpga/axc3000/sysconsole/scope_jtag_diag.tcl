# scope_jtag_diag.tcl — quick reachability check for the #15 byte bridge at 0x800.
proc rd32 {m a} { return [expr {[lindex [master_read_32 $m $a 1] 0] & 0xffffffff}] }
set m [lindex [get_service_paths master] 0]
open_service master $m
puts [format "DIAG bw MAGIC   (0x01C) = 0x%08X" [rd32 $m 0x01C]]
puts [format "DIAG CSR-scope  (0x400) = 0x%08X (expect 0x5C09E001)" [rd32 $m 0x400]]
puts [format "DIAG jtag STATUS(0x808) = 0x%08X (bit1=can_write bit0=rx_avail)" [rd32 $m 0x808]]
puts [format "DIAG jtag RXDATA(0x804) = 0x%08X" [rd32 $m 0x804]]
master_write_32 $m 0x800 0xA5
puts [format "DIAG after TX 0xA5, STATUS(0x808) = 0x%08X (expect can_write=0)" [rd32 $m 0x808]]
master_write_32 $m 0x800 0x5C
after 10
puts [format "DIAG after TX 0x5C, STATUS(0x808) = 0x%08X" [rd32 $m 0x808]]
close_service master $m
puts "DIAG done"
