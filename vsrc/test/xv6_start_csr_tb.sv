`ifdef VERILATOR
`include "include/common.sv"
`include "include/csr.sv"
`include "src/core.sv"
`endif

module xv6_start_csr_tb
    import common::*;
    import csr_pkg::*;
;
    localparam logic [1:0] PRIV_S = 2'b01;
    localparam addr_t S_PC = 64'h0000_0000_0000_0040;
    localparam word_t S_INTERRUPT_MASK = 64'h0000_0000_0000_0222;

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

    function automatic u32 instr_shift(
        input logic [5:0] shamt,
        input u5 rs1,
        input u3 funct3,
        input u5 rd
    );
        instr_shift = {6'b000000, shamt, rs1, funct3, rd, 7'b0010011};
    endfunction

    function automatic u32 addi(input u5 rd, input u5 rs1, input logic signed [11:0] imm);
        addi = instr_i(imm, rs1, 3'b000, rd, 7'b0010011);
    endfunction

    function automatic u32 lui(input u5 rd, input logic [19:0] imm);
        lui = {imm, rd, 7'b0110111};
    endfunction

    function automatic u32 srli(input u5 rd, input u5 rs1, input logic [5:0] shamt);
        srli = instr_shift(shamt, rs1, 3'b101, rd);
    endfunction

    function automatic u32 csrr(input u5 rd, input u12 csr);
        csrr = {csr, 5'd0, 3'b010, rd, 7'b1110011};
    endfunction

    function automatic u32 csrw(input u12 csr, input u5 rs1);
        csrw = {csr, rs1, 3'b001, 5'd0, 7'b1110011};
    endfunction

    function automatic u32 instr_at(input addr_t addr);
        unique case (addr)
            PCINIT + 64'h00: instr_at = csrw(CSR_SATP, 5'd0);
            PCINIT + 64'h04: instr_at = addi(5'd1, 5'd0, -12'sd1);
            PCINIT + 64'h08: instr_at = csrw(CSR_MEDELEG, 5'd1);
            PCINIT + 64'h0c: instr_at = csrw(CSR_MIDELEG, 5'd1);
            PCINIT + 64'h10: instr_at = addi(5'd1, 5'd0, 12'h222);
            PCINIT + 64'h14: instr_at = csrw(CSR_SIE, 5'd1);
            PCINIT + 64'h18: instr_at = addi(5'd1, 5'd0, -12'sd1);
            PCINIT + 64'h1c: instr_at = srli(5'd1, 5'd1, 6'd10);
            PCINIT + 64'h20: instr_at = csrw(CSR_PMPADDR0, 5'd1);
            PCINIT + 64'h24: instr_at = addi(5'd1, 5'd0, 12'h00f);
            PCINIT + 64'h28: instr_at = csrw(CSR_PMPCFG0, 5'd1);
            PCINIT + 64'h2c: instr_at = addi(5'd1, 5'd0, -12'sd1);
            PCINIT + 64'h30: instr_at = csrw(CSR_MENVCFG, 5'd1);
            PCINIT + 64'h34: instr_at = addi(5'd1, 5'd0, 12'h002);
            PCINIT + 64'h38: instr_at = csrw(CSR_MCOUNTEREN, 5'd1);
            PCINIT + 64'h3c: instr_at = csrr(5'd1, CSR_TIME);
            PCINIT + 64'h40: instr_at = addi(5'd1, 5'd1, 12'sd2047);
            PCINIT + 64'h44: instr_at = csrw(CSR_STIMECMP, 5'd1);
            PCINIT + 64'h48: instr_at = addi(5'd1, 5'd0, 12'h040);
            PCINIT + 64'h4c: instr_at = csrw(CSR_MEPC, 5'd1);
            PCINIT + 64'h50: instr_at = lui(5'd1, 20'h00001);
            PCINIT + 64'h54: instr_at = addi(5'd1, 5'd1, -12'sd2048);
            PCINIT + 64'h58: instr_at = csrw(CSR_MSTATUS, 5'd1);
            PCINIT + 64'h5c: instr_at = 32'h3020_0073;
            S_PC:            instr_at = csrr(5'd6, CSR_STIMECMP);
            S_PC + 64'h04:   instr_at = addi(5'd5, 5'd0, 12'h001);
            default:         instr_at = addi(5'd0, 5'd0, 12'h000);
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

    initial begin
        clk = 1'b0;
        reset = 1'b1;
        trint = 1'b0;
        swint = 1'b0;
        exint = 1'b0;
        repeat (3) @(posedge clk);
        reset = 1'b0;

        for (int cycle = 0; cycle < 220; cycle += 1) begin
            @(posedge clk);
            #1;
            if (dut.gpr[5] == 64'd1) begin
                if (priv_mode != PRIV_S) begin
                    $fatal(1, "xv6 start sequence did not enter S-mode");
                end
                if (dut.csr_satp != 64'd0) begin
                    $fatal(1, "xv6 start satp expected Bare: %h", dut.csr_satp);
                end
                if (dut.csr_medeleg != MEDELEG_MASK) begin
                    $fatal(1, "medeleg mask mismatch: %h expected %h", dut.csr_medeleg, MEDELEG_MASK);
                end
                if (dut.csr_mideleg != MIDELEG_MASK) begin
                    $fatal(1, "mideleg mask mismatch: %h expected %h", dut.csr_mideleg, MIDELEG_MASK);
                end
                if ((dut.csr_mie & S_INTERRUPT_MASK) != S_INTERRUPT_MASK) begin
                    $fatal(1, "SIE delegated interrupt bits missing: mie=%h", dut.csr_mie);
                end
                if (dut.csr_pmpaddr[0] != 64'h003f_ffff_ffff_ffff) begin
                    $fatal(1, "pmpaddr0 mismatch: %h", dut.csr_pmpaddr[0]);
                end
                if (dut.csr_pmpcfg0[7:0] != 8'h0f) begin
                    $fatal(1, "pmpcfg0 mismatch: %h", dut.csr_pmpcfg0[7:0]);
                end
                if (dut.csr_menvcfg != MENVCFG_STCE_BIT) begin
                    $fatal(1, "menvcfg.STCE not retained: %h", dut.csr_menvcfg);
                end
                if (dut.csr_mcounteren[1] != 1'b1) begin
                    $fatal(1, "mcounteren.TM not enabled: %h", dut.csr_mcounteren);
                end
                if (dut.gpr[6] != dut.csr_stimecmp) begin
                    $fatal(1, "S-mode stimecmp read mismatch: gpr=%h csr=%h",
                        dut.gpr[6], dut.csr_stimecmp);
                end
                if (dut.csr_mcause == 64'd2) begin
                    $fatal(1, "unexpected illegal instruction during xv6 start CSR sequence");
                end
                $display("xv6_start_satp_bare [OK]");
                $display("xv6_start_delegation [OK]");
                $display("xv6_start_pmp_all_memory [OK]");
                $display("xv6_start_sstc_counter_setup [OK]");
                $display("xv6 start CSR directed test passed.");
                $finish;
            end
        end

        $fatal(1, "timed out waiting for xv6 start CSR sequence");
    end

    `UNUSED_OK({satp, mstatus, dreq, if_flush});
endmodule
