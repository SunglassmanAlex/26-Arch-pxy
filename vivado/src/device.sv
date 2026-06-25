`include "device.svh"

module device #(
	parameter logic SIMULATION = 1'b0,
	parameter int unsigned BIT_TMR_MAX_VALUE = 10416
)(
	input logic clk, reset,
	input logic cpu_clk,

	/* From Board */
	output logic [3:0] led,
	input logic [3:0] sw,
	output logic tx,

	/* From CPU */
	input logic valid,
	input logic [63:0] addr,
	input logic wvalid,
	input logic [7:0] size,
	input logic [63:0] wdata,
	output logic [63:0] rdata,

	output logic ready,
	output logic last
);
	localparam int STR_LEN = 15;
	localparam logic [4:0] STR_LAST = 5'(STR_LEN - 1);
	localparam logic [STR_LEN-1:0][7:0] STR = {
		8'h48,8'h65,8'h6c,8'h6c,8'h6f,8'h20,
		8'h57,8'h6f,8'h72,8'h6c,8'h64,8'h21,8'h0d,8'h0a,8'h0
	};

	/* Counter */
	logic [63:0] cnter, cnter1;

	always_ff @(posedge clk) begin
		if (reset) {cnter, cnter1} <= '0;
		else begin
			cnter1 <= cnter1 + 1;
			if (cnter1 == 100) begin
				cnter1 <= '0;
				cnter <= cnter + 1;
			end
		end
	end

	/* Switch */
	logic [3:0] switch;
	logic tx_ready;
	always_ff @(posedge clk) begin
		switch <= sw;
	end

	always_comb begin
		rdata = '0;
		unique case(addr)
			SW_ADDR: begin
				unique case(switch)
					4'd0: rdata = 64'd31;
					4'd1: rdata = 64'd1;
					4'd2: rdata = 64'd2;
					4'd3: rdata = 64'd4;
					4'd4: rdata = 64'd8;
					4'd5: rdata = 64'd16;
					default: ;
				endcase
			end
			COUNTER_1, COUNTER_2: rdata = cnter;
			TX_READY: rdata = {{63{1'b0}}, tx_ready};
			default: ;
		endcase
	end

	always_ff @(posedge clk) begin
		if (reset) led <= '0;
		else if (valid && wvalid && (addr == FINISH_ADDR)) led <= '1;
	end

	assign last = ready;

	/* UART */
	localparam logic [13:0] BIT_TMR_MAX = 14'(BIT_TMR_MAX_VALUE);
	localparam logic [3:0] BIT_INDEX_MAX = 4'd10;

	logic finish;
	always_ff @(posedge clk) begin
		if (reset) finish <= '0;
		else if (valid && addr == FINISH_ADDR && wvalid) finish <= '1;
	end

	logic [13:0] bitTmr;

	localparam type state_t = enum logic [1:0] {
		RDY, LOAD_BIT, SEND_BIT
	};

	logic bitDone;
	logic [3:0] bitIndex;
	logic txBit;
	logic [9:0] txData;
	state_t txState;

	logic send;
	logic [7:0] char_data;
	logic tx_access;
	logic [4:0] idx;
	logic putchar;

	always_ff @(posedge clk) begin
		if (reset) putchar <= '1;
		else if (~valid) putchar <= '1;
		else if (addr == TX_DATA && valid && wvalid && txState != RDY) putchar <= '0;
	end

	assign send = (idx != 0 && finish) || (addr == TX_DATA && valid && wvalid);

	always_ff @(posedge clk) begin
		if (reset) idx <= STR_LAST;
		else if (send && finish && tx_ready) idx <= idx - 1;
	end

	assign char_data = finish ? STR[idx] : wdata[39:32];

	always_ff @(posedge clk) begin
		if (reset) txState <= RDY;
		else begin
			unique case(txState)
				RDY: if (send && putchar) txState <= LOAD_BIT;
				LOAD_BIT: txState <= SEND_BIT;
				SEND_BIT: begin
					if (bitDone) begin
						if (bitIndex == BIT_INDEX_MAX) txState <= RDY;
						else txState <= LOAD_BIT;
					end
				end
				default: txState <= RDY;
			endcase
		end
	end

	always_ff @(posedge clk) begin
		if (reset || txState == RDY || bitDone) bitTmr <= '0;
		else bitTmr <= bitTmr + 1;
	end

	assign bitDone = bitTmr == BIT_TMR_MAX;

	always_ff @(posedge clk) begin
		if (reset || txState == RDY) bitIndex <= '0;
		else if (txState == LOAD_BIT) bitIndex <= bitIndex + 1;
	end

	always_ff @(posedge clk) begin
		if (reset) txData <= 10'h3ff;
		else if (txState == RDY && send && putchar) txData <= {1'b1, char_data, 1'b0};
	end

	always_ff @(posedge clk) begin
		if (reset) txBit <= '1;
		else if (txState == RDY) txBit <= '1;
		else if (txState == LOAD_BIT) txBit <= txData[bitIndex];
	end

	assign tx = txBit;
	assign tx_ready = txState == RDY;
	assign tx_access = valid && wvalid && (addr == TX_DATA);
	if (SIMULATION)
		assign ready = '1;
	else
		assign ready = tx_access ? tx_ready : 1'b1;

	always_ff @(posedge clk) begin
		if (~reset && valid && wvalid) begin
			if (addr == TX_DATA) begin
				$write("%c", char_data);
			end else if (addr == FINISH_ADDR) begin
				$write("Hello World!\n");
			end
		end
	end

endmodule
