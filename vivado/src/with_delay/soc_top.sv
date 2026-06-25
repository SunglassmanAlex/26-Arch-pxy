`ifndef __ARCH_VIVADO_CPU_DEPS_SV
`define __ARCH_VIVADO_CPU_DEPS_SV
`include "../../../vsrc/include/config.sv"
`include "../../../vsrc/include/common.sv"
`include "../../../vsrc/include/csr.sv"
`include "../../../vsrc/src/core.sv"
`include "../../../vsrc/util/IBusToCBus.sv"
`include "../../../vsrc/util/DBusToCBus.sv"
`include "../../../vsrc/util/CBusArbiter.sv"
`include "../../../vsrc/util/MMU.sv"
`endif

module mycpu_top_single
	import common::*;
(
	input logic clk,
	input logic reset,

	output logic valid,
	output logic [63:0] addr,
	output logic [63:0] wdata,
	input logic [63:0] rdata,
	output logic [7:0] wstrobe,
	output logic [1:0] burst,
	output logic [7:0] len,
	output logic [2:0] size,

	input logic ready,
	input logic last
);
	cbus_req_t  oreq;
	cbus_resp_t oresp;
	cbus_req_t  cpu_oreq;
	cbus_resp_t cpu_oresp;
	logic trint, swint, exint;
	logic if_flush;
	logic [1:0] priv_mode;
	word_t satp, mstatus;

	ibus_req_t  ireq;
	ibus_resp_t iresp;
	dbus_req_t  dreq;
	dbus_resp_t dresp;
	cbus_req_t  icreq, dcreq;
	cbus_resp_t icresp, dcresp;

	assign trint = 1'b0;
	assign swint = 1'b0;
	assign exint = 1'b0;

	core core_inst(
		.clk(clk),
		.reset(reset),
		.ireq(ireq),
		.iresp(iresp),
		.if_flush(if_flush),
		.dreq(dreq),
		.dresp(dresp),
		.priv_mode(priv_mode),
		.satp(satp),
		.mstatus(mstatus),
		.trint(trint),
		.swint(swint),
		.exint(exint)
	);

	IBusToCBus icvt(
		.ireq(ireq),
		.iresp(iresp),
		.if_flush(if_flush),
		.clk(clk),
		.reset(reset),
		.icreq(icreq),
		.icresp(icresp)
	);

	DBusToCBus dcvt(
		.dreq(dreq),
		.dresp(dresp),
		.dcreq(dcreq),
		.dcresp(dcresp)
	);

	CBusArbiter mux(
		.clk(clk),
		.reset(reset),
		.ireqs({icreq, dcreq}),
		.iresps({icresp, dcresp}),
		.oreq(cpu_oreq),
		.oresp(cpu_oresp)
	);

	MMU mmu(
		.clk(clk),
		.reset(reset),
		.priv_mode(priv_mode),
		.satp(satp),
		.mstatus(mstatus),
		.ireq(cpu_oreq),
		.iresp(cpu_oresp),
		.oreq(oreq),
		.oresp(oresp)
	);

	assign valid = oreq.valid;
	assign addr = oreq.addr;
	assign wdata = oreq.data;
	assign wstrobe = oreq.strobe;
	assign burst = oreq.burst;
	assign len = oreq.len;
	assign size = oreq.size;

	assign oresp.data = rdata;
	assign oresp.paddr = oreq.addr;
	assign oresp.page_fault = 1'b0;
	assign oresp.ready = ready;
	assign oresp.last = last;
endmodule

module soc_top #(
	parameter logic SIMULATION = 1'b0
)(
	input logic clk, reset,

	output logic [3:0] led,
	input logic [3:0] sw,
	output logic tx
);
	logic valid;
	logic [63:0] addr;
	logic [63:0] wdata;
	logic [1:0] burst;
	logic [7:0] len;
	logic [7:0] wstrobe;
	logic [63:0] rdata;
	logic ready;
	logic last;
	logic [2:0] size;

	logic ram_valid;
	logic [63:0] ram_addr;
	logic [63:0] ram_wdata;
	logic [1:0] ram_burst;
	logic [7:0] ram_len;
	logic [7:0] ram_wstrobe;
	logic [63:0] ram_rdata;
	logic ram_ready;
	logic ram_last;

	logic device_valid;
	logic [63:0] device_addr;
	logic [63:0] device_wdata;
	logic device_wvalid;
	logic [63:0] device_rdata;
	logic device_ready;
	logic device_last;

	logic cpu_clk;
	logic clk_wiz_locked;
	logic soc_reset;
	logic [3:0] device_led;
	logic bus_seen;
	logic uart_seen;
	logic finish_seen;
	localparam int unsigned BOARD_UART_BIT_TMR_MAX = 2603;

	/* mycpu */
	mycpu_top_single mycpu_top_inst(
		.clk(cpu_clk),
		.reset(soc_reset),
		.valid(valid),
		.addr(addr),
		.wdata(wdata),
		.rdata(rdata),
		.wstrobe(wstrobe),
		.burst(burst),
		.len(len),
		.size(size),
		.ready(ready),
		.last(last)
	);


	/* CBus Crossbar */
	cbus_crossbar cbus_crossbar_inst(.*);

	/* RAM */
	bram_wrapper #(SIMULATION) bram_wrapper_inst(
		.clk(cpu_clk), .reset(soc_reset),
		.valid(ram_valid),
		.addr(ram_addr),
		.wdata(ram_wdata),
		.rdata(ram_rdata),
		.wstrobe(ram_wstrobe),
		.burst(ram_burst),
		.len(ram_len),
		.ready(ram_ready),
		.last(ram_last)
	);

	/* Device */
	device #(
		.SIMULATION(SIMULATION),
		.BIT_TMR_MAX_VALUE(BOARD_UART_BIT_TMR_MAX)
	) device_inst (
		.clk(cpu_clk),
		.reset(soc_reset),
		.cpu_clk(cpu_clk),
		.led(device_led),
		.sw(sw),
		.tx(tx),
		.valid(device_valid),
		.addr(device_addr),
		.wdata(device_wdata),
		.rdata(device_rdata),
		.wvalid(device_wvalid),
		.size({5'b0, size}),
		.ready(device_ready),
		.last(device_last)
	);

	if (SIMULATION) begin
		assign cpu_clk = clk;
		assign clk_wiz_locked = 1'b1;
	end else begin
		clk_wiz_0 clk_wiz_0(
			.sys_clk(clk),
			.reset(reset),
			.cpu_clk(cpu_clk),
			.locked(clk_wiz_locked)
		);
	end

	assign soc_reset = reset | ~clk_wiz_locked;

	always_ff @(posedge cpu_clk) begin
		if (soc_reset) begin
			bus_seen <= 1'b0;
			uart_seen <= 1'b0;
			finish_seen <= 1'b0;
		end else begin
			bus_seen <= bus_seen | valid;
			uart_seen <= uart_seen | (device_valid && device_wvalid && device_addr == 64'h4060_0004);
			finish_seen <= finish_seen | (device_valid && device_wvalid && device_addr == 64'h2333_3000);
		end
	end

	assign led = sw[3] ? {finish_seen | uart_seen, bus_seen, ~soc_reset, clk_wiz_locked} : device_led;
	

endmodule
