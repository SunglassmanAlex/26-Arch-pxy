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
	/* TODO: Add your CPU-Core here. */

	addr_t pc, if_req_addr, if_id_pc;
	logic  if_pending, if_id_valid;
	u32    if_id_instr;
	
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
			if (if_id_valid) begin
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

	logic id_wen, id_use_imm, id_is_word, id_valid;
	logic [2:0] id_alu_op;
	word_t ex_op1, ex_op2, ex_res, ex_res_raw;

	localparam logic [2:0] ALU_ADD = 3'D0;
	localparam logic [2:0] ALU_SUB = 3'D1;
	localparam logic [2:0] ALU_AND = 3'D2;
	localparam logic [2:0] ALU_OR = 3'D3;
	localparam logic [2:0] ALU_XOR = 3'D4;

	always_comb begin
		id_valid = if_id_valid;
		id_wen = 1'b0;
		id_use_imm = 1'b0;
		id_is_word = 1'b0;
		id_alu_op = ALU_ADD;

		unique case (opc)
			7'b0010011: begin // addi, xori, ori, andi
				id_wen = 1'b1;
				id_use_imm = 1'b1;
				unique case (fun3)
					3'b000: id_alu_op = ALU_ADD; // addi
					3'b100: id_alu_op = ALU_XOR; // xori
					3'b110: id_alu_op = ALU_OR; // ori
					3'b111: id_alu_op = ALU_AND; // andi
					default: id_wen = 1'b0;
				endcase
			end

			7'b0110011: begin // add, sub, and, or, xor
				id_wen = 1;
				unique case ({fun7, fun3})
					{7'b0000000,3'b000}: id_alu_op = ALU_ADD; // add
					{7'b0100000,3'b000}: id_alu_op = ALU_SUB; // sub
					{7'b0000000,3'b111}: id_alu_op = ALU_AND; // and
					{7'b0000000,3'b110}: id_alu_op = ALU_OR;  // or
					{7'b0000000,3'b100}: id_alu_op = ALU_XOR; // xor
					default: id_wen = 1'b0;
				endcase
			end

			7'b0111011: begin // addw, subw
				id_wen = 1'b1;
				id_is_word = 1'b1;
				unique case ({fun7, fun3})
					{7'b0000000,3'b000}: id_alu_op = ALU_ADD; // addw
					{7'b0100000,3'b000}: id_alu_op = ALU_SUB; // subw
					default: id_wen = 1'b0;
				endcase
			end

			7'b0011011: begin // addiw
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

	assign ex_res = id_is_word ? {{32{ex_res_raw[31]}}, ex_res_raw[31:0]} : ex_res_raw;
	
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
			ex_wb_wen   <= id_wen;
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
		.sstatus            (0 /* mstatus & 64'h800000030001e000 */),
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