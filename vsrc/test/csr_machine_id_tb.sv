`ifdef VERILATOR
`include "include/common.sv"
`include "include/csr.sv"
`include "src/core.sv"
`endif

module csr_machine_id_tb
    import common::*;
    import csr_pkg::*;
;
    localparam logic [1:0] PRIV_M = 2'b11;
    localparam addr_t TRAP_PC = 64'h0000_0000_0000_0100;
    localparam word_t EXPECT_MISA = 64'h8000_0000_0014_1101;

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

    function automatic u32 csrr(input u5 rd, input u12 csr);
        csrr = {csr, 5'd0, 3'b010, rd, 7'b1110011};
    endfunction

    function automatic u32 csrw(input u12 csr, input u5 rs1);
        csrw = {csr, rs1, 3'b001, 5'd0, 7'b1110011};
    endfunction

    function automatic u32 instr_at(input addr_t addr);
        unique case (addr)
            PCINIT + 64'h00: instr_at = csrr(5'd5, CSR_MVENDORID);
            PCINIT + 64'h04: instr_at = csrr(5'd6, CSR_MARCHID);
            PCINIT + 64'h08: instr_at = csrr(5'd7, CSR_MIMPID);
            PCINIT + 64'h0c: instr_at = csrr(5'd8, CSR_MHARTID);
            PCINIT + 64'h10: instr_at = csrr(5'd10, CSR_MISA);
            PCINIT + 64'h14: instr_at = addi(5'd1, 5'd0, 12'sh001);
            PCINIT + 64'h18: instr_at = csrw(CSR_MISA, 5'd1);
            PCINIT + 64'h1c: instr_at = csrr(5'd11, CSR_MISA);
            PCINIT + 64'h20: instr_at = addi(5'd1, 5'd0, 12'sh100);
            PCINIT + 64'h24: instr_at = csrw(CSR_MTVEC, 5'd1);
            PCINIT + 64'h28: instr_at = addi(5'd1, 5'd0, 12'sh001);
            PCINIT + 64'h2c: instr_at = csrw(CSR_MVENDORID, 5'd1);
            PCINIT + 64'h30: instr_at = addi(5'd9, 5'd0, 12'sh001);
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

    always_comb begin
        dresp = '0;
        dresp.addr_ok = dreq.valid;
        dresp.paddr = dreq.addr;
    end

    task automatic expect_machine_id_reads();
        if (dut.gpr[5] != 64'd0) begin
            $fatal(1, "mvendorid expected 0, got %h", dut.gpr[5]);
        end
        if (dut.gpr[6] != 64'd0) begin
            $fatal(1, "marchid expected 0, got %h", dut.gpr[6]);
        end
        if (dut.gpr[7] != 64'd0) begin
            $fatal(1, "mimpid expected 0, got %h", dut.gpr[7]);
        end
        if (dut.gpr[8] != 64'd0) begin
            $fatal(1, "mhartid expected 0, got %h", dut.gpr[8]);
        end
        if (dut.gpr[10] != EXPECT_MISA) begin
            $fatal(1, "misa expected %h, got %h", EXPECT_MISA, dut.gpr[10]);
        end
        if (dut.gpr[11] != EXPECT_MISA) begin
            $fatal(1, "misa write should be ignored: got %h", dut.gpr[11]);
        end
        if (dut.gpr[9] != 64'd0) begin
            $fatal(1, "instruction after read-only machine-id CSR write committed");
        end
        $display("csr_machine_id_reads [OK]");
        $display("csr_misa_read_write_ignored [OK]");
        $display("csr_machine_id_readonly_write_illegal [OK]");
    endtask

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
                (dut.csr_mepc == (PCINIT + 64'h2c))) begin
                expect_machine_id_reads();
                $display("CSR machine-id directed test passed.");
                $finish;
            end
        end

        $fatal(1, "timed out waiting for read-only machine-id CSR trap");
    end

    `UNUSED_OK({satp, mstatus, dreq, if_flush});
endmodule
