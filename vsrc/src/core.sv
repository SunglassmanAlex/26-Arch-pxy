`ifndef __CORE_SV
`define __CORE_SV

`ifdef VERILATOR
`include "include/common.sv"
`endif

module core import common::*;(
	input  logic       clk, reset,
	output ibus_req_t  ireq,
	input  ibus_resp_t iresp,
	output dbus_req_t  dreq,
	input  dbus_resp_t dresp,
	input  logic       trint, swint, exint
);

	addr_t pc, if_req_addr, if_id_pc;
	logic  if_pending, if_id_valid;
	u32    if_id_instr;
	logic  id_consume;
	
	assign ireq.valid = if_pending;
	assign ireq.addr  = if_req_addr;
	assign dreq = '0;

	always_ff @(posedge clk) begin 
		if (reset) begin
			pc <= PCINIT;
			if_pending <= 1'b0;
			if_req_addr <= '0;
			if_id_valid <= 1'b0;
			if_id_pc <= '0;
			if_id_instr <= '0;
		end
		else begin
			if (!if_pending && !if_id_valid) begin
				if_pending <= 1'b1;
				if_req_addr <= pc;
			end
			if (if_pending && iresp.data_ok) begin
				if_id_valid <= 1'b1;
				if_id_pc <= if_req_addr;
				if_id_instr <= iresp.data;
				pc <= if_req_addr + 64'd4;
				if_pending <= 1'b0;
			end
			if (if_id_valid && id_consume) begin
				if_id_valid <= 1'b0;
			end
		end
	end

	word_t gpr[31:0];
	logic [4:0] rs1, rs2, rd;
	logic [6:0] opc, fun7;
	logic [2:0] fun3;
	word_t imm_i;

	assign opc   = if_id_instr[6:0];
	assign rd    = if_id_instr[11:7];
	assign fun3  = if_id_instr[14:12];
	assign rs1   = if_id_instr[19:15];
	assign rs2   = if_id_instr[24:20];
	assign fun7  = if_id_instr[31:25];
	assign imm_i = {{52{if_id_instr[31]}}, if_id_instr[31:20]};

	word_t rs1_val, rs2_val;
	assign rs1_val = (rs1 == 5'd0) ? 64'd0 : gpr[rs1];
	assign rs2_val = (rs2 == 5'd0) ? 64'd0 : gpr[rs2];

	always_ff @(posedge clk) begin
		if (reset) begin
			for (int i = 0; i < 32; i += 1) gpr[i] <= '0;
		end
		else begin
			if (wb_valid && wb_wen && wb_rd != 5'd0) begin
				gpr[wb_rd] <= wb_data;
			end
		end
		gpr[0] <= '0;
	end

	function automatic word_t sext32(input logic [31:0] x);
		sext32 = {{32{x[31]}}, x};
	endfunction

	logic id_wen, id_use_imm, id_is_word, id_valid;
	logic id_is_md;
	logic [2:0] id_alu_op;
	logic [3:0] id_md_op;
	word_t ex_op1, ex_op2, ex_res, ex_res_raw;

	localparam logic [2:0] ALU_ADD = 3'D0;
	localparam logic [2:0] ALU_SUB = 3'D1;
	localparam logic [2:0] ALU_AND = 3'D2;
	localparam logic [2:0] ALU_OR = 3'D3;
	localparam logic [2:0] ALU_XOR = 3'D4;

	// M extension op select
	localparam logic [3:0] MD_NONE  = 4'd0;
	localparam logic [3:0] MD_MUL   = 4'd1;
	localparam logic [3:0] MD_DIV   = 4'd2;
	localparam logic [3:0] MD_DIVU  = 4'd3;
	localparam logic [3:0] MD_REM   = 4'd4;
	localparam logic [3:0] MD_REMU  = 4'd5;
	localparam logic [3:0] MD_MULW  = 4'd6;
	localparam logic [3:0] MD_DIVW  = 4'd7;
	localparam logic [3:0] MD_DIVUW = 4'd8;
	localparam logic [3:0] MD_REMW  = 4'd9;
	localparam logic [3:0] MD_REMUW = 4'd10;

	always_comb begin
		id_valid = if_id_valid;
		id_wen = 1'b0;
		id_use_imm = 1'b0;
		id_is_word = 1'b0;
		id_is_md = 1'b0;
		id_alu_op = ALU_ADD;
		id_md_op = MD_NONE;

		unique case (opc)
			7'b0010011: begin
				id_wen = 1'b1;
				id_use_imm = 1'b1;
				unique case (fun3)
					3'b000: id_alu_op = ALU_ADD;
					3'b100: id_alu_op = ALU_XOR;
					3'b110: id_alu_op = ALU_OR;
					3'b111: id_alu_op = ALU_AND;
					default: id_wen = 1'b0;
				endcase
			end

			7'b0110011: begin
				if (fun7 == 7'b0000001) begin
					id_wen = 1'b1;
					id_is_md = 1'b1;
					unique case (fun3)
						3'b000: id_md_op = MD_MUL;
						3'b100: id_md_op = MD_DIV;
						3'b101: id_md_op = MD_DIVU;
						3'b110: id_md_op = MD_REM;
						3'b111: id_md_op = MD_REMU;
						default: id_wen = 1'b0;
					endcase
				end
				else begin
					id_wen = 1'b1;
						case ({fun7, fun3})
							{7'b0000000,3'b000}: id_alu_op = ALU_ADD;
							{7'b0100000,3'b000}: id_alu_op = ALU_SUB;
							{7'b0000000,3'b111}: id_alu_op = ALU_AND;
							{7'b0000000,3'b110}: id_alu_op = ALU_OR;
							{7'b0000000,3'b100}: id_alu_op = ALU_XOR;
							default: id_wen = 1'b0;
						endcase
				end
			end

			7'b0111011: begin
				if (fun7 == 7'b0000001) begin
					id_wen = 1'b1;
					id_is_md = 1'b1;
					unique case (fun3)
						3'b000: id_md_op = MD_MULW;
						3'b100: id_md_op = MD_DIVW;
						3'b101: id_md_op = MD_DIVUW;
						3'b110: id_md_op = MD_REMW;
						3'b111: id_md_op = MD_REMUW;
						default: id_wen = 1'b0;
					endcase
				end
				else begin
					id_wen = 1'b1;
					id_is_word = 1'b1;
						case ({fun7, fun3})
							{7'b0000000,3'b000}: id_alu_op = ALU_ADD;
							{7'b0100000,3'b000}: id_alu_op = ALU_SUB;
							default: id_wen = 1'b0;
						endcase
				end
			end

			7'b0011011: begin
				if (fun3 == 3'b000) begin
					id_wen = 1'b1;
					id_use_imm = 1'b1;
					id_is_word = 1'b1;
					id_alu_op = ALU_ADD;
				end
			end

			default: begin
			end

		endcase
	end

	assign ex_op1 = rs1_val;
	assign ex_op2 = id_use_imm ? imm_i : rs2_val;
	
	always_comb begin
		unique case (id_alu_op)
			ALU_ADD: ex_res_raw = ex_op1 + ex_op2;
			ALU_SUB: ex_res_raw = ex_op1 - ex_op2;
			ALU_AND: ex_res_raw = ex_op1 & ex_op2;
			ALU_OR: ex_res_raw = ex_op1 | ex_op2;
			ALU_XOR: ex_res_raw = ex_op1 ^ ex_op2;
			default: ex_res_raw = '0;
		endcase
	end

	function automatic word_t mul_u64(input word_t a, input word_t b);
		word_t acc, mcand, mplier;
		acc = '0;
		mcand = a;
		mplier = b;
		for (int i = 0; i < 64; i += 1) begin
			if (mplier[0]) acc = acc + mcand;
			mcand = mcand << 1;
			mplier = {1'b0, mplier[63:1]};
		end
		mul_u64 = acc;
	endfunction

	function automatic logic [127:0] udivrem64(input word_t dividend, input word_t divisor);
		logic [64:0] rem;
		word_t quot;
		rem = '0;
		quot = dividend;
		for (int i = 0; i < 64; i += 1) begin
			rem = {rem[63:0], quot[63]};
			quot = {quot[62:0], 1'b0};
			if (rem >= {1'b0, divisor}) begin
				rem = rem - {1'b0, divisor};
				quot[0] = 1'b1;
			end
		end
		udivrem64 = {rem[63:0], quot};
	endfunction

	word_t md_res;

	always_comb begin
		logic a_neg64, b_neg64, a_neg32, b_neg32;
		word_t a_abs64, b_abs64;
		logic [31:0] a_abs32, b_abs32;
		logic [31:0] a32, b32;
		logic [127:0] divpack;
		word_t q_u, r_u, mul_raw;
		logic [31:0] res32;

		a_neg64 = ex_op1[63];
		b_neg64 = ex_op2[63];
		a_abs64 = a_neg64 ? (~ex_op1 + 64'd1) : ex_op1;
		b_abs64 = b_neg64 ? (~ex_op2 + 64'd1) : ex_op2;

		a32 = ex_op1[31:0];
		b32 = ex_op2[31:0];
		a_neg32 = a32[31];
		b_neg32 = b32[31];
		a_abs32 = a_neg32 ? (~a32 + 32'd1) : a32;
		b_abs32 = b_neg32 ? (~b32 + 32'd1) : b32;

		md_res = '0;
		divpack = '0;
		q_u = '0;
		r_u = '0;
		mul_raw = '0;
		res32 = 32'd0;

		case (id_md_op)
			MD_MUL: begin
				mul_raw = mul_u64(a_abs64, b_abs64);
				md_res = (a_neg64 ^ b_neg64) ? (~mul_raw + 64'd1) : mul_raw;
			end
			MD_MULW: begin
				mul_raw = mul_u64({32'd0, a_abs32}, {32'd0, b_abs32});
				res32 = mul_raw[31:0];
				if (a_neg32 ^ b_neg32) res32 = ~res32 + 32'd1;
				md_res = sext32(res32);
			end
			MD_DIV: begin
				if (ex_op2 == 64'd0) md_res = 64'hffff_ffff_ffff_ffff;
				else if ((ex_op1 == 64'h8000_0000_0000_0000) && (ex_op2 == 64'hffff_ffff_ffff_ffff)) md_res = 64'h8000_0000_0000_0000;
				else begin
					divpack = udivrem64(a_abs64, b_abs64);
					q_u = divpack[63:0];
					md_res = (a_neg64 ^ b_neg64) ? (~q_u + 64'd1) : q_u;
				end
			end
			MD_DIVU: begin
				if (ex_op2 == 64'd0) md_res = 64'hffff_ffff_ffff_ffff;
				else begin
					divpack = udivrem64(ex_op1, ex_op2);
					md_res = divpack[63:0];
				end
			end
			MD_REM: begin
				if (ex_op2 == 64'd0) md_res = ex_op1;
				else if ((ex_op1 == 64'h8000_0000_0000_0000) && (ex_op2 == 64'hffff_ffff_ffff_ffff)) md_res = 64'd0;
				else begin
					divpack = udivrem64(a_abs64, b_abs64);
					r_u = divpack[127:64];
					md_res = a_neg64 ? (~r_u + 64'd1) : r_u;
				end
			end
			MD_REMU: begin
				if (ex_op2 == 64'd0) md_res = ex_op1;
				else begin
					divpack = udivrem64(ex_op1, ex_op2);
					md_res = divpack[127:64];
				end
			end
			MD_DIVW: begin
				if (b32 == 32'd0) md_res = 64'hffff_ffff_ffff_ffff;
				else if ((a32 == 32'h8000_0000) && (b32 == 32'hffff_ffff)) md_res = sext32(32'h8000_0000);
				else begin
					divpack = udivrem64({32'd0, a_abs32}, {32'd0, b_abs32});
					res32 = divpack[31:0];
					if (a_neg32 ^ b_neg32) res32 = ~res32 + 32'd1;
					md_res = sext32(res32);
				end
			end
			MD_DIVUW: begin
				if (b32 == 32'd0) md_res = 64'hffff_ffff_ffff_ffff;
				else begin
					divpack = udivrem64({32'd0, a32}, {32'd0, b32});
					md_res = sext32(divpack[31:0]);
				end
			end
			MD_REMW: begin
				if (b32 == 32'd0) md_res = sext32(a32);
				else if ((a32 == 32'h8000_0000) && (b32 == 32'hffff_ffff)) md_res = 64'd0;
				else begin
					divpack = udivrem64({32'd0, a_abs32}, {32'd0, b_abs32});
					res32 = divpack[95:64];
					if (a_neg32) res32 = ~res32 + 32'd1;
					md_res = sext32(res32);
				end
			end
			MD_REMUW: begin
				if (b32 == 32'd0) md_res = sext32(a32);
				else begin
					divpack = udivrem64({32'd0, a32}, {32'd0, b32});
					md_res = sext32(divpack[95:64]);
				end
			end
			default: begin
				md_res = '0;
			end
		endcase
	end

	assign ex_res = id_is_md ? md_res : (id_is_word ? {{32{ex_res_raw[31]}}, ex_res_raw[31:0]} : ex_res_raw);
	assign id_consume = id_valid;
		
	// EX -> WB
	logic ex_wb_valid, ex_wb_wen;
	logic [4:0] ex_wb_rd;
	word_t ex_wb_data;
	addr_t ex_wb_pc;
	u32 ex_wb_instr;

	// ID/EX -> WB
	always_ff @(posedge clk) begin
		if (reset) begin
			ex_wb_valid <= 1'b0;
			ex_wb_wen   <= 1'b0;
			ex_wb_rd    <= '0;
			ex_wb_data  <= '0;
			ex_wb_pc    <= '0;
			ex_wb_instr <= '0;
		end
		else begin
			ex_wb_valid <= id_valid;
			ex_wb_wen   <= id_valid ? id_wen : 1'b0;
			ex_wb_rd    <= rd;
			ex_wb_data  <= ex_res;
			ex_wb_pc    <= if_id_pc;
			ex_wb_instr <= if_id_instr;
		end
	end

	logic wb_valid, wb_wen;
	logic [4:0] wb_rd;
	word_t wb_data;
	addr_t wb_pc;
	u32 wb_instr;

	assign wb_valid = ex_wb_valid;
	assign wb_wen = ex_wb_wen;
	assign wb_rd = ex_wb_rd;
	assign wb_data = ex_wb_data;
	assign wb_instr = ex_wb_instr;
	assign wb_pc = ex_wb_pc;

	// next step for difftest

	logic dt_valid, dt_wen;
	addr_t dt_pc;
	u32 dt_instr;
	logic [7:0] dt_wdest;
	word_t dt_wdata;

	always_ff @(posedge clk) begin
		if (reset) begin
			dt_valid <= 1'b0;
			dt_wen   <= 1'b0;
			dt_pc    <= '0;
			dt_instr <= '0;
			dt_wdest <= '0;
			dt_wdata <= '0;
		end
		else begin
			dt_valid <= wb_valid;
			dt_pc    <= wb_pc;
			dt_instr <= wb_instr;
			dt_wen   <= wb_wen && (wb_rd != 5'd0);
			dt_wdest <= {3'b0, wb_rd};
			dt_wdata <= wb_data;
		end
	end

	logic trap_valid;
	logic [2:0] trap_code;
	word_t cyc_cnt, instr_cnt;

	assign trap_valid = dt_valid && (dt_instr == 32'h0005006b);
	assign trap_code = gpr[10][2:0];

	always_ff @(posedge clk) begin
		if (reset) begin
			cyc_cnt <= '0;
			instr_cnt <= '0;
		end
		else begin
			cyc_cnt <= cyc_cnt + 64'd1;
			if (dt_valid) begin
				instr_cnt <= instr_cnt + 64'd1;
			end
		end
	end


`ifdef VERILATOR
	DifftestInstrCommit DifftestInstrCommit(
		.clock              (clk),
		.coreid             (0),
		.index              (0),
		.valid              (dt_valid),
		.pc                 (dt_pc),
		.instr              (dt_instr),
		.skip               (0),
		.isRVC              (0),
		.scFailed           (0),
		.wen                (dt_wen),
		.wdest              (dt_wdest),
		.wdata              (dt_wdata)
	);

	DifftestArchIntRegState DifftestArchIntRegState (
		.clock              (clk),
		.coreid             (0),
		.gpr_0              (gpr[0]),
		.gpr_1              (gpr[1]),
		.gpr_2              (gpr[2]),
		.gpr_3              (gpr[3]),
		.gpr_4              (gpr[4]),
		.gpr_5              (gpr[5]),
		.gpr_6              (gpr[6]),
		.gpr_7              (gpr[7]),
		.gpr_8              (gpr[8]),
		.gpr_9              (gpr[9]),
		.gpr_10             (gpr[10]),
		.gpr_11             (gpr[11]),
		.gpr_12             (gpr[12]),
		.gpr_13             (gpr[13]),
		.gpr_14             (gpr[14]),
		.gpr_15             (gpr[15]),
		.gpr_16             (gpr[16]),
		.gpr_17             (gpr[17]),
		.gpr_18             (gpr[18]),
		.gpr_19             (gpr[19]),
		.gpr_20             (gpr[20]),
		.gpr_21             (gpr[21]),
		.gpr_22             (gpr[22]),
		.gpr_23             (gpr[23]),
		.gpr_24             (gpr[24]),
		.gpr_25             (gpr[25]),
		.gpr_26             (gpr[26]),
		.gpr_27             (gpr[27]),
		.gpr_28             (gpr[28]),
		.gpr_29             (gpr[29]),
		.gpr_30             (gpr[30]),
		.gpr_31             (gpr[31])
	);

    DifftestTrapEvent DifftestTrapEvent(
		.clock              (clk),
		.coreid             (0),
		.valid              (trap_valid),
		.code               (trap_code),
		.pc                 (dt_pc),
		.cycleCnt           (cyc_cnt),
		.instrCnt           (instr_cnt)
	);

	DifftestCSRState DifftestCSRState(
		.clock              (clk),
		.coreid             (0),
		.priviledgeMode     (3),
		.mstatus            (0),
		.sstatus            (0),
		.mepc               (0),
		.sepc               (0),
		.mtval              (0),
		.stval              (0),
		.mtvec              (0),
		.stvec              (0),
		.mcause             (0),
		.scause             (0),
		.satp               (0),
		.mip                (0),
		.mie                (0),
		.mscratch           (0),
		.sscratch           (0),
		.mideleg            (0),
		.medeleg            (0)
	);
`endif
endmodule
`endif
