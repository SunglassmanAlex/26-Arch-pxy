module nexys4_top (
	input logic clk, btnC,
	input logic [3:0] sw,
	input logic RsRx,
	output logic [3:0] led,
	output logic RsTx
);
	soc_top soc_top_inst (
		.clk,
		.reset(btnC),
		.sw(sw),
		.led(led),
		.tx(RsTx)
	);
endmodule

// Backward-compatible wrapper so old project files that still use `basys3_top`
// can continue to build.
module basys3_top (
	input logic clk, btnC,
	input logic [3:0] sw,
	input logic RsRx,
	output logic [3:0] led,
	output logic RsTx
);
	nexys4_top u_nexys4_top(
		.clk(clk),
		.btnC(btnC),
		.sw(sw),
		.RsRx(RsRx),
		.led(led),
		.RsTx(RsTx)
	);
endmodule
