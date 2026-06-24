`ifdef VERILATOR
`include "include/common.sv"
`include "include/csr.sv"
`include "src/core.sv"
`endif

module sfence_vma_tb
    import common::*;
    import csr_pkg::*;
;
    localparam logic [1:0] PRIV_M = 2'b11;
    localparam addr_t U_PC = 64'h0000_0000_0000_0040;
    localparam addr_t TRAP_PC = 64'h0000_0000_0000_0100;
    localparam u32 SFENCE_VMA = 32'h1200_0073;
    localparam u32 MRET = 32'h3020_0073;

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
    logic if_resp_pending;
    logic saw_m_sfence_flush;

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

    function automatic u32 csrw(input u12 csr, input u5 rs1);
        csrw = {csr, rs1, 3'b001, 5'd0, 7'b1110011};
    endfunction

    function automatic u32 instr_at(input addr_t addr);
        unique case (addr)
            PCINIT + 64'h00: instr_at = addi(5'd1, 5'd0, 12'sh100);
            PCINIT + 64'h04: instr_at = csrw(CSR_MTVEC, 5'd1);
            PCINIT + 64'h08: instr_at = SFENCE_VMA;
            PCINIT + 64'h0c: instr_at = addi(5'd5, 5'd0, 12'sh001);
            PCINIT + 64'h10: instr_at = addi(5'd1, 5'd0, 12'sh040);
            PCINIT + 64'h14: instr_at = csrw(CSR_MEPC, 5'd1);
            PCINIT + 64'h18: instr_at = csrw(CSR_MSTATUS, 5'd0);
            PCINIT + 64'h1c: instr_at = MRET;
            U_PC:            instr_at = SFENCE_VMA;
            U_PC + 64'h04:   instr_at = addi(5'd6, 5'd0, 12'sh001);
            TRAP_PC:         instr_at = addi(5'd0, 5'd0, 12'sh000);
            default:         instr_at = addi(5'd0, 5'd0, 12'sh000);
        endcase
    endfunction

    always #5 clk = ~clk;

    always_ff @(posedge clk) begin
        if (reset) begin
            iresp <= '0;
            if_req_q <= '0;
            if_resp_pending <= 1'b0;
            saw_m_sfence_flush <= 1'b0;
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

            if ((priv_mode == PRIV_M) && dut.if_id_valid &&
                (dut.if_id_instr == SFENCE_VMA) && if_flush) begin
                saw_m_sfence_flush <= 1'b1;
            end
        end
    end

    always_comb begin
        dresp = '0;
        dresp.addr_ok = dreq.valid;
        dresp.paddr = dreq.addr;
    end

    initial begin
        clk = 1'b0;
        reset = 1'b1;
        trint = 1'b0;
        swint = 1'b0;
        exint = 1'b0;
        repeat (3) @(posedge clk);
        reset = 1'b0;

        for (int cycle = 0; cycle < 120; cycle += 1) begin
            @(posedge clk);
            if ((priv_mode == PRIV_M) && (dut.csr_mcause == 64'd2) &&
                (dut.csr_mepc == U_PC)) begin
                if (!saw_m_sfence_flush) begin
                    $fatal(1, "M-mode sfence.vma did not trigger if_flush");
                end
                $display("sfence_vma_mmode_flush [OK]");
                $display("sfence_vma_umode_illegal [OK]");
                $display("SFENCE.VMA directed test passed.");
                $finish;
            end
        end

        $fatal(1, "timed out waiting for U-mode sfence.vma illegal trap");
    end

    `UNUSED_OK({satp, mstatus, dreq});
endmodule
