// prim_ram_1r1w — simple-dual-port RAM, 1 write + 1 read port (vendored fpgapa-prim primitive).
//
// What it is: one synchronous write port and one synchronous read port on a shared clock,
// 1-cycle read latency (`rd_data` valid the cycle after `rd_en` samples `rd_addr`), inferred
// block RAM. This is the ONLY memory-inference module in the design (tracker rule 2).
//
// Contract / POLICY (load-bearing — asserted executable in sim/tb_prim_ram.sv):
//   * Read-during-write returns OLD DATA: when `wr_en && rd_en && wr_addr == rd_addr` in the
//     same cycle, `rd_data` delivers the PRE-write content of that location. Every consumer
//     in fpga-scope (capture buffer, FIFOs) assumes this policy.
//   * `rd_data` holds its last value while `rd_en` is low.
//   * The array has no reset and no initial value; contents before first write are undefined.
//
// Policy decisions: plain always_ff array, separate write and read processes, no bypass
// logic, no reset on the array — written this way so Verilator simulates it and Quartus,
// Vivado, and Yosys all infer block RAM from the same source. No vendor primitives.
module prim_ram_1r1w #(
    parameter int unsigned WIDTH      = 8,
    parameter int unsigned DEPTH_LOG2 = 8
) (
    input  logic                  clk,
    input  logic                  wr_en,
    input  logic [DEPTH_LOG2-1:0] wr_addr,
    input  logic [WIDTH-1:0]      wr_data,
    input  logic                  rd_en,
    input  logic [DEPTH_LOG2-1:0] rd_addr,
    output logic [WIDTH-1:0]      rd_data
);

  localparam int unsigned DEPTH = 1 << DEPTH_LOG2;

  logic [WIDTH-1:0] mem[DEPTH];

  always_ff @(posedge clk) begin
    if (wr_en) mem[wr_addr] <= wr_data;
  end

  // Separate read process; nonblocking write above guarantees the "old data" policy in
  // simulation, and the separate-process shape is what all four target flows map to a
  // block-RAM read port.
  always_ff @(posedge clk) begin
    if (rd_en) rd_data <= mem[rd_addr];
  end

endmodule
