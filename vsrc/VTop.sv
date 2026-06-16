`ifndef __VTOP_SV
`define __VTOP_SV

`ifdef VERILATOR
`include "include/common.sv"
`include "include/csr.sv"
`include "src/core.sv"
`include "util/IBusToCBus.sv"
`include "util/DBusToCBus.sv"
`include "util/CBusArbiter.sv"
`include "util/MMU.sv"

`endif
module VTop 
	import common::*;(
	input logic clk, reset,

	output cbus_req_t  oreq,
	input  cbus_resp_t oresp,
	input logic trint, swint, exint
);

    ibus_req_t  ireq;
    ibus_resp_t iresp;
    dbus_req_t  dreq;
    dbus_resp_t dresp;
    cbus_req_t  icreq,  dcreq;
    cbus_resp_t icresp, dcresp;
    cbus_req_t  cpu_oreq;
    cbus_resp_t cpu_oresp;
    logic [1:0] priv_mode;
    word_t satp;

    core core(.*);
    IBusToCBus icvt(.*);

    DBusToCBus dcvt(.*);


    CBusArbiter mux(
        .ireqs({icreq, dcreq}),
        .iresps({icresp, dcresp}),
        .oreq(cpu_oreq),
        .oresp(cpu_oresp),
        .clk(clk),
        .reset(reset)
    );

    MMU mmu(
        .clk(clk),
        .reset(reset),
        .priv_mode(priv_mode),
        .satp(satp),
        .ireq(cpu_oreq),
        .iresp(cpu_oresp),
        .oreq(oreq),
        .oresp(oresp)
    );

	always_ff @(posedge clk) begin
		if (~reset) begin
			// $display("icreq %x, %x", icreq.valid, icreq.addr);
			// if (oreq.valid || dcreq.addr == 64'h40600004) $display("dcreq %x, %x, oreq %x, %x, dcresp %x", dcreq.addr, dcreq.valid, oreq.valid, oreq.addr, dcresp.ready);
		end
	end
	

endmodule



`endif
