`include "device.svh"

module bram_0 (
	input wire clka,
	input wire ena,
	input wire [7:0] wea,
	input wire [14:0] addra,
	input wire [63:0] dina,
	output logic [63:0] douta
);
	logic [63:0] mem [0:32767];

	initial begin
		$readmemb("vivado/test-cpu/src/ip/bram_0/bram_0.mif", mem);
	end

	always_ff @(posedge clka) begin
		if (ena) begin
			douta <= mem[addra];
			for (int i = 0; i < 8; i++) begin
				if (wea[i]) mem[addra][8 * i +: 8] <= dina[8 * i +: 8];
			end
		end
	end
endmodule

module board_soc_trace_tb;
	logic clk;
	logic reset;
	logic [3:0] sw;
	logic [3:0] led;
	logic tx;

	soc_top #(.SIMULATION(1'b1)) dut (
		.clk(clk),
		.reset(reset),
		.led(led),
		.sw(sw),
		.tx(tx)
	);

	initial clk = 1'b0;
	always #5 clk = ~clk;

	int cycle;
	int printed_reqs;
	logic [3:0] last_led;

	initial begin
		$dumpfile("build/board-soc-trace/board_soc_trace_tb.fst");
		$dumpvars(0, board_soc_trace_tb);

		reset = 1'b1;
		sw = 4'b1000;
		last_led = 4'h0;
		printed_reqs = 0;
		repeat (20) @(posedge clk);
		reset = 1'b0;

		for (cycle = 0; cycle < 500000; cycle++) begin
			@(posedge clk);
			#1;

			if (led != last_led) begin
				$display("cycle=%0d led=%b valid=%0b instr=%0b addr=%016x ready=%0b last=%0b",
					cycle, led, dut.valid, dut.debug_is_instr, dut.addr, dut.ready, dut.last);
				last_led = led;
			end

			if (dut.valid && printed_reqs < 80) begin
				$display("cycle=%0d req[%0d] instr=%0b write=%0b addr=%016x wdata=%016x rdata=%016x ready=%0b last=%0b",
					cycle, printed_reqs, dut.debug_is_instr, |dut.wstrobe,
					dut.addr, dut.wdata, dut.rdata, dut.ready, dut.last);
				printed_reqs++;
			end

			if (dut.device_valid && dut.device_wvalid) begin
				$display("cycle=%0d device_write addr=%016x data=%016x strobe=%02x",
					cycle, dut.device_addr, dut.device_wdata, dut.wstrobe);
			end

			if (dut.uart_seen || dut.finish_seen) begin
				$display("board_soc_trace_hit_output cycle=%0d led=%b uart_seen=%0b finish_seen=%0b",
					cycle, led, dut.uart_seen, dut.finish_seen);
				repeat (20) @(posedge clk);
				$finish;
			end
		end

		$display("board_soc_trace_timeout cycle=%0d led=%b bus_seen=%0b uart_seen=%0b finish_seen=%0b",
			cycle, led, dut.bus_seen, dut.uart_seen, dut.finish_seen);
		$finish;
	end
endmodule
