`ifdef VERILATOR
`include "include/common.sv"
`include "include/csr.sv"
`include "src/core.sv"
`endif

module timervec_ssip_tb
    import common::*;
    import csr_pkg::*;
;
    localparam logic [1:0] PRIV_M = 2'b11;
    localparam logic [1:0] PRIV_S = 2'b01;
    localparam addr_t S_PC = 64'h0000_0000_0000_0040;
    localparam addr_t M_TIMER_HANDLER = 64'h0000_0000_0000_0080;
    localparam addr_t S_SOFT_HANDLER = 64'h0000_0000_0000_0100;
    localparam word_t M_TIMER_CAUSE = 64'h8000_0000_0000_0007;
    localparam word_t S_SOFT_CAUSE = 64'h8000_0000_0000_0001;
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
    logic saw_m_timer;

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

    function automatic u32 lui(input u5 rd, input logic [19:0] imm);
        lui = {imm, rd, 7'b0110111};
    endfunction

    function automatic u32 csrw(input u12 csr, input u5 rs1);
        csrw = {csr, rs1, 3'b001, 5'd0, 7'b1110011};
    endfunction

    function automatic u32 instr_at(input addr_t addr);
        unique case (addr)
            PCINIT + 64'h00: instr_at = addi(5'd1, 5'd0, 12'sh002);
            PCINIT + 64'h04: instr_at = csrw(CSR_MIDELEG, 5'd1);
            PCINIT + 64'h08: instr_at = addi(5'd1, 5'd0, 12'sh082);
            PCINIT + 64'h0c: instr_at = csrw(CSR_MIE, 5'd1);
            PCINIT + 64'h10: instr_at = addi(5'd1, 5'd0, 12'sh080);
            PCINIT + 64'h14: instr_at = csrw(CSR_MTVEC, 5'd1);
            PCINIT + 64'h18: instr_at = addi(5'd1, 5'd0, 12'sh100);
            PCINIT + 64'h1c: instr_at = csrw(CSR_STVEC, 5'd1);
            PCINIT + 64'h20: instr_at = addi(5'd1, 5'd0, 12'sh040);
            PCINIT + 64'h24: instr_at = csrw(CSR_MEPC, 5'd1);
            PCINIT + 64'h28: instr_at = lui(5'd1, 20'h00001);
            PCINIT + 64'h2c: instr_at = addi(5'd1, 5'd1, 12'sh802);
            PCINIT + 64'h30: instr_at = csrw(CSR_MSTATUS, 5'd1);
            PCINIT + 64'h34: instr_at = MRET;
            S_PC:            instr_at = addi(5'd6, 5'd0, 12'sh001);
            M_TIMER_HANDLER: instr_at = addi(5'd1, 5'd0, 12'sh002);
            M_TIMER_HANDLER + 64'h04: instr_at = csrw(CSR_SIP, 5'd1);
            M_TIMER_HANDLER + 64'h08: instr_at = MRET;
            S_SOFT_HANDLER:  instr_at = addi(5'd5, 5'd0, 12'sh001);
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

    initial begin
        clk = 1'b0;
        reset = 1'b1;
        trint = 1'b1;
        swint = 1'b0;
        exint = 1'b0;
        saw_m_timer = 1'b0;
        repeat (3) @(posedge clk);
        reset = 1'b0;

        for (int cycle = 0; cycle < 180; cycle += 1) begin
            @(posedge clk);
            if ((priv_mode == PRIV_M) && (dut.csr_mcause == M_TIMER_CAUSE) &&
                (dut.csr_mepc == S_PC)) begin
                saw_m_timer = 1'b1;
                trint = 1'b0;
            end
            if (dut.gpr[5] == 64'd1) begin
                if (!saw_m_timer) begin
                    $fatal(1, "S software interrupt happened before M timer interrupt");
                end
                if (priv_mode != PRIV_S) begin
                    $fatal(1, "S software handler executed outside S-mode");
                end
                if (dut.gpr[6] != 64'd0) begin
                    $fatal(1, "interrupted S instruction committed before SSIP trap");
                end
                if (dut.csr_scause != S_SOFT_CAUSE) begin
                    $fatal(1, "expected S software interrupt, scause=%h", dut.csr_scause);
                end
                if (dut.csr_sepc != S_PC) begin
                    $fatal(1, "expected S software sepc=%h, got %h", S_PC, dut.csr_sepc);
                end
                $display("timervec_mtimer_to_mmode [OK]");
                $display("timervec_posts_ssip [OK]");
                $display("timervec_ssip_to_smode [OK]");
                $display("Timervec SSIP directed test passed.");
                $finish;
            end
        end

        $fatal(1, "timed out waiting for timervec SSIP handoff");
    end

    `UNUSED_OK({satp, mstatus, dreq, if_flush});
endmodule
