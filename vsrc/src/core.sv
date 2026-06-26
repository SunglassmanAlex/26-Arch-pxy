`ifndef __CORE_SV
`define __CORE_SV

`ifdef VERILATOR
`include "include/common.sv"
`endif

module core import common::*;(
	input  logic       clk, reset,
	output ibus_req_t  ireq,
	input  ibus_resp_t iresp,
	output logic       if_flush,
	output dbus_req_t  dreq,
	input  dbus_resp_t dresp,
	output logic [1:0] priv_mode,
	output word_t      satp,
	output word_t      mstatus,
	input  logic       trint, swint, exint
);
	import csr_pkg::*;

	localparam logic [1:0] PRIV_U = 2'b00;
	localparam logic [1:0] PRIV_S = 2'b01;
	localparam logic [1:0] PRIV_M = 2'b11;
	localparam word_t MSTATUS_SIE_BIT  = 64'h0000_0000_0000_0002;
	localparam word_t MSTATUS_MIE_BIT  = 64'h0000_0000_0000_0008;
	localparam word_t MSTATUS_SPIE_BIT = 64'h0000_0000_0000_0020;
	localparam word_t MSTATUS_MPIE_BIT = 64'h0000_0000_0000_0080;
	localparam word_t MSTATUS_SPP_BIT  = 64'h0000_0000_0000_0100;
	localparam word_t MSTATUS_MPP_MASK = 64'h0000_0000_0000_1800;
	localparam word_t MSTATUS_XS_MASK  = 64'h0000_0000_0001_8000;
	localparam word_t MSTATUS_MPRV_BIT = 64'h0000_0000_0002_0000;
	localparam word_t MIP_SSIP_BIT     = 64'h0000_0000_0000_0002;
	localparam word_t MIP_MSIP_BIT     = 64'h0000_0000_0000_0008;
	localparam word_t MIP_STIP_BIT     = 64'h0000_0000_0000_0020;
	localparam word_t MIP_MTIP_BIT     = 64'h0000_0000_0000_0080;
	localparam word_t MIP_SEIP_BIT     = 64'h0000_0000_0000_0200;
	localparam word_t MIP_MEIP_BIT     = 64'h0000_0000_0000_0800;
	localparam word_t MIP_S_MASK       = MIP_SSIP_BIT | MIP_STIP_BIT | MIP_SEIP_BIT;
	localparam word_t MIP_HW_MASK      = MIP_MSIP_BIT | MIP_MTIP_BIT | MIP_MEIP_BIT;
	localparam word_t COUNTEREN_MASK   = 64'h0000_0000_0000_0007;
	localparam int PMP_ENTRIES = 8;
	localparam int BP_ENTRIES = 32;
	localparam int BP_INDEX_BITS = 5;

	addr_t pc, if_req_addr, if_id_pc;
	logic  if_pending, if_id_valid, if_can_request;
	u32    if_id_instr;
	logic  if_id_access_fault, if_id_page_fault;
	addr_t if_id_fault_tval;
	logic  if_id_pred_taken;
	addr_t if_id_pred_target;
	logic  if_buf_valid;
	addr_t if_buf_pc;
	u32    if_buf_instr;
	logic  if_buf_access_fault, if_buf_page_fault;
	addr_t if_buf_fault_tval;
	logic  if_buf_pred_taken;
	addr_t if_buf_pred_target;
	logic  if_pred_req_valid;
	addr_t if_pred_req_addr;
	logic  if_kill_pending;
	logic  id_consume;
	logic  id_redirect;
	logic  id_fast_redirect;
	addr_t id_redirect_target;

	word_t gpr[31:0];
	logic [4:0] rs1, rs2, rd;
	logic [6:0] opc, fun7;
	logic [2:0] fun3;
	word_t imm_i, imm_s, imm_u, imm_b, imm_j;

	logic  mem_pending, mem_is_load, mem_is_store, mem_wen;
	logic  mem_is_atomic, mem_atomic_write_phase, mem_atomic_is_lr, mem_atomic_is_sc;
	logic [4:0] mem_rd;
	addr_t mem_pc, mem_addr;
	u32    mem_instr;
	msize_t mem_size;
	strobe_t mem_strobe;
	word_t mem_wdata;
	logic [7:0] mem_load_optype;
	logic [4:0] mem_amo_op;
	word_t mem_atomic_wb_data, mem_atomic_src_data;
	logic [1:0] mem_priv;
	logic reservation_valid;
	addr_t reservation_addr;

	word_t csr_mstatus, csr_mtvec, csr_mip, csr_mie, csr_mscratch;
	word_t csr_mcause, csr_mtval, csr_mepc, csr_mcycle, csr_minstret, csr_satp;
	word_t csr_stvec, csr_sscratch, csr_sepc, csr_scause, csr_stval;
	word_t csr_medeleg, csr_mideleg, csr_pmpcfg0;
	word_t csr_mcounteren, csr_scounteren;
	word_t csr_pmpaddr[PMP_ENTRIES];
	word_t csr_mhartid;
	word_t mip_value;
	logic [1:0] current_priv, fetch_priv;
	logic bp_valid[BP_ENTRIES];
	logic [1:0] bp_counter[BP_ENTRIES];

	assign priv_mode = current_priv;
	assign satp = csr_satp;
	assign mstatus = csr_mstatus;
	assign mip_value = (csr_mip & ~MIP_HW_MASK) |
		(swint ? MIP_MSIP_BIT : 64'd0) |
		(trint ? MIP_MTIP_BIT : 64'd0) |
		(exint ? MIP_MEIP_BIT : 64'd0) |
		((swint && csr_mideleg[1]) ? MIP_SSIP_BIT : 64'd0) |
		((trint && csr_mideleg[5]) ? MIP_STIP_BIT : 64'd0) |
		((exint && csr_mideleg[9]) ? MIP_SEIP_BIT : 64'd0);

	assign ireq.valid = if_pending;
	assign ireq.addr  = if_req_addr;

	assign dreq.valid  = mem_pending;
	assign dreq.addr   = mem_addr;
	assign dreq.size   = mem_size;
	assign dreq.strobe = mem_strobe;
	assign dreq.data   = mem_wdata;

	function automatic word_t fetch_branch_imm(input u32 instr);
		fetch_branch_imm = {{51{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};
	endfunction

	function automatic logic fetch_is_branch(input u32 instr);
		fetch_is_branch = (instr[6:0] == 7'b1100011) &&
			((instr[14:12] == 3'b000) || (instr[14:12] == 3'b001) ||
			 (instr[14:12] == 3'b100) || (instr[14:12] == 3'b101) ||
			 (instr[14:12] == 3'b110) || (instr[14:12] == 3'b111));
	endfunction

	u32    if_resp_instr;
	word_t if_resp_branch_imm;
	addr_t if_resp_pred_target;
	logic  if_resp_pred_taken;
	logic  if_resp_to_id;
	logic [BP_INDEX_BITS-1:0] if_resp_bp_index;
	logic  if_resp_is_branch;
	logic  if_resp_bht_taken;
	logic  if_resp_bp_decision;

	assign if_resp_instr = iresp.page_fault ? 32'h0000_0013 : iresp.data;
	assign if_resp_branch_imm = fetch_branch_imm(iresp.data);
	assign if_resp_pred_target = if_req_addr + if_resp_branch_imm;
	assign if_resp_bp_index = if_req_addr[BP_INDEX_BITS+1:2];
	assign if_resp_is_branch = fetch_is_branch(iresp.data);
	assign if_resp_bht_taken = bp_valid[if_resp_bp_index] ? bp_counter[if_resp_bp_index][1] : 1'b0;
	assign if_resp_bp_decision = bp_valid[if_resp_bp_index] ? if_resp_bht_taken : if_resp_branch_imm[63];
	assign if_resp_pred_taken =
		!iresp.page_fault && if_resp_is_branch && if_resp_bp_decision &&
		!|if_resp_pred_target[1:0] &&
		!pmp_access_fault(if_resp_pred_target, MSIZE4, 1'b1, 1'b0, fetch_priv);
	assign if_resp_to_id = !if_id_valid || (id_consume && !id_redirect);

	always_ff @(posedge clk) begin
		if (reset) begin
			pc <= PCINIT;
			if_pending <= 1'b0;
			if_req_addr <= '0;
			if_id_valid <= 1'b0;
			if_id_pc <= '0;
			if_id_instr <= '0;
			if_id_access_fault <= 1'b0;
			if_id_page_fault <= 1'b0;
			if_id_fault_tval <= '0;
			if_id_pred_taken <= 1'b0;
			if_id_pred_target <= '0;
			if_buf_valid <= 1'b0;
			if_buf_pc <= '0;
			if_buf_instr <= '0;
			if_buf_access_fault <= 1'b0;
			if_buf_page_fault <= 1'b0;
			if_buf_fault_tval <= '0;
			if_buf_pred_taken <= 1'b0;
			if_buf_pred_target <= '0;
			if_pred_req_valid <= 1'b0;
			if_pred_req_addr <= '0;
			if_kill_pending <= 1'b0;
			for (int bp_i = 0; bp_i < BP_ENTRIES; bp_i += 1) begin
				bp_valid[bp_i] <= 1'b0;
				bp_counter[bp_i] <= 2'b01;
			end
		end
		else begin
			if (wb_trap_valid) begin
				pc <= wb_trap_to_s ? {csr_stvec[63:2], 2'b00} : {csr_mtvec[63:2], 2'b00};
				if_id_valid <= 1'b0;
				if_id_access_fault <= 1'b0;
				if_id_page_fault <= 1'b0;
				if_id_fault_tval <= '0;
				if_id_pred_taken <= 1'b0;
				if_id_pred_target <= '0;
				if_buf_valid <= 1'b0;
				if_pred_req_valid <= 1'b0;
				if (if_pending && !iresp.data_ok) begin
					if_kill_pending <= 1'b1;
				end
				else begin
					if_pending <= 1'b0;
					if_kill_pending <= 1'b0;
				end
			end
			else if (if_pred_req_valid && !if_pending && !mem_pending) begin
				if_pred_req_valid <= 1'b0;
				if (pmp_access_fault(if_pred_req_addr, MSIZE4, 1'b1, 1'b0, fetch_priv)) begin
					pc <= if_pred_req_addr + 64'd4;
					if (if_resp_to_id) begin
						if_id_valid <= 1'b1;
						if_id_pc <= if_pred_req_addr;
						if_id_instr <= 32'h0000_0013;
						if_id_access_fault <= 1'b1;
						if_id_page_fault <= 1'b0;
						if_id_fault_tval <= if_pred_req_addr;
						if_id_pred_taken <= 1'b0;
						if_id_pred_target <= '0;
					end
					else if (!if_buf_valid) begin
						if_buf_valid <= 1'b1;
						if_buf_pc <= if_pred_req_addr;
						if_buf_instr <= 32'h0000_0013;
						if_buf_access_fault <= 1'b1;
						if_buf_page_fault <= 1'b0;
						if_buf_fault_tval <= if_pred_req_addr;
						if_buf_pred_taken <= 1'b0;
						if_buf_pred_target <= '0;
					end
				end
				else begin
					if_pending <= 1'b1;
					if_req_addr <= if_pred_req_addr;
				end
			end
			else if (if_can_request) begin
				if (pmp_access_fault(pc, MSIZE4, 1'b1, 1'b0, fetch_priv)) begin
					if_id_valid <= 1'b1;
					if_id_pc <= pc;
					if_id_instr <= 32'h0000_0013;
					if_id_access_fault <= 1'b1;
					if_id_page_fault <= 1'b0;
					if_id_fault_tval <= pc;
					if_id_pred_taken <= 1'b0;
					if_id_pred_target <= '0;
				end
				else begin
					if_pending <= 1'b1;
					if_req_addr <= pc;
				end
			end
			if (if_pending && iresp.data_ok) begin
				if_pending <= 1'b0;
				if_kill_pending <= 1'b0;
				if (!if_kill_pending && !wb_trap_valid) begin
					if (if_resp_to_id) begin
						if_id_valid <= 1'b1;
						if_id_pc <= if_req_addr;
						if_id_instr <= if_resp_instr;
						if_id_access_fault <= 1'b0;
						if_id_page_fault <= iresp.page_fault;
						if_id_fault_tval <= iresp.page_fault ? if_req_addr : '0;
						if_id_pred_taken <= if_resp_pred_taken;
						if_id_pred_target <= if_resp_pred_target;
						pc <= if_resp_pred_taken ? if_resp_pred_target : (if_req_addr + 64'd4);
						if_pred_req_valid <= if_resp_pred_taken;
						if_pred_req_addr <= if_resp_pred_target;
					end
					else if (!if_buf_valid) begin
						if_buf_valid <= 1'b1;
						if_buf_pc <= if_req_addr;
						if_buf_instr <= if_resp_instr;
						if_buf_access_fault <= 1'b0;
						if_buf_page_fault <= iresp.page_fault;
						if_buf_fault_tval <= iresp.page_fault ? if_req_addr : '0;
						if_buf_pred_taken <= if_resp_pred_taken;
						if_buf_pred_target <= if_resp_pred_target;
						pc <= if_req_addr + 64'd4;
					end
				end
			end
			if (if_id_valid && id_consume && !id_redirect &&
				!(if_pending && iresp.data_ok && !if_kill_pending && !wb_trap_valid)) begin
				if (if_buf_valid) begin
					if_id_valid <= 1'b1;
					if_id_pc <= if_buf_pc;
					if_id_instr <= if_buf_instr;
					if_id_access_fault <= if_buf_access_fault;
					if_id_page_fault <= if_buf_page_fault;
					if_id_fault_tval <= if_buf_fault_tval;
					if_id_pred_taken <= if_buf_pred_taken;
					if_id_pred_target <= if_buf_pred_target;
					if_buf_valid <= 1'b0;
					pc <= if_buf_pred_taken ? if_buf_pred_target : (if_buf_pc + 64'd4);
					if_pred_req_valid <= if_buf_pred_taken;
					if_pred_req_addr <= if_buf_pred_target;
				end
				else begin
					if_id_valid <= 1'b0;
					if_id_access_fault <= 1'b0;
					if_id_page_fault <= 1'b0;
					if_id_pred_taken <= 1'b0;
					if_id_pred_target <= '0;
				end
			end
			if (if_id_valid && id_consume && id_redirect) begin
				pc <= id_redirect_target;
				if_id_valid <= 1'b0;
				if_id_access_fault <= 1'b0;
				if_id_page_fault <= 1'b0;
				if_id_pred_taken <= 1'b0;
				if_id_pred_target <= '0;
				if_buf_valid <= 1'b0;
				if_pred_req_valid <= 1'b0;
				if (if_pending && !iresp.data_ok) begin
					if_kill_pending <= 1'b1;
				end
				else begin
					if_pending <= 1'b0;
					if_kill_pending <= 1'b0;
				end
				if (id_fast_redirect && !if_pending) begin
					if (pmp_access_fault(id_redirect_target, MSIZE4, 1'b1, 1'b0, fetch_priv)) begin
						if_pending <= 1'b0;
						if_id_valid <= 1'b1;
						if_id_pc <= id_redirect_target;
						if_id_instr <= 32'h0000_0013;
						if_id_access_fault <= 1'b1;
						if_id_page_fault <= 1'b0;
						if_id_fault_tval <= id_redirect_target;
						if_id_pred_taken <= 1'b0;
						if_id_pred_target <= '0;
					end
					else begin
						if_pending <= 1'b1;
						if_req_addr <= id_redirect_target;
					end
				end
			end
			if (if_id_valid && id_consume && id_is_branch && !id_trap) begin
				bp_valid[id_bp_index] <= 1'b1;
				if (!bp_valid[id_bp_index]) begin
					bp_counter[id_bp_index] <= id_branch_taken ? 2'b10 : 2'b01;
				end
				else if (id_branch_taken && (bp_counter[id_bp_index] != 2'b11)) begin
					bp_counter[id_bp_index] <= bp_counter[id_bp_index] + 2'b01;
				end
				else if (!id_branch_taken && (bp_counter[id_bp_index] != 2'b00)) begin
					bp_counter[id_bp_index] <= bp_counter[id_bp_index] - 2'b01;
				end
			end
		end
	end

	assign opc   = if_id_instr[6:0];
	assign rd    = if_id_instr[11:7];
	assign fun3  = if_id_instr[14:12];
	assign rs1   = if_id_instr[19:15];
	assign rs2   = if_id_instr[24:20];
	assign fun7  = if_id_instr[31:25];
	assign imm_i = {{52{if_id_instr[31]}}, if_id_instr[31:20]};
	assign imm_s = {{52{if_id_instr[31]}}, if_id_instr[31:25], if_id_instr[11:7]};
	assign imm_u = {{32{if_id_instr[31]}}, if_id_instr[31:12], 12'd0};
	assign imm_b = {{51{if_id_instr[31]}}, if_id_instr[31], if_id_instr[7], if_id_instr[30:25], if_id_instr[11:8], 1'b0};
	assign imm_j = {{43{if_id_instr[31]}}, if_id_instr[31], if_id_instr[19:12], if_id_instr[20], if_id_instr[30:21], 1'b0};

	word_t rs1_val, rs2_val;

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

	function automatic word_t sext8(input logic [7:0] x);
		sext8 = {{56{x[7]}}, x};
	endfunction

	function automatic word_t sext16(input logic [15:0] x);
		sext16 = {{48{x[15]}}, x};
	endfunction

	function automatic word_t sext32(input logic [31:0] x);
		sext32 = {{32{x[31]}}, x};
	endfunction

	function automatic strobe_t make_store_mask(input msize_t size, input logic [2:0] ofs);
		unique case (size)
			MSIZE1: make_store_mask = 8'b0000_0001 << ofs;
			MSIZE2: make_store_mask = 8'b0000_0011 << ofs;
			MSIZE4: make_store_mask = 8'b0000_1111 << ofs;
			default: make_store_mask = 8'b1111_1111;
		endcase
	endfunction

	function automatic word_t make_store_data(input msize_t size, input logic [2:0] ofs, input word_t src);
		logic [63:0] payload;
		logic [5:0] shamt;
		shamt = {ofs, 3'b000};
		unique case (size)
			MSIZE1: payload = {56'd0, src[7:0]};
			MSIZE2: payload = {48'd0, src[15:0]};
			MSIZE4: payload = {32'd0, src[31:0]};
			default: payload = src;
		endcase
		make_store_data = payload << shamt;
	endfunction

	function automatic word_t make_load_data(input word_t raw, input logic [2:0] ofs, input logic [7:0] optype);
		word_t shifted;
		logic [7:0] b;
		logic [15:0] h;
		logic [31:0] w;
		shifted = raw >> {ofs, 3'b000};
		b = shifted[7:0];
		h = shifted[15:0];
		w = shifted[31:0];
		unique case (optype)
			8'd0: make_load_data = {{56{b[7]}}, b};
			8'd1: make_load_data = {{48{h[15]}}, h};
			8'd2: make_load_data = {{32{w[31]}}, w};
			8'd3: make_load_data = shifted;
			8'd4: make_load_data = {56'd0, b};
			8'd5: make_load_data = {48'd0, h};
			8'd6: make_load_data = {32'd0, w};
			default: make_load_data = 64'd0;
		endcase
	endfunction

	function automatic logic [31:0] select_word(input word_t raw, input logic [2:0] ofs);
		word_t shifted;
		shifted = raw >> {ofs, 3'b000};
		select_word = shifted[31:0];
	endfunction

	function automatic logic [31:0] amo_w_result(input logic [4:0] op, input logic [31:0] oldw, input logic [31:0] srcw);
		unique case (op)
			5'b00000: amo_w_result = oldw + srcw;                                  // AMOADD.W
			5'b00001: amo_w_result = srcw;                                         // AMOSWAP.W
			5'b00100: amo_w_result = oldw ^ srcw;                                  // AMOXOR.W
			5'b01100: amo_w_result = oldw & srcw;                                  // AMOAND.W
			5'b01000: amo_w_result = oldw | srcw;                                  // AMOOR.W
			5'b10000: amo_w_result = ($signed(oldw) < $signed(srcw)) ? oldw : srcw; // AMOMIN.W
			5'b10100: amo_w_result = ($signed(oldw) > $signed(srcw)) ? oldw : srcw; // AMOMAX.W
			5'b11000: amo_w_result = (oldw < srcw) ? oldw : srcw;                  // AMOMINU.W
			5'b11100: amo_w_result = (oldw > srcw) ? oldw : srcw;                  // AMOMAXU.W
			default:  amo_w_result = srcw;
		endcase
	endfunction

	function automatic logic [7:0] amo_fuop(input logic [4:0] op);
		unique case (op)
			5'b00010: amo_fuop = 8'o02; // LR.W
			5'b00011: amo_fuop = 8'o06; // SC.W
			5'b00001: amo_fuop = 8'o12; // AMOSWAP.W
			5'b00000: amo_fuop = 8'o16; // AMOADD.W
			5'b00100: amo_fuop = 8'o22; // AMOXOR.W
			5'b01100: amo_fuop = 8'o26; // AMOAND.W
			5'b01000: amo_fuop = 8'o32; // AMOOR.W
			5'b10000: amo_fuop = 8'o36; // AMOMIN.W
			5'b10100: amo_fuop = 8'o42; // AMOMAX.W
			5'b11000: amo_fuop = 8'o46; // AMOMINU.W
			5'b11100: amo_fuop = 8'o52; // AMOMAXU.W
			default:  amo_fuop = 8'o00;
		endcase
	endfunction

	function automatic word_t csr_read(input csr_addr_t id);
		unique case (id)
			CSR_MSTATUS:  csr_read = csr_mstatus;
			CSR_SSTATUS:  csr_read = csr_mstatus & SSTATUS_MASK;
			CSR_MTVEC:    csr_read = csr_mtvec;
			CSR_STVEC:    csr_read = csr_stvec;
			CSR_MIP:      csr_read = mip_value & MIP_MASK;
			CSR_SIP:      csr_read = mip_value & MIP_S_MASK;
			CSR_MIE:      csr_read = csr_mie;
			CSR_SIE:      csr_read = csr_mie & MIP_S_MASK;
			CSR_MCOUNTEREN: csr_read = csr_mcounteren;
			CSR_SCOUNTEREN: csr_read = csr_scounteren;
			CSR_MSCRATCH: csr_read = csr_mscratch;
			CSR_SSCRATCH: csr_read = csr_sscratch;
			CSR_MEPC:     csr_read = csr_mepc;
			CSR_SEPC:     csr_read = csr_sepc;
			CSR_MCAUSE:   csr_read = csr_mcause;
			CSR_SCAUSE:   csr_read = csr_scause;
			CSR_MTVAL:    csr_read = csr_mtval;
			CSR_STVAL:    csr_read = csr_stval;
			CSR_SATP:     csr_read = csr_satp;
			CSR_CYCLE,
			CSR_TIME,
			CSR_MCYCLE:   csr_read = csr_mcycle;
			CSR_INSTRET,
			CSR_MINSTRET: csr_read = csr_minstret;
			CSR_MHARTID:  csr_read = csr_mhartid;
			CSR_MEDELEG:  csr_read = csr_medeleg;
			CSR_MIDELEG:  csr_read = csr_mideleg;
			CSR_PMPADDR0: csr_read = csr_pmpaddr[0];
			CSR_PMPADDR1: csr_read = csr_pmpaddr[1];
			CSR_PMPADDR2: csr_read = csr_pmpaddr[2];
			CSR_PMPADDR3: csr_read = csr_pmpaddr[3];
			CSR_PMPADDR4: csr_read = csr_pmpaddr[4];
			CSR_PMPADDR5: csr_read = csr_pmpaddr[5];
			CSR_PMPADDR6: csr_read = csr_pmpaddr[6];
			CSR_PMPADDR7: csr_read = csr_pmpaddr[7];
			CSR_PMPCFG0:  csr_read = csr_pmpcfg0;
			default:      csr_read = 64'd0;
		endcase
	endfunction

	function automatic logic csr_supported(input csr_addr_t id);
		unique case (id)
			CSR_MSTATUS, CSR_SSTATUS, CSR_MTVEC, CSR_STVEC,
			CSR_MIP, CSR_SIP, CSR_MIE, CSR_SIE,
			CSR_MCOUNTEREN, CSR_SCOUNTEREN,
			CSR_MSCRATCH, CSR_SSCRATCH, CSR_MEPC, CSR_SEPC,
			CSR_MCAUSE, CSR_SCAUSE, CSR_MTVAL, CSR_STVAL,
			CSR_SATP, CSR_CYCLE, CSR_TIME, CSR_INSTRET,
			CSR_MCYCLE, CSR_MINSTRET, CSR_MHARTID,
			CSR_MEDELEG, CSR_MIDELEG, CSR_PMPADDR0, CSR_PMPADDR1,
			CSR_PMPADDR2, CSR_PMPADDR3, CSR_PMPADDR4, CSR_PMPADDR5,
			CSR_PMPADDR6, CSR_PMPADDR7, CSR_PMPCFG0:
				csr_supported = 1'b1;
			default:
				csr_supported = 1'b0;
		endcase
	endfunction

	function automatic logic counter_csr_access_allowed(input csr_addr_t id, input logic [1:0] mode);
		logic [5:0] counter_bit;
		logic is_counter;
		begin
			is_counter = 1'b1;
			unique case (id)
				CSR_CYCLE:   counter_bit = 6'd0;
				CSR_TIME:    counter_bit = 6'd1;
				CSR_INSTRET: counter_bit = 6'd2;
				default: begin
					is_counter = 1'b0;
					counter_bit = 6'd0;
				end
			endcase

			if (!is_counter || (mode == PRIV_M)) begin
				counter_csr_access_allowed = 1'b1;
			end
			else if (mode == PRIV_S) begin
				counter_csr_access_allowed = csr_mcounteren[counter_bit];
			end
			else begin
				counter_csr_access_allowed =
					csr_mcounteren[counter_bit] && csr_scounteren[counter_bit];
			end
		end
	endfunction

	function automatic logic addr_misaligned(input addr_t addr, input msize_t size);
		unique case (size)
			MSIZE1: addr_misaligned = 1'b0;
			MSIZE2: addr_misaligned = addr[0];
			MSIZE4: addr_misaligned = |addr[1:0];
			default: addr_misaligned = |addr[2:0];
		endcase
	endfunction

	function automatic word_t access_size_bytes(input msize_t size);
		unique case (size)
			MSIZE1: access_size_bytes = 64'd1;
			MSIZE2: access_size_bytes = 64'd2;
			MSIZE4: access_size_bytes = 64'd4;
			default: access_size_bytes = 64'd8;
		endcase
	endfunction

	function automatic logic [7:0] pmp_cfg(input int unsigned entry);
		unique case (entry)
			0: pmp_cfg = csr_pmpcfg0[7:0];
			1: pmp_cfg = csr_pmpcfg0[15:8];
			2: pmp_cfg = csr_pmpcfg0[23:16];
			3: pmp_cfg = csr_pmpcfg0[31:24];
			4: pmp_cfg = csr_pmpcfg0[39:32];
			5: pmp_cfg = csr_pmpcfg0[47:40];
			6: pmp_cfg = csr_pmpcfg0[55:48];
			7: pmp_cfg = csr_pmpcfg0[63:56];
			default: pmp_cfg = 8'd0;
		endcase
	endfunction

	function automatic logic pmp_entry_match(input int unsigned entry, input addr_t addr, input msize_t size);
		logic [7:0] cfg;
		logic [1:0] addr_mode;
		word_t start_addr, end_addr, base, top, bytes, low_mask, pmpaddr, prev_pmpaddr;
		int ones;
		cfg = pmp_cfg(entry);
		addr_mode = cfg[4:3];
		pmpaddr = csr_pmpaddr[entry];
		prev_pmpaddr = (entry == 0) ? 64'd0 : csr_pmpaddr[entry - 1];
		start_addr = addr;
		end_addr = addr + access_size_bytes(size) - 64'd1;
		base = 64'd0;
		top = 64'd0;
		bytes = 64'd0;
		low_mask = 64'd0;
		ones = 0;
		pmp_entry_match = 1'b0;

		unique case (addr_mode)
			2'b01: begin // TOR
				base = (entry == 0) ? 64'd0 : (prev_pmpaddr << 2);
				top = pmpaddr << 2;
				pmp_entry_match = (start_addr >= base) && (end_addr < top);
			end
			2'b10: begin // NA4
				base = pmpaddr << 2;
				top = base + 64'd4;
				pmp_entry_match = (start_addr >= base) && (end_addr < top);
			end
			2'b11: begin // NAPOT
				for (int i = 0; i < 54; i += 1) begin
					if (pmpaddr[i]) ones += 1;
					else break;
				end
				bytes = 64'd1 << (ones + 3);
				low_mask = (ones == 0) ? 64'd0 : ((64'd1 << ones) - 64'd1);
				base = (pmpaddr & ~low_mask) << 2;
				top = base + bytes;
				pmp_entry_match = (start_addr >= base) && (end_addr < top);
			end
			default: begin
				pmp_entry_match = 1'b0;
			end
		endcase
	endfunction

	function automatic logic pmp_access_fault(
		input addr_t addr,
		input msize_t size,
		input logic is_exec,
		input logic is_write,
		input logic [1:0] mode
	);
		logic [7:0] cfg, matched_cfg;
		logic any_active, matched, permitted;
		any_active = 1'b0;
		matched = 1'b0;
		matched_cfg = 8'd0;

		for (int entry = 0; entry < PMP_ENTRIES; entry += 1) begin
			cfg = pmp_cfg(entry);
			if (cfg[4:3] != 2'b00) begin
				any_active = 1'b1;
				if (!matched && pmp_entry_match(entry, addr, size)) begin
					matched = 1'b1;
					matched_cfg = cfg;
				end
			end
		end

		permitted = is_exec ? matched_cfg[2] : (is_write ? matched_cfg[1] : matched_cfg[0]);

		if (!any_active) begin
			pmp_access_fault = 1'b0;
		end
		else if (!matched) begin
			pmp_access_fault = (mode != PRIV_M);
		end
		else if ((mode == PRIV_M) && !matched_cfg[7]) begin
			pmp_access_fault = 1'b0;
		end
		else begin
			pmp_access_fault = !permitted;
		end
	endfunction

	function automatic logic trap_delegated(input logic is_interrupt, input word_t cause, input logic [1:0] from_priv);
		if (from_priv == PRIV_M || |cause[63:6]) begin
			trap_delegated = 1'b0;
		end
		else begin
			trap_delegated = is_interrupt ? csr_mideleg[cause[5:0]] : csr_medeleg[cause[5:0]];
		end
	endfunction

	logic id_wen, id_use_imm, id_is_word, id_valid;
	logic id_is_md, id_is_lui, id_is_auipc, id_is_load, id_is_store, id_is_amo;
	logic id_is_branch, id_is_jal, id_is_jalr, id_is_csr, id_is_fence;
	logic id_is_ecall, id_is_ebreak, id_is_mret, id_is_sret, id_is_wfi, id_is_sfence_vma;
	logic [3:0] id_alu_op;
	logic [2:0] id_branch_op;
	logic [3:0] id_md_op;
	msize_t id_mem_size;
	logic [7:0] id_load_optype;
	word_t ex_op1, ex_op2, ex_res, ex_res_raw, md_res;
	word_t id_jalr_target_raw;
	addr_t id_mem_addr;
	addr_t id_jump_target, id_branch_target, id_branch_next_pc, id_control_target;
	strobe_t id_store_mask;
	word_t id_store_data;
	logic id_fire, id_go_mem, id_branch_taken, id_branch_mispredict;
	csr_addr_t id_csr_addr;
	word_t id_csr_rdata, id_csr_src, id_csr_wdata;
	logic id_csr_wen;
	logic id_csr_legal, id_instr_legal;
	logic id_is_lr, id_is_sc, id_sc_success;
	logic [4:0] id_amo_op;
	logic id_control_misaligned, id_load_misaligned, id_store_misaligned;
	logic id_instr_access_fault, id_instr_page_fault, id_load_access_fault, id_store_access_fault;
	logic id_sync_exception, id_interrupt, id_trap, id_trap_is_interrupt, id_trap_to_s;
	word_t id_interrupt_cause, id_trap_cause, id_trap_tval;
	logic [BP_INDEX_BITS-1:0] id_bp_index;

	localparam logic [3:0] ALU_ADD  = 4'd0;
	localparam logic [3:0] ALU_SUB  = 4'd1;
	localparam logic [3:0] ALU_AND  = 4'd2;
	localparam logic [3:0] ALU_OR   = 4'd3;
	localparam logic [3:0] ALU_XOR  = 4'd4;
	localparam logic [3:0] ALU_SLL  = 4'd5;
	localparam logic [3:0] ALU_SRL  = 4'd6;
	localparam logic [3:0] ALU_SRA  = 4'd7;
	localparam logic [3:0] ALU_SLT  = 4'd8;
	localparam logic [3:0] ALU_SLTU = 4'd9;

	localparam logic [2:0] BR_EQ  = 3'd0;
	localparam logic [2:0] BR_NE  = 3'd1;
	localparam logic [2:0] BR_LT  = 3'd2;
	localparam logic [2:0] BR_GE  = 3'd3;
	localparam logic [2:0] BR_LTU = 3'd4;
	localparam logic [2:0] BR_GEU = 3'd5;

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

	localparam logic [4:0] AMO_ADD  = 5'b00000;
	localparam logic [4:0] AMO_SWAP = 5'b00001;
	localparam logic [4:0] AMO_LR   = 5'b00010;
	localparam logic [4:0] AMO_SC   = 5'b00011;
	localparam logic [4:0] AMO_XOR  = 5'b00100;
	localparam logic [4:0] AMO_OR   = 5'b01000;
	localparam logic [4:0] AMO_AND  = 5'b01100;
	localparam logic [4:0] AMO_MIN  = 5'b10000;
	localparam logic [4:0] AMO_MAX  = 5'b10100;
	localparam logic [4:0] AMO_MINU = 5'b11000;
	localparam logic [4:0] AMO_MAXU = 5'b11100;

	localparam logic [2:0] CSR_RW  = 3'b001;
	localparam logic [2:0] CSR_RS  = 3'b010;
	localparam logic [2:0] CSR_RC  = 3'b011;
	localparam logic [2:0] CSR_RWI = 3'b101;
	localparam logic [2:0] CSR_RSI = 3'b110;
	localparam logic [2:0] CSR_RCI = 3'b111;

`ifdef VERILATOR
	localparam logic ENABLE_M_EXT = 1'b1;
`else
	// Keep FPGA implementation lightweight for Lab3 board run.
	localparam logic ENABLE_M_EXT = 1'b0;
`endif

	always_comb begin
		id_valid = if_id_valid;
		id_wen = 1'b0;
		id_use_imm = 1'b0;
		id_is_word = 1'b0;
		id_is_md = 1'b0;
		id_is_lui = 1'b0;
		id_is_auipc = 1'b0;
		id_is_load = 1'b0;
		id_is_store = 1'b0;
		id_is_amo = 1'b0;
		id_is_branch = 1'b0;
		id_is_jal = 1'b0;
		id_is_jalr = 1'b0;
		id_is_csr = 1'b0;
		id_is_fence = 1'b0;
		id_is_ecall = 1'b0;
		id_is_ebreak = 1'b0;
		id_is_mret = 1'b0;
		id_is_sret = 1'b0;
		id_is_wfi = 1'b0;
		id_alu_op = ALU_ADD;
		id_branch_op = BR_EQ;
		id_md_op = MD_NONE;
		id_mem_size = MSIZE8;
		id_load_optype = 8'd0;

		unique case (opc)
			7'b0010011: begin
				id_wen = 1'b1;
				id_use_imm = 1'b1;
				unique case (fun3)
					3'b000: id_alu_op = ALU_ADD;
					3'b001: begin
						if (if_id_instr[31:26] == 6'b000000) id_alu_op = ALU_SLL;
						else id_wen = 1'b0;
					end
					3'b010: id_alu_op = ALU_SLT;
					3'b011: id_alu_op = ALU_SLTU;
					3'b100: id_alu_op = ALU_XOR;
					3'b101: begin
						if (if_id_instr[31:26] == 6'b000000) id_alu_op = ALU_SRL;
						else if (if_id_instr[31:26] == 6'b010000) id_alu_op = ALU_SRA;
						else id_wen = 1'b0;
					end
					3'b110: id_alu_op = ALU_OR;
					3'b111: id_alu_op = ALU_AND;
					default: id_wen = 1'b0;
				endcase
			end

			7'b0110011: begin
				if (ENABLE_M_EXT && fun7 == 7'b0000001) begin
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
						{7'b0000000, 3'b000}: id_alu_op = ALU_ADD;
						{7'b0100000, 3'b000}: id_alu_op = ALU_SUB;
						{7'b0000000, 3'b001}: id_alu_op = ALU_SLL;
						{7'b0000000, 3'b010}: id_alu_op = ALU_SLT;
						{7'b0000000, 3'b011}: id_alu_op = ALU_SLTU;
						{7'b0000000, 3'b111}: id_alu_op = ALU_AND;
						{7'b0000000, 3'b110}: id_alu_op = ALU_OR;
						{7'b0000000, 3'b100}: id_alu_op = ALU_XOR;
						{7'b0000000, 3'b101}: id_alu_op = ALU_SRL;
						{7'b0100000, 3'b101}: id_alu_op = ALU_SRA;
						default: id_wen = 1'b0;
					endcase
				end
			end

			7'b0111011: begin
				if (ENABLE_M_EXT && fun7 == 7'b0000001) begin
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
						{7'b0000000, 3'b000}: id_alu_op = ALU_ADD;
						{7'b0100000, 3'b000}: id_alu_op = ALU_SUB;
						{7'b0000000, 3'b001}: id_alu_op = ALU_SLL;
						{7'b0000000, 3'b101}: id_alu_op = ALU_SRL;
						{7'b0100000, 3'b101}: id_alu_op = ALU_SRA;
						default: id_wen = 1'b0;
					endcase
				end
			end

			7'b0011011: begin
				id_wen = 1'b1;
				id_use_imm = 1'b1;
				id_is_word = 1'b1;
				unique case (fun3)
					3'b000: id_alu_op = ALU_ADD;
					3'b001: begin
						if (fun7 == 7'b0000000) id_alu_op = ALU_SLL;
						else id_wen = 1'b0;
					end
					3'b101: begin
						if (fun7 == 7'b0000000) id_alu_op = ALU_SRL;
						else if (fun7 == 7'b0100000) id_alu_op = ALU_SRA;
						else id_wen = 1'b0;
					end
					default: id_wen = 1'b0;
				endcase
			end

			7'b0110111: begin
				id_wen = 1'b1;
				id_is_lui = 1'b1;
			end

			7'b0010111: begin
				id_wen = 1'b1;
				id_is_auipc = 1'b1;
			end

			7'b1100011: begin
				id_is_branch = 1'b1;
				unique case (fun3)
					3'b000: id_branch_op = BR_EQ;
					3'b001: id_branch_op = BR_NE;
					3'b100: id_branch_op = BR_LT;
					3'b101: id_branch_op = BR_GE;
					3'b110: id_branch_op = BR_LTU;
					3'b111: id_branch_op = BR_GEU;
					default: id_is_branch = 1'b0;
				endcase
			end

			7'b1101111: begin
				id_wen = 1'b1;
				id_is_jal = 1'b1;
			end

			7'b1100111: begin
				if (fun3 == 3'b000) begin
					id_wen = 1'b1;
					id_is_jalr = 1'b1;
				end
			end

			7'b0000011: begin
				id_wen = 1'b1;
				id_is_load = 1'b1;
				unique case (fun3)
					3'b000: begin id_mem_size = MSIZE1; id_load_optype = 8'd0; end
					3'b001: begin id_mem_size = MSIZE2; id_load_optype = 8'd1; end
					3'b010: begin id_mem_size = MSIZE4; id_load_optype = 8'd2; end
					3'b011: begin id_mem_size = MSIZE8; id_load_optype = 8'd3; end
					3'b100: begin id_mem_size = MSIZE1; id_load_optype = 8'd4; end
					3'b101: begin id_mem_size = MSIZE2; id_load_optype = 8'd5; end
					3'b110: begin id_mem_size = MSIZE4; id_load_optype = 8'd6; end
					default: begin id_wen = 1'b0; id_is_load = 1'b0; end
				endcase
			end

			7'b0100011: begin
				id_is_store = 1'b1;
				unique case (fun3)
					3'b000: id_mem_size = MSIZE1;
					3'b001: id_mem_size = MSIZE2;
					3'b010: id_mem_size = MSIZE4;
					3'b011: id_mem_size = MSIZE8;
					default: id_is_store = 1'b0;
				endcase
			end

				7'b0101111: begin
					if (fun3 == 3'b010) begin
						id_wen = 1'b1;
					id_is_amo = 1'b1;
					id_mem_size = MSIZE4;
					id_load_optype = 8'd2;
					unique case (if_id_instr[31:27])
						AMO_ADD, AMO_SWAP, AMO_LR, AMO_SC,
						AMO_XOR, AMO_OR, AMO_AND,
						AMO_MIN, AMO_MAX, AMO_MINU, AMO_MAXU: begin
						end
						default: begin
							id_wen = 1'b0;
							id_is_amo = 1'b0;
						end
					endcase
					if ((if_id_instr[31:27] == AMO_LR) && (rs2 != 5'd0)) begin
						id_wen = 1'b0;
						id_is_amo = 1'b0;
					end
					end
				end

				7'b0001111: begin
					if ((fun3 == 3'b000) || (fun3 == 3'b001)) begin
						id_is_fence = 1'b1;
					end
				end

				7'b1110011: begin
					unique case (fun3)
						CSR_RW, CSR_RS, CSR_RC, CSR_RWI, CSR_RSI, CSR_RCI: begin
							id_wen = 1'b1;
							id_is_csr = 1'b1;
						end
						3'b000: begin
							if (if_id_instr[31:20] == 12'h000) id_is_ecall = 1'b1;
							else if (if_id_instr[31:20] == 12'h001) id_is_ebreak = 1'b1;
							else if (if_id_instr[31:20] == 12'h102) id_is_sret = 1'b1;
							else if (if_id_instr[31:20] == 12'h105) id_is_wfi = 1'b1;
							else if (if_id_instr[31:20] == 12'h302) id_is_mret = 1'b1;
						end
					default: begin
					end
				endcase
			end

			default: begin
				end
		endcase
	end

	assign ex_op1 = rs1_val;
	assign ex_op2 = id_use_imm ? imm_i : rs2_val;

	always_comb begin
		logic [31:0] a32, b32, res32;
		a32 = ex_op1[31:0];
		b32 = ex_op2[31:0];
		res32 = 32'd0;

		if (id_is_word) begin
			unique case (id_alu_op)
				ALU_ADD:  res32 = a32 + b32;
				ALU_SUB:  res32 = a32 - b32;
				ALU_AND:  res32 = a32 & b32;
				ALU_OR:   res32 = a32 | b32;
				ALU_XOR:  res32 = a32 ^ b32;
				ALU_SLL:  res32 = a32 << ex_op2[4:0];
				ALU_SRL:  res32 = a32 >> ex_op2[4:0];
				ALU_SRA:  res32 = $signed(a32) >>> ex_op2[4:0];
				ALU_SLT:  res32 = {31'd0, ($signed(a32) < $signed(b32))};
				ALU_SLTU: res32 = {31'd0, (a32 < b32)};
				default:  res32 = 32'd0;
			endcase
			ex_res_raw = {32'd0, res32};
		end
		else begin
			unique case (id_alu_op)
				ALU_ADD:  ex_res_raw = ex_op1 + ex_op2;
				ALU_SUB:  ex_res_raw = ex_op1 - ex_op2;
				ALU_AND:  ex_res_raw = ex_op1 & ex_op2;
				ALU_OR:   ex_res_raw = ex_op1 | ex_op2;
				ALU_XOR:  ex_res_raw = ex_op1 ^ ex_op2;
				ALU_SLL:  ex_res_raw = ex_op1 << ex_op2[5:0];
				ALU_SRL:  ex_res_raw = ex_op1 >> ex_op2[5:0];
				ALU_SRA:  ex_res_raw = $signed(ex_op1) >>> ex_op2[5:0];
				ALU_SLT:  ex_res_raw = {63'd0, ($signed(ex_op1) < $signed(ex_op2))};
				ALU_SLTU: ex_res_raw = {63'd0, (ex_op1 < ex_op2)};
				default:  ex_res_raw = '0;
			endcase
		end
	end

`ifdef VERILATOR
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
`else
	always_comb begin
		md_res = '0;
	end
`endif

	assign ex_res = id_is_md ? md_res : (id_is_word ? sext32(ex_res_raw[31:0]) : ex_res_raw);
	assign id_csr_addr = if_id_instr[31:20];
	assign id_csr_rdata = csr_read(id_csr_addr);
	assign id_csr_src = fun3[2] ? {59'd0, rs1} : rs1_val;
	assign id_amo_op = if_id_instr[31:27];
	assign id_is_lr = id_is_amo && (id_amo_op == AMO_LR);
	assign id_is_sc = id_is_amo && (id_amo_op == AMO_SC);
	assign id_is_sfence_vma =
		((if_id_instr & 32'hfe00_7fff) == 32'h1200_0073) &&
		(current_priv != PRIV_U);
	always_comb begin
		id_csr_wdata = id_csr_rdata;
		id_csr_wen = 1'b0;
		unique case (fun3)
			CSR_RW, CSR_RWI: begin
				id_csr_wdata = id_csr_src;
				id_csr_wen = id_is_csr;
			end
			CSR_RS, CSR_RSI: begin
				id_csr_wdata = id_csr_rdata | id_csr_src;
				id_csr_wen = id_is_csr && (id_csr_src != 64'd0);
			end
			CSR_RC, CSR_RCI: begin
				id_csr_wdata = id_csr_rdata & ~id_csr_src;
				id_csr_wen = id_is_csr && (id_csr_src != 64'd0);
			end
			default: begin
			end
		endcase
	end

	assign id_csr_legal = id_is_csr && csr_supported(id_csr_addr) &&
		(current_priv >= id_csr_addr[9:8]) &&
		!((id_csr_addr[11:10] == 2'b11) && id_csr_wen) &&
		counter_csr_access_allowed(id_csr_addr, current_priv);
		assign id_instr_legal =
			(id_wen && !id_is_csr) || id_is_store || id_is_branch ||
			id_is_fence || id_is_ecall || id_is_ebreak ||
			(id_is_sret && current_priv != PRIV_U) || (id_is_mret && current_priv == PRIV_M) ||
			(id_is_wfi && current_priv != PRIV_U) || id_is_sfence_vma ||
			id_csr_legal || (if_id_instr == 32'h0005_006b);

	always_comb begin
		unique case (id_branch_op)
			BR_EQ:  id_branch_taken = (rs1_val == rs2_val);
			BR_NE:  id_branch_taken = (rs1_val != rs2_val);
			BR_LT:  id_branch_taken = ($signed(rs1_val) < $signed(rs2_val));
			BR_GE:  id_branch_taken = ($signed(rs1_val) >= $signed(rs2_val));
			BR_LTU: id_branch_taken = (rs1_val < rs2_val);
			BR_GEU: id_branch_taken = (rs1_val >= rs2_val);
			default: id_branch_taken = 1'b0;
		endcase
	end
	assign id_branch_target = if_id_pc + imm_b;
	assign id_bp_index = if_id_pc[BP_INDEX_BITS+1:2];
	assign id_branch_next_pc = id_branch_taken ? id_branch_target : (if_id_pc + 64'd4);
	assign id_branch_mispredict = id_is_branch &&
		((if_id_pred_taken != id_branch_taken) ||
		 (if_id_pred_taken && id_branch_taken && (if_id_pred_target != id_branch_target)));
	assign id_jalr_target_raw = rs1_val + imm_i;
	assign id_jump_target = id_is_jalr ? {id_jalr_target_raw[63:1], 1'b0} : (if_id_pc + imm_j);
	assign id_control_target = id_is_branch ? id_branch_target : id_jump_target;
	assign id_mem_addr = id_is_amo ? rs1_val : (rs1_val + (id_is_store ? imm_s : imm_i));
	assign id_sc_success = id_is_sc && reservation_valid && ({id_mem_addr[63:2], 2'b00} == reservation_addr);
	assign id_control_misaligned =
		(id_is_jalr && |id_jalr_target_raw[1:0]) ||
		(((id_is_jal || (id_is_branch && id_branch_taken))) && |id_control_target[1:0]);
	assign id_load_misaligned = id_is_load && addr_misaligned(id_mem_addr, id_mem_size);
	assign id_store_misaligned = (id_is_store || id_is_amo) && addr_misaligned(id_mem_addr, id_mem_size);
	assign id_instr_access_fault = id_valid && if_id_access_fault;
	assign id_instr_page_fault = id_valid && if_id_page_fault;
	assign id_load_access_fault =
		(id_is_load || (id_is_amo && !id_is_sc)) &&
		pmp_access_fault(id_mem_addr, id_mem_size, 1'b0, 1'b0, current_priv);
	assign id_store_access_fault =
		(id_is_store || (id_is_amo && !id_is_lr)) &&
		pmp_access_fault(id_mem_addr, id_mem_size, 1'b0, 1'b1, current_priv);

	always_comb begin
		id_interrupt = 1'b0;
		id_interrupt_cause = 64'd0;
		if (id_valid && ((current_priv != PRIV_M) || csr_mstatus[3])) begin
			if (mip_value[11] && csr_mie[11]) begin
				id_interrupt = 1'b1;
				id_interrupt_cause = 64'd11;
			end
			else if (mip_value[3] && csr_mie[3]) begin
				id_interrupt = 1'b1;
				id_interrupt_cause = 64'd3;
			end
			else if (mip_value[7] && csr_mie[7]) begin
				id_interrupt = 1'b1;
				id_interrupt_cause = 64'd7;
			end
		end
		if (!id_interrupt && id_valid &&
			((current_priv == PRIV_U) || ((current_priv == PRIV_S) && csr_mstatus[1]))) begin
			if (mip_value[9] && csr_mie[9] && csr_mideleg[9]) begin
				id_interrupt = 1'b1;
				id_interrupt_cause = 64'd9;
			end
			else if (mip_value[1] && csr_mie[1] && csr_mideleg[1]) begin
				id_interrupt = 1'b1;
				id_interrupt_cause = 64'd1;
			end
			else if (mip_value[5] && csr_mie[5] && csr_mideleg[5]) begin
				id_interrupt = 1'b1;
				id_interrupt_cause = 64'd5;
			end
		end
	end

	always_comb begin
			id_sync_exception = id_valid &&
				(id_control_misaligned || id_instr_access_fault || id_instr_page_fault || !id_instr_legal ||
				 id_load_misaligned || id_load_access_fault || id_store_misaligned ||
				 id_store_access_fault || id_is_ecall || id_is_ebreak);
		id_trap_cause = id_interrupt_cause;
		id_trap_tval = 64'd0;
		if (id_control_misaligned) begin
			id_trap_cause = 64'd0;
			id_trap_tval = id_is_jalr ? id_jalr_target_raw : id_control_target;
		end
		else if (id_instr_access_fault) begin
			id_trap_cause = 64'd1;
			id_trap_tval = if_id_fault_tval;
		end
		else if (id_instr_page_fault) begin
			id_trap_cause = 64'd12;
			id_trap_tval = if_id_fault_tval;
		end
		else if (!id_instr_legal) begin
			id_trap_cause = 64'd2;
			id_trap_tval = {32'd0, if_id_instr};
		end
		else if (id_load_misaligned) begin
			id_trap_cause = 64'd4;
			id_trap_tval = id_mem_addr;
		end
		else if (id_load_access_fault) begin
			id_trap_cause = 64'd5;
			id_trap_tval = id_mem_addr;
		end
		else if (id_store_misaligned) begin
			id_trap_cause = 64'd6;
			id_trap_tval = id_mem_addr;
		end
			else if (id_store_access_fault) begin
				id_trap_cause = 64'd7;
				id_trap_tval = id_mem_addr;
			end
			else if (id_is_ebreak) begin
				id_trap_cause = 64'd3;
			end
			else if (id_is_ecall) begin
				id_trap_cause = (current_priv == PRIV_U) ? 64'd8 :
					((current_priv == PRIV_S) ? 64'd9 : 64'd11);
			end
		end

		assign id_trap = id_sync_exception || id_interrupt;
		assign id_trap_is_interrupt = !id_sync_exception && id_interrupt;
		assign id_trap_to_s = id_trap && trap_delegated(id_trap_is_interrupt, id_trap_cause, current_priv);
		assign id_redirect = id_trap || (id_is_jal || id_is_jalr) ||
			id_branch_mispredict || id_is_csr || id_is_mret || id_is_sret;
		assign id_fast_redirect = !id_trap &&
			(id_is_jal || id_is_jalr || id_branch_mispredict);
		assign if_can_request = !if_pending && !if_kill_pending && !if_buf_valid &&
			!if_pred_req_valid && !mem_pending &&
			(!if_id_valid || (id_consume && !id_redirect));
		assign id_redirect_target = id_trap ? (id_trap_to_s ? {csr_stvec[63:2], 2'b00} : {csr_mtvec[63:2], 2'b00}) :
			(id_is_mret ? csr_mepc :
			(id_is_sret ? csr_sepc :
			(id_is_csr ? (if_id_pc + 64'd4) :
			(id_is_branch ? id_branch_next_pc : id_control_target))));
	assign id_store_mask = make_store_mask(id_mem_size, id_mem_addr[2:0]);
	assign id_store_data = make_store_data(id_mem_size, id_mem_addr[2:0], rs2_val);
	assign id_fire = id_valid && !mem_pending && !wb_trap_valid;
	assign id_go_mem = id_fire &&
		(id_is_load || id_is_store || (id_is_amo && !id_is_sc) || (id_is_sc && id_sc_success)) &&
		!id_trap;
	assign id_consume = id_fire;

	logic ex_wb_valid, ex_wb_wen, ex_wb_is_load, ex_wb_is_store;
	logic ex_wb_is_atomic;
	logic [4:0] ex_wb_rd;
	word_t ex_wb_data;
	addr_t ex_wb_pc, ex_wb_mem_addr, ex_wb_mem_paddr;
	u32 ex_wb_instr;
	logic [7:0] ex_wb_load_optype;
	word_t ex_wb_store_data;
	strobe_t ex_wb_store_mask;
	logic [4:0] ex_wb_amo_op;
	word_t ex_wb_atomic_src_data;
	logic ex_wb_is_csr, ex_wb_csr_wen;
	csr_addr_t ex_wb_csr_addr;
	word_t ex_wb_csr_wdata;
		logic ex_wb_is_mret, ex_wb_is_sret;
	logic ex_wb_trap_valid, ex_wb_trap_is_interrupt;
	word_t ex_wb_trap_cause, ex_wb_trap_tval;
	addr_t ex_wb_trap_pc;
	logic [1:0] ex_wb_priv;

	always_ff @(posedge clk) begin
		if (reset) begin
			mem_pending <= 1'b0;
			mem_is_load <= 1'b0;
			mem_is_store <= 1'b0;
			mem_is_atomic <= 1'b0;
			mem_atomic_write_phase <= 1'b0;
			mem_atomic_is_lr <= 1'b0;
			mem_atomic_is_sc <= 1'b0;
			mem_wen <= 1'b0;
			mem_rd <= '0;
			mem_pc <= '0;
			mem_instr <= '0;
			mem_addr <= '0;
			mem_size <= MSIZE8;
			mem_strobe <= '0;
			mem_wdata <= '0;
			mem_load_optype <= '0;
			mem_amo_op <= '0;
			mem_atomic_wb_data <= '0;
			mem_atomic_src_data <= '0;
			mem_priv <= PRIV_M;
			reservation_valid <= 1'b0;
			reservation_addr <= '0;
			ex_wb_valid <= 1'b0;
			ex_wb_wen <= 1'b0;
			ex_wb_is_load <= 1'b0;
			ex_wb_is_store <= 1'b0;
			ex_wb_is_atomic <= 1'b0;
			ex_wb_rd <= '0;
			ex_wb_data <= '0;
			ex_wb_pc <= '0;
			ex_wb_instr <= '0;
			ex_wb_mem_addr <= '0;
			ex_wb_mem_paddr <= '0;
			ex_wb_load_optype <= '0;
			ex_wb_store_data <= '0;
			ex_wb_store_mask <= '0;
			ex_wb_amo_op <= '0;
			ex_wb_atomic_src_data <= '0;
			ex_wb_is_csr <= 1'b0;
			ex_wb_csr_wen <= 1'b0;
			ex_wb_csr_addr <= '0;
			ex_wb_csr_wdata <= '0;
			ex_wb_is_mret <= 1'b0;
			ex_wb_is_sret <= 1'b0;
			ex_wb_trap_valid <= 1'b0;
			ex_wb_trap_is_interrupt <= 1'b0;
			ex_wb_trap_cause <= '0;
			ex_wb_trap_tval <= '0;
			ex_wb_trap_pc <= '0;
			ex_wb_priv <= PRIV_M;
		end
		else begin
			ex_wb_valid <= 1'b0;
			ex_wb_wen <= 1'b0;
			ex_wb_is_load <= 1'b0;
			ex_wb_is_store <= 1'b0;
			ex_wb_is_atomic <= 1'b0;
			ex_wb_rd <= '0;
			ex_wb_data <= '0;
			ex_wb_pc <= '0;
			ex_wb_instr <= '0;
			ex_wb_mem_addr <= '0;
			ex_wb_mem_paddr <= '0;
			ex_wb_load_optype <= '0;
			ex_wb_store_data <= '0;
			ex_wb_store_mask <= '0;
			ex_wb_amo_op <= '0;
			ex_wb_atomic_src_data <= '0;
				ex_wb_is_csr <= 1'b0;
				ex_wb_csr_wen <= 1'b0;
				ex_wb_csr_addr <= '0;
				ex_wb_csr_wdata <= '0;
				ex_wb_is_mret <= 1'b0;
				ex_wb_is_sret <= 1'b0;
				ex_wb_trap_valid <= 1'b0;
			ex_wb_trap_is_interrupt <= 1'b0;
			ex_wb_trap_cause <= '0;
			ex_wb_trap_tval <= '0;
			ex_wb_trap_pc <= '0;
			ex_wb_priv <= current_priv;

			if (mem_pending && dresp.data_ok) begin
				if (dresp.page_fault) begin
					logic mem_fault_is_store;
					mem_fault_is_store = mem_is_store && (!mem_is_atomic || mem_atomic_write_phase);
					mem_pending <= 1'b0;
					mem_is_load <= 1'b0;
					mem_is_store <= 1'b0;
					mem_is_atomic <= 1'b0;
					mem_atomic_write_phase <= 1'b0;
					mem_atomic_is_lr <= 1'b0;
					mem_atomic_is_sc <= 1'b0;
					mem_wen <= 1'b0;
					ex_wb_trap_valid <= 1'b1;
					ex_wb_trap_is_interrupt <= 1'b0;
					ex_wb_trap_cause <= mem_fault_is_store ? 64'd15 : 64'd13;
					ex_wb_trap_tval <= mem_addr;
					ex_wb_trap_pc <= mem_pc;
					ex_wb_priv <= mem_priv;
				end
				else if (mem_is_atomic && !mem_atomic_write_phase && !mem_atomic_is_lr) begin
					logic [31:0] old_word, new_word;
					old_word = select_word(dresp.data, mem_addr[2:0]);
					new_word = amo_w_result(mem_amo_op, old_word, mem_wdata[31:0]);
					mem_atomic_wb_data <= sext32(old_word);
					mem_atomic_write_phase <= 1'b1;
					mem_strobe <= make_store_mask(MSIZE4, mem_addr[2:0]);
					mem_wdata <= make_store_data(MSIZE4, mem_addr[2:0], {32'd0, new_word});
				end
				else begin
					mem_pending <= 1'b0;
					mem_is_load <= 1'b0;
					mem_is_store <= 1'b0;
					mem_is_atomic <= 1'b0;
					mem_atomic_write_phase <= 1'b0;
					mem_atomic_is_lr <= 1'b0;
					mem_atomic_is_sc <= 1'b0;
					mem_wen <= 1'b0;
					ex_wb_valid <= 1'b1;
					ex_wb_wen <= (mem_is_load || mem_is_atomic) ? mem_wen : 1'b0;
					ex_wb_is_load <= mem_is_load;
					ex_wb_is_store <= mem_is_store;
					ex_wb_is_atomic <= mem_is_atomic;
					ex_wb_rd <= mem_rd;
					ex_wb_data <= mem_is_atomic ?
						(mem_atomic_is_lr ? make_load_data(dresp.data, mem_addr[2:0], 8'd2) : mem_atomic_wb_data) :
						(mem_is_load ? make_load_data(dresp.data, mem_addr[2:0], mem_load_optype) : 64'd0);
					ex_wb_pc <= mem_pc;
					ex_wb_instr <= mem_instr;
					ex_wb_mem_addr <= mem_addr;
					ex_wb_mem_paddr <= dresp.paddr;
					ex_wb_load_optype <= mem_load_optype;
					ex_wb_store_data <= mem_wdata;
					ex_wb_store_mask <= mem_strobe;
					ex_wb_amo_op <= mem_amo_op;
					ex_wb_atomic_src_data <= mem_atomic_src_data;
					if (mem_is_atomic && mem_atomic_is_lr) begin
						reservation_valid <= 1'b1;
						reservation_addr <= {mem_addr[63:2], 2'b00};
					end
					else if (mem_is_atomic && mem_atomic_is_sc) begin
						reservation_valid <= 1'b0;
					end
					else if (mem_is_store && reservation_valid && ({mem_addr[63:2], 2'b00} == reservation_addr)) begin
						reservation_valid <= 1'b0;
					end
				end
			end
			else if (id_go_mem) begin
				mem_pending <= 1'b1;
				mem_is_load <= id_is_load || (id_is_amo && !id_is_sc);
				mem_is_store <= id_is_store || (id_is_amo && !id_is_lr);
				mem_is_atomic <= id_is_amo;
				mem_atomic_write_phase <= id_is_sc;
				mem_atomic_is_lr <= id_is_lr;
				mem_atomic_is_sc <= id_is_sc;
				mem_wen <= id_wen;
				mem_rd <= rd;
				mem_pc <= if_id_pc;
				mem_instr <= if_id_instr;
				mem_addr <= id_mem_addr;
				mem_size <= id_mem_size;
				mem_strobe <= (id_is_store || id_is_sc) ? id_store_mask : 8'd0;
				mem_wdata <= (id_is_store || id_is_sc) ? id_store_data : rs2_val;
				mem_load_optype <= id_load_optype;
				mem_amo_op <= id_amo_op;
				mem_atomic_wb_data <= id_is_sc ? 64'd0 : 64'd0;
				mem_atomic_src_data <= rs2_val;
				mem_priv <= current_priv;
			end
			else if (id_fire) begin
				ex_wb_valid <= !id_trap || id_is_ecall;
				ex_wb_wen <= id_wen && !id_trap;
				ex_wb_rd <= rd;
				if (id_is_lui) ex_wb_data <= imm_u;
				else if (id_is_auipc) ex_wb_data <= if_id_pc + imm_u;
				else if (id_is_jal || id_is_jalr) ex_wb_data <= if_id_pc + 64'd4;
				else if (id_is_csr) ex_wb_data <= id_csr_rdata;
				else if (id_is_sc) ex_wb_data <= 64'd1;
				else ex_wb_data <= ex_res;
				ex_wb_pc <= if_id_pc;
				ex_wb_instr <= if_id_instr;
				ex_wb_is_csr <= id_is_csr && !id_trap;
				ex_wb_csr_wen <= id_csr_wen && !id_trap;
				ex_wb_csr_addr <= id_csr_addr;
				ex_wb_csr_wdata <= id_csr_wdata;
				ex_wb_is_mret <= id_is_mret && !id_trap;
				ex_wb_is_sret <= id_is_sret && !id_trap;
				ex_wb_trap_valid <= id_trap;
				ex_wb_trap_is_interrupt <= id_trap_is_interrupt;
				ex_wb_trap_cause <= id_trap_cause;
				ex_wb_trap_tval <= id_trap_tval;
				ex_wb_trap_pc <= if_id_pc;
				ex_wb_priv <= current_priv;
				if (id_is_sc && !id_trap) begin
					reservation_valid <= 1'b0;
				end
			end
		end
	end

	logic wb_valid, wb_wen, wb_is_load, wb_is_store, wb_is_atomic;
	logic [4:0] wb_rd;
	word_t wb_data;
	addr_t wb_pc, wb_mem_addr, wb_mem_paddr;
	u32 wb_instr;
	logic [7:0] wb_load_optype;
	word_t wb_store_data;
	strobe_t wb_store_mask;
	logic [4:0] wb_amo_op;
	word_t wb_atomic_src_data;
	logic wb_is_csr, wb_csr_wen;
	csr_addr_t wb_csr_addr;
	word_t wb_csr_wdata;
	logic wb_is_mret, wb_is_sret;
	logic wb_trap_valid, wb_trap_is_interrupt;
	word_t wb_trap_cause, wb_trap_tval;
	addr_t wb_trap_pc;
	logic [1:0] wb_priv;

	assign wb_valid = ex_wb_valid;
	assign wb_wen = ex_wb_wen;
	assign wb_is_load = ex_wb_is_load;
	assign wb_is_store = ex_wb_is_store;
	assign wb_is_atomic = ex_wb_is_atomic;
	assign wb_rd = ex_wb_rd;
	assign wb_data = ex_wb_data;
	assign wb_pc = ex_wb_pc;
	assign wb_instr = ex_wb_instr;
	assign wb_mem_addr = ex_wb_mem_addr;
	assign wb_mem_paddr = ex_wb_mem_paddr;
	assign wb_load_optype = ex_wb_load_optype;
	assign wb_store_data = ex_wb_store_data;
	assign wb_store_mask = ex_wb_store_mask;
	assign wb_amo_op = ex_wb_amo_op;
	assign wb_atomic_src_data = ex_wb_atomic_src_data;
	assign wb_is_csr = ex_wb_is_csr;
	assign wb_csr_wen = ex_wb_csr_wen;
	assign wb_csr_addr = ex_wb_csr_addr;
	assign wb_csr_wdata = ex_wb_csr_wdata;
	assign wb_is_mret = ex_wb_is_mret;
	assign wb_is_sret = ex_wb_is_sret;
	assign wb_trap_valid = ex_wb_trap_valid;
	assign wb_trap_is_interrupt = ex_wb_trap_is_interrupt;
	assign wb_trap_cause = ex_wb_trap_cause;
	assign wb_trap_tval = ex_wb_trap_tval;
	assign wb_trap_pc = ex_wb_trap_pc;
	assign wb_priv = ex_wb_priv;
	assign rs1_val = (rs1 == 5'd0) ? 64'd0 :
		((wb_valid && wb_wen && (wb_rd == rs1)) ? wb_data : gpr[rs1]);
	assign rs2_val = (rs2 == 5'd0) ? 64'd0 :
		((wb_valid && wb_wen && (wb_rd == rs2)) ? wb_data : gpr[rs2]);
	assign if_flush = wb_trap_valid ||
		(if_id_valid && id_consume &&
			(id_redirect || id_is_csr || id_is_fence || id_is_sfence_vma));

	word_t mstatus_mtrap_next, mstatus_strap_next, mstatus_mret_next, mstatus_sret_next;
	logic [1:0] trap_priv_next, mret_priv_next, sret_priv_next;
	logic wb_trap_to_s;
	assign wb_trap_to_s = wb_trap_valid && trap_delegated(wb_trap_is_interrupt, wb_trap_cause, wb_priv);
	assign trap_priv_next = wb_trap_to_s ? PRIV_S : PRIV_M;
	assign mstatus_mtrap_next = (csr_mstatus & ~(MSTATUS_MPP_MASK | MSTATUS_MPIE_BIT | MSTATUS_MIE_BIT)) |
		(csr_mstatus[3] ? MSTATUS_MPIE_BIT : 64'd0) | {51'd0, wb_priv, 11'd0};
	assign mstatus_strap_next = (csr_mstatus & ~(MSTATUS_SPP_BIT | MSTATUS_SPIE_BIT | MSTATUS_SIE_BIT)) |
		(csr_mstatus[1] ? MSTATUS_SPIE_BIT : 64'd0) |
		((wb_priv == PRIV_S) ? MSTATUS_SPP_BIT : 64'd0);
	assign mret_priv_next = (csr_mstatus[12:11] == PRIV_M) ? PRIV_M :
		((csr_mstatus[12:11] == PRIV_S) ? PRIV_S : PRIV_U);
	assign sret_priv_next = csr_mstatus[8] ? PRIV_S : PRIV_U;
	assign mstatus_mret_next = (csr_mstatus & ~(MSTATUS_MPP_MASK | MSTATUS_MPIE_BIT | MSTATUS_MIE_BIT | MSTATUS_XS_MASK |
		((csr_mstatus[12:11] == PRIV_M) ? 64'd0 : MSTATUS_MPRV_BIT))) |
		MSTATUS_MPIE_BIT | (csr_mstatus[7] ? MSTATUS_MIE_BIT : 64'd0);
	assign mstatus_sret_next = (csr_mstatus & ~(MSTATUS_SPP_BIT | MSTATUS_SPIE_BIT | MSTATUS_SIE_BIT | MSTATUS_MPRV_BIT)) |
		MSTATUS_SPIE_BIT | (csr_mstatus[5] ? MSTATUS_SIE_BIT : 64'd0);
	assign fetch_priv = wb_trap_valid ? trap_priv_next :
		((wb_valid && wb_is_mret) ? mret_priv_next :
		((wb_valid && wb_is_sret) ? sret_priv_next : current_priv));

	always_ff @(posedge clk) begin
		if (reset) begin
			csr_mstatus <= '0;
			csr_mtvec <= '0;
			csr_mip <= '0;
			csr_mie <= '0;
			csr_mscratch <= '0;
			csr_mcause <= '0;
			csr_mtval <= '0;
			csr_mepc <= '0;
			csr_mcycle <= '0;
			csr_minstret <= '0;
			csr_satp <= '0;
			csr_stvec <= '0;
			csr_sscratch <= '0;
			csr_sepc <= '0;
			csr_scause <= '0;
			csr_stval <= '0;
			csr_medeleg <= '0;
			csr_mideleg <= '0;
			csr_mcounteren <= '0;
			csr_scounteren <= '0;
			for (int entry = 0; entry < PMP_ENTRIES; entry += 1) begin
				csr_pmpaddr[entry] <= '0;
			end
			csr_pmpcfg0 <= '0;
			csr_mhartid <= '0;
			current_priv <= PRIV_M;
		end
		else begin
			csr_mcycle <= csr_mcycle + 64'd1;
			csr_minstret <= csr_minstret + ((wb_valid && !wb_trap_valid) ? 64'd1 : 64'd0);
			csr_mhartid <= '0;
			if (wb_trap_valid) begin
				if (wb_trap_to_s) begin
					csr_mstatus <= mstatus_strap_next & MSTATUS_MASK;
					csr_sepc <= wb_trap_pc;
					csr_scause <= {wb_trap_is_interrupt, wb_trap_cause[62:0]};
					csr_stval <= wb_trap_tval;
					current_priv <= PRIV_S;
				end
				else begin
					csr_mstatus <= mstatus_mtrap_next & MSTATUS_MASK;
					csr_mepc <= wb_trap_pc;
					csr_mcause <= {wb_trap_is_interrupt, wb_trap_cause[62:0]};
					csr_mtval <= wb_trap_tval;
					current_priv <= PRIV_M;
				end
			end
			else if (wb_valid && wb_is_mret) begin
				csr_mstatus <= mstatus_mret_next & MSTATUS_MASK;
				current_priv <= mret_priv_next;
			end
			else if (wb_valid && wb_is_sret) begin
				csr_mstatus <= mstatus_sret_next & MSTATUS_MASK;
				current_priv <= sret_priv_next;
			end
			else if (wb_valid && wb_is_csr && wb_csr_wen) begin
				unique case (wb_csr_addr)
					CSR_MSTATUS:  csr_mstatus <= wb_csr_wdata & MSTATUS_MASK;
					CSR_SSTATUS:  csr_mstatus <= (csr_mstatus & ~(SSTATUS_MASK & MSTATUS_MASK)) |
						(wb_csr_wdata & SSTATUS_MASK & MSTATUS_MASK);
					CSR_MTVEC:    csr_mtvec <= wb_csr_wdata & MTVEC_MASK;
					CSR_STVEC:    csr_stvec <= wb_csr_wdata & MTVEC_MASK;
					CSR_MIP:      csr_mip <= wb_csr_wdata & MIP_MASK;
					CSR_SIP:      csr_mip <= (csr_mip & ~MIP_S_MASK) | (wb_csr_wdata & MIP_S_MASK);
					CSR_MIE:      csr_mie <= wb_csr_wdata;
					CSR_SIE:      csr_mie <= (csr_mie & ~MIP_S_MASK) | (wb_csr_wdata & MIP_S_MASK);
					CSR_MCOUNTEREN: csr_mcounteren <= wb_csr_wdata & COUNTEREN_MASK;
					CSR_SCOUNTEREN: csr_scounteren <= wb_csr_wdata & COUNTEREN_MASK;
					CSR_MSCRATCH: csr_mscratch <= wb_csr_wdata;
					CSR_SSCRATCH: csr_sscratch <= wb_csr_wdata;
					CSR_MEPC:     csr_mepc <= wb_csr_wdata;
					CSR_SEPC:     csr_sepc <= wb_csr_wdata;
					CSR_MCAUSE:   csr_mcause <= wb_csr_wdata;
					CSR_SCAUSE:   csr_scause <= wb_csr_wdata;
					CSR_MTVAL:    csr_mtval <= wb_csr_wdata;
					CSR_STVAL:    csr_stval <= wb_csr_wdata;
					CSR_SATP:     csr_satp <= wb_csr_wdata;
					CSR_MCYCLE:   csr_mcycle <= wb_csr_wdata;
					CSR_MINSTRET: csr_minstret <= wb_csr_wdata;
					CSR_MEDELEG:  csr_medeleg <= wb_csr_wdata & MEDELEG_MASK;
					CSR_MIDELEG:  csr_mideleg <= wb_csr_wdata & MIDELEG_MASK;
					CSR_PMPADDR0: csr_pmpaddr[0] <= wb_csr_wdata;
					CSR_PMPADDR1: csr_pmpaddr[1] <= wb_csr_wdata;
					CSR_PMPADDR2: csr_pmpaddr[2] <= wb_csr_wdata;
					CSR_PMPADDR3: csr_pmpaddr[3] <= wb_csr_wdata;
					CSR_PMPADDR4: csr_pmpaddr[4] <= wb_csr_wdata;
					CSR_PMPADDR5: csr_pmpaddr[5] <= wb_csr_wdata;
					CSR_PMPADDR6: csr_pmpaddr[6] <= wb_csr_wdata;
					CSR_PMPADDR7: csr_pmpaddr[7] <= wb_csr_wdata;
					CSR_PMPCFG0:  csr_pmpcfg0 <= wb_csr_wdata;
					default: begin
					end
				endcase
			end
		end
	end

	logic dt_valid, dt_wen, dt_is_load, dt_is_store, dt_is_atomic;
	addr_t dt_pc, dt_mem_addr, dt_mem_paddr;
	u32 dt_instr;
	logic [7:0] dt_wdest, dt_load_optype;
	word_t dt_wdata, dt_store_data;
	strobe_t dt_store_mask;
	logic [4:0] dt_amo_op;
	word_t dt_atomic_src_data;
	addr_t dt_store_addr;
	logic store_ev_valid;
	addr_t store_ev_addr;
	word_t store_ev_data;
	strobe_t store_ev_mask;
	logic dt_skip;

	always_ff @(posedge clk) begin
		if (reset) begin
			dt_valid <= 1'b0;
			dt_wen <= 1'b0;
			dt_is_load <= 1'b0;
			dt_is_store <= 1'b0;
			dt_is_atomic <= 1'b0;
			dt_pc <= '0;
			dt_mem_addr <= '0;
			dt_mem_paddr <= '0;
			dt_instr <= '0;
			dt_wdest <= '0;
			dt_load_optype <= '0;
			dt_wdata <= '0;
			dt_store_data <= '0;
			dt_store_mask <= '0;
			dt_amo_op <= '0;
			dt_atomic_src_data <= '0;
			store_ev_valid <= 1'b0;
			store_ev_addr <= '0;
			store_ev_data <= '0;
			store_ev_mask <= '0;
		end
		else begin
			dt_valid <= wb_valid;
			dt_pc <= wb_pc;
			dt_mem_addr <= wb_mem_addr;
			dt_mem_paddr <= wb_is_load || wb_is_store ? wb_mem_paddr : wb_mem_addr;
			dt_instr <= wb_instr;
			dt_wen <= wb_wen && (wb_rd != 5'd0);
			dt_is_load <= wb_is_load;
			dt_is_store <= wb_is_store;
			dt_is_atomic <= wb_is_atomic;
			dt_wdest <= {3'b0, wb_rd};
			dt_load_optype <= wb_load_optype;
			dt_wdata <= wb_data;
			dt_store_data <= wb_store_data;
			dt_store_mask <= wb_store_mask;
			dt_amo_op <= wb_amo_op;
			dt_atomic_src_data <= wb_atomic_src_data;
			store_ev_valid <= dt_valid && dt_is_store && !dt_is_atomic && !dt_skip;
			store_ev_addr <= dt_store_addr;
			store_ev_data <= dt_store_data;
			store_ev_mask <= dt_store_mask;
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

	assign dt_store_addr = {dt_mem_paddr[63:3], 3'b000};
	assign dt_skip = (dt_is_load || dt_is_store) && (dt_mem_paddr[31] == 1'b0);

`ifdef VERILATOR
	DifftestArchEvent DifftestArchEvent(
		.clock              (clk),
		.coreid             (csr_mhartid[7:0]),
		.intrNO             (32'd0),
		.cause              (32'd0),
		.exceptionPC        (dt_pc)
	);

	DifftestInstrCommit DifftestInstrCommit(
		.clock              (clk),
		.coreid             (csr_mhartid[7:0]),
		.index              (0),
		.valid              (dt_valid),
		.pc                 (dt_pc),
		.instr              (dt_instr),
		.skip               (dt_skip),
		.isRVC              (0),
		.scFailed           (0),
		.wen                (dt_wen),
		.wdest              (dt_wdest),
		.wdata              (dt_wdata)
	);

	DifftestArchIntRegState DifftestArchIntRegState (
		.clock              (clk),
		.coreid             (csr_mhartid[7:0]),
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

	DifftestStoreEvent DifftestStoreEvent(
		.clock              (clk),
		.coreid             (csr_mhartid[7:0]),
		.index              (0),
		.valid              (store_ev_valid),
		.storeAddr          (store_ev_addr),
		.storeData          (store_ev_data),
		.storeMask          (store_ev_mask)
	);

	DifftestLoadEvent DifftestLoadEvent(
		.clock              (clk),
		.coreid             (csr_mhartid[7:0]),
		.index              (0),
		.valid              (dt_valid && dt_is_load && !dt_skip),
		.paddr              (dt_mem_paddr),
		.opType             (dt_load_optype),
		.fuType             (dt_is_atomic ? 8'h0f : 8'h0c)
	);

	DifftestAtomicEvent DifftestAtomicEvent(
		.clock              (clk),
		.coreid             (csr_mhartid[7:0]),
		.atomicResp         (dt_valid && dt_is_atomic && !dt_skip),
		.atomicAddr         (dt_mem_paddr),
		.atomicData         (dt_atomic_src_data),
		.atomicMask         (make_store_mask(MSIZE4, dt_mem_addr[2:0])),
		.atomicFuop         (amo_fuop(dt_amo_op)),
		.atomicOut          (dt_wdata)
	);

	DifftestTrapEvent DifftestTrapEvent(
		.clock              (clk),
		.coreid             (csr_mhartid[7:0]),
		.valid              (trap_valid),
		.code               (trap_code),
		.pc                 (dt_pc),
		.cycleCnt           (cyc_cnt),
		.instrCnt           (instr_cnt)
	);

	DifftestCSRState DifftestCSRState(
		.clock              (clk),
		.coreid             (csr_mhartid[7:0]),
		.priviledgeMode     (current_priv),
		.mstatus            (csr_mstatus),
		.sstatus            (csr_mstatus & SSTATUS_MASK),
		.mepc               (csr_mepc),
		.sepc               (csr_sepc),
		.mtval              (csr_mtval),
		.stval              (csr_stval),
		.mtvec              (csr_mtvec),
		.stvec              (csr_stvec),
		.mcause             (csr_mcause),
		.scause             (csr_scause),
		.satp               (csr_satp),
		.mip                (mip_value & MIP_MASK),
		.mie                (csr_mie),
		.mscratch           (csr_mscratch),
		.sscratch           (csr_sscratch),
		.mideleg            (csr_mideleg),
		.medeleg            (csr_medeleg)
	);
`endif
endmodule
`endif
