`ifdef VERILATOR
`include "include/common.sv"
`include "include/csr.sv"
`include "src/core.sv"
`include "util/IBusToCBus.sv"
`include "util/DBusToCBus.sv"
`include "util/CBusArbiter.sv"
`include "util/MMU.sv"
`include "util/SimMemoryWithVirtio.sv"

module SimTop import common::*;(
  input         clock,
  input         reset,
  input  [63:0] io_logCtrl_log_begin,
  input  [63:0] io_logCtrl_log_end,
  input  [63:0] io_logCtrl_log_level,
  input         io_perfInfo_clean,
  input         io_perfInfo_dump,
  output        io_uart_out_valid,
  output [7:0]  io_uart_out_ch,
  output        io_uart_in_valid,
  input  [7:0]  io_uart_in_ch
);

    /* verilator lint_off UNOPTFLAT */
    cbus_req_t  oreq, cpu_oreq;
    cbus_resp_t oresp, cpu_oresp;
    /* verilator lint_on UNOPTFLAT */
    logic trint, swint, exint;
    logic [1:0] priv_mode;
    word_t satp, mstatus;

    ibus_req_t  ireq;
    ibus_resp_t iresp;
    dbus_req_t  dreq;
    dbus_resp_t dresp;
    cbus_req_t  icreq,  dcreq;
    cbus_resp_t icresp, dcresp;

    core core(
      .clk(clock), .reset, .ireq, .iresp, .dreq, .dresp,
      .priv_mode(priv_mode), .satp(satp), .mstatus(mstatus),
      .trint, .swint, .exint
    );

    IBusToCBus icvt(.*);
    DBusToCBus dcvt(.*);
    CBusArbiter mux(
        .clk(clock), .reset,
        .ireqs({icreq, dcreq}),
        .iresps({icresp, dcresp}),
        .oreq(cpu_oreq),
        .oresp(cpu_oresp)
    );

    MMU mmu(
        .clk(clock), .reset,
        .priv_mode(priv_mode),
        .satp(satp),
        .mstatus(mstatus),
        .ireq(cpu_oreq),
        .iresp(cpu_oresp),
        .oreq(oreq),
        .oresp(oresp)
    );

    SimMemoryWithVirtio ram(
        .clk(clock), .reset, .oreq, .oresp, .trint, .swint, .exint
    );

    assign {io_uart_out_valid, io_uart_out_ch, io_uart_in_valid} = '0;

endmodule
`endif
