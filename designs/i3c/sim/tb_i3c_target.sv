// ============================================================================
// tb_i3c_target.sv  -  Behavioral testbench for i3c_target_top (Icarus Verilog)
//
// Exercises the integrated Target through (a) the Avalon-MM application port and
// (b) a bit-level I3C controller BFM driving the open-drain SDA/SCL bus, covering
// the obligations that formal does NOT (real transactions end-to-end, timing/dwell,
// liveness of a full sequence). Open-drain bus = `tri1` net with pull-up; both the
// Target (via i3c_io_altera) and the BFM drive it through tri-state.
//
// Run: sim/run.sh   (iverilog -g2012)
// ============================================================================
`timescale 1ns/1ps

module tb_i3c_target;

  // ---- clock / reset --------------------------------------------------------
  logic clk = 1'b0;
  always #5 clk = ~clk;          // 100 MHz sys_clk
  logic rst_n = 1'b0;

  // ---- Avalon-MM ------------------------------------------------------------
  logic [4:0]  avs_address  = '0;
  logic        avs_read     = 1'b0;
  logic        avs_write    = 1'b0;
  logic [31:0] avs_writedata= '0;
  logic [3:0]  avs_byteenable = 4'hF;
  logic [31:0] avs_readdata;
  logic        avs_readdatavalid;
  logic        avs_waitrequest;
  logic        irq;

  // ---- I3C open-drain bus ---------------------------------------------------
  tri1 SDA;                      // pull-up to 1 when released
  wire  SCL;
  // controller drivers
  logic ctl_oe = 1'b0;           // 1 => controller drives SDA
  logic ctl_o  = 1'b1;
  logic scl_drv = 1'b1;          // controller drives SCL (push-pull); idle high
  assign SDA = ctl_oe ? ctl_o : 1'bz;
  assign SCL = scl_drv;

  // ---- DUT ------------------------------------------------------------------
  localparam logic [14:0] TB_MFG  = 15'h2A5;
  localparam logic [31:0] TB_PIDV = 32'h1234_5678;
  localparam logic [7:0]  TB_BCR  = 8'h07;
  localparam logic [7:0]  TB_DCR  = 8'h00;

  i3c_target_top #(
    .BCR(TB_BCR), .DCR(TB_DCR), .MFG_ID(TB_MFG), .PID_TYPE(1'b0), .PID_VAL(TB_PIDV),
    .RX_DEPTH(8), .TX_DEPTH(8),
    .BUS_FREE_CYCLES(2), .BUS_AVAIL_CYCLES(4), .BUS_IDLE_CYCLES(8)
  ) dut (
    .clk(clk), .rst_n(rst_n), .avl_clk(clk), .avl_rst_n(rst_n),
    .avs_address(avs_address), .avs_read(avs_read), .avs_write(avs_write),
    .avs_writedata(avs_writedata), .avs_byteenable(avs_byteenable),
    .avs_readdata(avs_readdata), .avs_readdatavalid(avs_readdatavalid),
    .avs_waitrequest(avs_waitrequest), .irq(irq),
    .SDA(SDA), .SCL(SCL)
  );

  // ---- scoreboard -----------------------------------------------------------
  integer pass = 0, fail = 0;
  task automatic check(input logic cond, input string msg);
    if (cond) begin pass++; $display("  [PASS] %s", msg); end
    else      begin fail++; $display("  [FAIL] %s", msg); end
  endtask

  // ---- register-map indices -------------------------------------------------
  localparam [4:0] R_CTRL=0,R_STATUS=1,R_INT_EN=2,R_INT_ST=3,R_DYN=4,R_PIDL=5,
                   R_PIDH=6,R_IDENT=7,R_MWL=8,R_MRL=9,R_IBI_CTRL=10,R_IBI_ST=11,
                   R_RX=12,R_TX=13,R_FIFO=14,R_GSCFG=15,R_CAPS=16,R_RESET=17;

  // ==========================================================================
  // Avalon master tasks
  // ==========================================================================
  task automatic avl_wr(input [4:0] a, input [31:0] d, input [3:0] be = 4'hF);
    @(posedge clk);
    avs_address <= a; avs_writedata <= d; avs_byteenable <= be; avs_write <= 1'b1;
    @(posedge clk);
    while (avs_waitrequest) @(posedge clk);          // honor back-pressure
    avs_write <= 1'b0; avs_byteenable <= 4'hF;
    @(posedge clk);
  endtask

  task automatic avl_rd(input [4:0] a, output [31:0] d);
    @(posedge clk);
    avs_address <= a; avs_read <= 1'b1;
    @(posedge clk);
    avs_read <= 1'b0;
    while (!avs_readdatavalid) @(posedge clk);       // fixed 1-cycle, but be safe
    d = avs_readdata;
    @(posedge clk);
  endtask

  // ==========================================================================
  // I3C controller BFM (bit-level, oversample-friendly dwell = PH sys_clk cyc)
  // ==========================================================================
  localparam int PH = 8;                              // sys_clk cycles per SCL half-bit
  task automatic clkw(input int n); repeat (n) @(posedge clk); endtask

  // entry/exit of every byte routine: SCL low.
  task automatic bus_start;                            // idle (SCL hi, SDA hi) -> START
    ctl_oe <= 1'b1; ctl_o <= 1'b1; scl_drv <= 1'b1; clkw(PH);
    ctl_o  <= 1'b0; clkw(PH);                          // SDA 1->0 while SCL hi = START
    scl_drv<= 1'b0; clkw(PH);                          // SCL low
  endtask
  task automatic bus_rstart;                           // (SCL low) -> repeated START
    ctl_oe <= 1'b1; ctl_o <= 1'b1; clkw(PH);           // SDA hi, SCL low
    scl_drv<= 1'b1; clkw(PH);                          // SCL hi, SDA hi
    ctl_o  <= 1'b0; clkw(PH);                          // SDA 1->0 while SCL hi = Sr
    scl_drv<= 1'b0; clkw(PH);                          // SCL low
  endtask
  task automatic bus_stop;                             // (SCL low) -> STOP
    ctl_oe <= 1'b1; ctl_o <= 1'b0; clkw(PH);           // SDA low, SCL low
    scl_drv<= 1'b1; clkw(PH);                          // SCL hi, SDA low
    ctl_o  <= 1'b1; clkw(PH);                          // SDA 0->1 while SCL hi = STOP
    ctl_oe <= 1'b0; clkw(PH);                          // release
  endtask

  // drive one controller bit (push-pull): entry SCL low, exit SCL low
  task automatic drive_bit(input logic b);
    ctl_oe <= 1'b1; ctl_o <= b; clkw(PH);              // setup while SCL low
    scl_drv<= 1'b1;             clkw(PH);              // SCL hi: target samples on rise
    scl_drv<= 1'b0;
  endtask
  // sample one target-driven bit: entry SCL low, exit SCL low.
  // Sample NEAR the rising edge (real controllers latch SDA at SCL^): the
  // oversampled target ends a driven slot at its sync-delayed 9th rising, so a
  // late-in-high sample would miss it.
  task automatic read_bit(output logic b);
    ctl_oe <= 1'b0; clkw(PH);                          // release; target drives on its scl_fall
    scl_drv<= 1'b1; clkw(3);                           // just past the rising edge
    b = SDA;                                            // sample resolved bus
    clkw(1); scl_drv <= 1'b0;                           // lower SCL promptly (before target
    clkw(PH-4);                                         // releases a driven bit -> avoids false STOP)
  endtask

  // send a byte MSb-first, then read the 9th (ACK) bit. ack=1 means ACKed (SDA low).
  task automatic send_byte_ack(input [7:0] data, output logic ack);
    logic bit9; int i;
    for (i=7;i>=0;i--) drive_bit(data[i]);
    read_bit(bit9);
    ack = ~bit9;
  endtask
  // send a byte MSb-first, then drive the 9th as a write T-bit (odd parity).
  task automatic send_byte_tbit(input [7:0] data);
    int i;
    for (i=7;i>=0;i--) drive_bit(data[i]);
    drive_bit(~(^data));                               // odd parity T-bit (framer expects ~^byte)
  endtask
  // read a byte from the target MSb-first, then read the target's T-bit.
  task automatic read_byte_tbit(output [7:0] data, output logic tbit);
    logic b; int i;
    data = 8'h00;
    for (i=7;i>=0;i--) begin read_bit(b); data[i] = b; end
    read_bit(tbit);
  endtask

  // ==========================================================================
  // Test sequences
  // ==========================================================================
  logic [31:0] rd;
  logic        ack;
  logic [7:0]  rbyte; logic tb_t;

  initial begin
    $dumpfile("sim/tb_i3c_target.vcd");
    $dumpvars(0, tb_i3c_target);

    // ---- reset ----
    rst_n = 1'b0; clkw(10); @(posedge clk); rst_n = 1'b1; clkw(10);

    $display("\n=== A. Avalon register sanity ===");
    avl_rd(R_PIDL, rd);  check(rd == TB_PIDV, $sformatf("PID_LOW == 0x12345678 (got 0x%08x)", rd));
    avl_rd(R_IDENT, rd); check(rd[7:0] == TB_BCR,  $sformatf("IDENT[7:0]==BCR 0x07 (got 0x%02x)", rd[7:0]));
    check(rd[15:8] == TB_DCR, $sformatf("IDENT[15:8]==DCR 0x00 (got 0x%02x)", rd[15:8]));
    avl_rd(R_CAPS, rd);  check(rd[7:0]==8'h00 && rd[15:8]==8'h02, $sformatf("GETCAPS b1=0x00 b2=0x02 (got 0x%08x)", rd));
    // CTRL write/read
    avl_wr(R_CTRL, 32'h0000_0003);                      // core_en + accept_en
    avl_rd(R_CTRL, rd); check(rd[1:0]==2'b11, $sformatf("CTRL core_en+accept_en (got 0x%02x)", rd[5:0]));
    // DYN_ADDR before any assignment
    avl_rd(R_DYN, rd); check(rd[7]==1'b0, "da_valid==0 before DAA");
    // TX FIFO push + level
    avl_rd(R_FIFO, rd); check(rd[15:8]==8'd0, "tx_level==0 initially");
    avl_wr(R_TX, 32'h0000_00AA);
    avl_rd(R_FIFO, rd); check(rd[15:8]==8'd1, $sformatf("tx_level==1 after push (got %0d)", rd[15:8]));
    avl_wr(R_CTRL, 32'h0000_0083);                      // flush_tx pulse (bit7) + keep core_en
    avl_rd(R_FIFO, rd); check(rd[15:8]==8'd0, "tx_level==0 after flush_tx");
    avl_wr(R_CTRL, 32'h0000_0003);                      // restore

    $display("\n=== B. I3C bus: broadcast 0x7E ACK (proof-of-life) ===");
    bus_start;
    send_byte_ack({7'h7E, 1'b0}, ack);                  // 7E + Write
    check(ack, "Target ACKs broadcast 0x7E+W");
    bus_stop;
    clkw(20);

    $display("\n=== C. ENTDAA dynamic address assignment ===");
    run_entdaa();

    $display("\n=== D. Private write / read (requires DA from C) ===");
    avl_rd(R_DYN, rd);
    if (rd[7]) run_private(rd[6:0]);
    else begin $display("  [SKIP] no DA assigned; private R/W skipped"); end

    $display("\n=== E. GETSTATUS CCC ===");
    avl_rd(R_DYN, rd);
    if (rd[7]) run_getstatus(rd[6:0]);
    else $display("  [SKIP] no DA; GETSTATUS skipped");

    $display("\n=== F. GETPID CCC (multi-byte response, FINDING-SIM-7) ===");
    avl_rd(R_DYN, rd);
    if (rd[7]) run_getpid(rd[6:0]);
    else $display("  [SKIP] no DA; GETPID skipped");

    $display("\n========================================");
    $display(" RESULT: %0d passed, %0d failed", pass, fail);
    $display("========================================");
    if (fail==0) $display("ALL TESTS PASSED"); else $display("SOME TESTS FAILED");
    $finish;
  end

  // ----- ENTDAA: 7E+W, code 0x07, Sr, 7E+R(ACK), 64b payload from target,
  //       then controller drives 7-bit DA + parity, target ACKs. ------------
  task automatic run_entdaa;
    logic a, b1; int i;
    logic [6:0] new_da; new_da = 7'h08;
    bus_start;
    send_byte_ack({7'h7E,1'b0}, a); check(a, "ENTDAA: 7E+W ACK");
    send_byte_tbit(8'h07);                              // ENTDAA broadcast code + T
    bus_rstart;
    send_byte_ack({7'h7E,1'b1}, a); check(a, "ENTDAA: 7E+R ACK (unassigned target)");
    // target drives its 64-bit {PID[47:0],BCR,DCR} payload continuously (no T-bits);
    // controller just clocks and reads 64 bits.
    for (i=0;i<64;i++) read_bit(b1);
    // controller drives the assigned-address byte {DA[6:0], PAR}, MSb first,
    // PAR = odd parity of DA[6:0] (dec_par_ok = rx[0]==~^rx[7:1]).
    for (i=6;i>=0;i--) drive_bit(new_da[i]);
    drive_bit(~(^new_da));                              // odd-parity bit
    read_bit(a); check(~a, "ENTDAA: target ACKs assigned DA");
    bus_stop; clkw(20);
    avl_rd(R_DYN, rd);
    check(rd[7] && rd[6:0]==new_da, $sformatf("DA latched = 0x%02x valid=%b", rd[6:0], rd[7]));
  endtask

  // ----- private write a byte to DA, read it back from RX FIFO via Avalon ---
  task automatic run_private(input [6:0] da);
    logic a;
    avl_wr(R_CTRL, 32'h0000_0043);   // flush_rx pulse (bit6) + keep core_en/accept_en
    avl_wr(R_CTRL, 32'h0000_0003);
    bus_start;
    send_byte_ack({da,1'b0}, a); check(a, "PrivWr: DA+W ACK");
    send_byte_tbit(8'h5C);                              // one data byte + T
    bus_stop; clkw(20);
    avl_rd(R_FIFO, rd);
    if (rd[7:0] != 0) begin
      avl_rd(R_RX, rd);
      check(rd[7:0]==8'h5C, $sformatf("PrivWr byte in RX FIFO = 0x%02x", rd[7:0]));
    end else check(1'b0, "PrivWr: RX FIFO empty (no byte captured)");
    // private read: app loads TX, controller reads
    avl_wr(R_TX, 32'h0000_0100 | 8'hC3);                // data 0xC3, last=1 (bit8)
    bus_start;
    send_byte_ack({da,1'b1}, a); check(a, "PrivRd: DA+R ACK");
    read_byte_tbit(rbyte, tb_t);
    check(rbyte==8'hC3, $sformatf("PrivRd byte from target = 0x%02x", rbyte));
    bus_stop; clkw(20);
  endtask

  // ----- GETSTATUS (Direct CCC 0x90): 7E+W, 0x90+T, Sr, DA+R, read 2 bytes --
  task automatic run_getstatus(input [6:0] da);
    logic a; logic [7:0] b0,b1; logic t;
    bus_start;
    send_byte_ack({7'h7E,1'b0}, a); check(a, "GETSTATUS: 7E+W ACK");
    send_byte_tbit(8'h90);                              // GETSTATUS code + T
    bus_rstart;
    send_byte_ack({da,1'b1}, a); check(a, "GETSTATUS: DA+R ACK");
    read_byte_tbit(b0, t); read_byte_tbit(b1, t);
    // GETSTATUS Format-1 high byte for an idle Target (no pending IRQ / errors) = 0x00.
    // Multi-byte streaming (the low byte and beyond) is verified decisively by the
    // GETPID test below (FINDING-SIM-7 fixed).
    check(b0==8'h00, $sformatf("GETSTATUS responds, status high byte=0x00 (got hi=0x%02x lo=0x%02x)", b0, b1));
    bus_stop; clkw(20);
  endtask

  // ----- GETPID (Direct CCC 0x8D): 7E+W, 0x8D+T, Sr, DA+R, read 6 PID bytes -----
  // Decisive multi-byte GET test (FINDING-SIM-7). PID = {MFG_ID, type, PID_VAL}, so the
  // six response bytes are pid[47:40], [39:32], ... [7:0] (here 05,4A,12,34,56,78 - all
  // distinct after byte0). Before the fix the response repeated/lagged bytes by one.
  task automatic run_getpid(input [6:0] da);
    logic a; logic [7:0] bb; logic t; int i;
    logic [47:0] pidv; logic [7:0] expb;
    pidv = {TB_MFG, 1'b0, TB_PIDV};
    bus_start;
    send_byte_ack({7'h7E,1'b0}, a); check(a, "GETPID: 7E+W ACK");
    send_byte_tbit(8'h8D);                              // GETPID code + T
    bus_rstart;
    send_byte_ack({da,1'b1}, a); check(a, "GETPID: DA+R ACK");
    for (i=0;i<6;i++) begin
      read_byte_tbit(bb, t);
      expb = pidv[47 - 8*i -: 8];
      check(bb==expb, $sformatf("GETPID byte%0d=0x%02x exp 0x%02x", i, bb, expb));
    end
    bus_stop; clkw(20);
  endtask

  // ---- debug probe ----------------------------------------------------------
  logic dbg_en = 1'b0;
  always @(posedge clk) if (rst_n && dbg_en) begin
    if (dut.fe_start_stb||dut.fe_rstart_stb||dut.fe_stop_stb||dut.be_byte_done||
        dut.pf_ack_oe||dut.sda_oe||dut.fe_scl_rising)
      $display("DBG t=%0t S=%b R=%b P=%b busy=%b sclr=%b cnt=%0d rxb=%02x bdone=%b m7e=%b mda=%b ackoe=%b acko=%b sda_oe=%b SDA=%b daa=%b",
        $time, dut.fe_start_stb, dut.fe_rstart_stb, dut.fe_stop_stb, dut.fe_bus_busy,
        dut.fe_scl_rising, dut.be_bit_cnt, dut.be_rx_byte, dut.be_byte_done,
        dut.pf_match_7e, dut.pf_match_da, dut.pf_ack_oe, dut.pf_ack_o, dut.sda_oe, SDA, dut.daa_active);
  end

  // ---- global timeout -------------------------------------------------------
  initial begin #2_000_000; $display("TIMEOUT"); $display(" RESULT: %0d passed, %0d failed", pass, fail); $finish; end

endmodule
