`ifdef VERILATOR
`include "include/common.sv"
`include "include/csr.sv"
`include "src/core.sv"
`endif

module mstatus_mprv_tb
    import common::*;
    import csr_pkg::*;
;
    localparam addr_t LOAD_PC = PCINIT + 64'h20;
    localparam addr_t TRAP_PC = 64'h0000_0000_0000_0100;
    localparam u32 NOP = 32'h0000_0013;

    localparam int CASE_MPRV_OFF = 0;
    localparam int CASE_MPRV_U = 1;

    logic clk, reset;
    ibus_req_t ireq;
    ibus_resp_t iresp;
    dbus_req_t dreq;
    dbus_resp_t dresp;
    logic if_flush;
    logic [1:0] priv_mode;
    word_t satp, mstatus;
    logic trint, swint, exint;
    addr_t if_req_q;
    dbus_req_t dreq_q;
    logic if_resp_pending, dresp_pending;
    int test_case;

    core dut(
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

    function automatic u32 instr_i(
        input logic signed [11:0] imm,
        input u5 rs1,
        input u3 funct3,
        input u5 rd,
        input u7 opcode
    );
        instr_i = {imm[11:0], rs1, funct3, rd, opcode};
    endfunction

    function automatic u32 addi(input u5 rd, input u5 rs1, input logic signed [11:0] imm);
        addi = instr_i(imm, rs1, 3'b000, rd, 7'b0010011);
    endfunction

    function automatic u32 ld(input u5 rd, input u5 rs1, input logic signed [11:0] imm);
        ld = instr_i(imm, rs1, 3'b011, rd, 7'b0000011);
    endfunction

    function automatic u32 lui(input u5 rd, input logic [19:0] imm);
        lui = {imm, rd, 7'b0110111};
    endfunction

    function automatic u32 csrw(input u12 csr, input u5 rs1);
        csrw = {csr, rs1, 3'b001, 5'd0, 7'b1110011};
    endfunction

    function automatic u32 instr_at(input addr_t addr);
        unique case (addr)
            PCINIT + 64'h00: instr_at = addi(5'd1, 5'd0, 12'sh100);
            PCINIT + 64'h04: instr_at = csrw(CSR_MTVEC, 5'd1);
            PCINIT + 64'h08: instr_at = csrw(CSR_PMPADDR0, 5'd0);
            PCINIT + 64'h0c: instr_at = addi(5'd1, 5'd0, 12'sh018);
            PCINIT + 64'h10: instr_at = csrw(CSR_PMPCFG0, 5'd1);
            PCINIT + 64'h14: begin
                if (test_case == CASE_MPRV_U) instr_at = lui(5'd1, 20'h00020);
                else instr_at = addi(5'd1, 5'd0, 12'sh000);
            end
            PCINIT + 64'h18: instr_at = csrw(CSR_MSTATUS, 5'd1);
            PCINIT + 64'h1c: instr_at = NOP;
            LOAD_PC:         instr_at = ld(5'd5, 5'd0, 12'sh000);
            PCINIT + 64'h24: instr_at = addi(5'd6, 5'd0, 12'sh001);
            TRAP_PC:         instr_at = NOP;
            default:         instr_at = NOP;
        endcase
    endfunction

    always #5 clk = ~clk;

    always_ff @(posedge clk) begin
        if (reset) begin
            iresp <= '0;
            if_req_q <= '0;
            if_resp_pending <= 1'b0;
        end
        else begin
            iresp <= '0;
            if (if_resp_pending) begin
                iresp.addr_ok <= 1'b1;
                iresp.data_ok <= 1'b1;
                iresp.data <= instr_at(if_req_q);
                iresp.page_fault <= 1'b0;
                if_resp_pending <= 1'b0;
            end
            else if (ireq.valid && !iresp.data_ok) begin
                if_req_q <= ireq.addr;
                if_resp_pending <= 1'b1;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            dresp <= '0;
            dreq_q <= '0;
            dresp_pending <= 1'b0;
        end
        else begin
            dresp <= '0;
            if (dresp_pending) begin
                dresp.addr_ok <= 1'b1;
                dresp.data_ok <= 1'b1;
                dresp.data <= 64'h1122_3344_5566_7788;
                dresp.paddr <= dreq_q.addr;
                dresp.page_fault <= 1'b0;
                dresp_pending <= 1'b0;
            end
            else if (dreq.valid && !dresp.data_ok) begin
                dreq_q <= dreq;
                dresp_pending <= 1'b1;
            end
        end
    end

    task automatic reset_core(input int which);
        test_case = which;
        reset = 1'b1;
        repeat (3) @(posedge clk);
        reset = 1'b0;
    endtask

    task automatic run_mprv_off();
        reset_core(CASE_MPRV_OFF);
        for (int cycle = 0; cycle < 160; cycle += 1) begin
            @(posedge clk);
            if (dut.gpr[6] == 64'd1) begin
                if (dut.gpr[5] != 64'h1122_3344_5566_7788) begin
                    $fatal(1, "M-mode load data mismatch with MPRV clear: %h", dut.gpr[5]);
                end
                if (dut.csr_mcause == 64'd5) begin
                    $fatal(1, "M-mode load unexpectedly trapped with MPRV clear");
                end
                $display("mstatus_mprv_clear_keeps_mmode_pmp [OK]");
                return;
            end
        end
        $fatal(1, "M-mode load with MPRV clear timed out");
    endtask

    task automatic run_mprv_u();
        reset_core(CASE_MPRV_U);
        for (int cycle = 0; cycle < 160; cycle += 1) begin
            @(posedge clk);
            if ((priv_mode == 2'b11) && (dut.csr_mcause == 64'd5) &&
                (dut.csr_mepc == LOAD_PC)) begin
                if (dut.gpr[6] != 64'd0) begin
                    $fatal(1, "post-load instruction executed after MPRV U access fault");
                end
                if (dut.csr_mtval != 64'd0) begin
                    $fatal(1, "MPRV U access fault mtval=%h expected 0", dut.csr_mtval);
                end
                $display("mstatus_mprv_u_pmp_load_fault [OK]");
                return;
            end
        end
        $fatal(1, "MPRV U load did not trap as a PMP load access fault");
    endtask

    initial begin
        clk = 1'b0;
        reset = 1'b1;
        trint = 1'b0;
        swint = 1'b0;
        exint = 1'b0;
        test_case = CASE_MPRV_OFF;

        run_mprv_off();
        run_mprv_u();

        $display("mstatus MPRV directed test passed.");
        $finish;
    end

    `UNUSED_OK({satp, mstatus, dreq, if_flush});
endmodule
