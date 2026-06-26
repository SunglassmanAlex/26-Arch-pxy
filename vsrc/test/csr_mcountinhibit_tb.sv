`ifdef VERILATOR
`include "include/common.sv"
`include "include/csr.sv"
`include "src/core.sv"
`endif

module csr_mcountinhibit_tb
    import common::*;
    import csr_pkg::*;
;
    localparam u32 NOP = 32'h0000_0013;

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
            PCINIT + 64'h00: instr_at = addi(5'd1, 5'd0, 12'sh005);
            PCINIT + 64'h04: instr_at = csrw(CSR_MCOUNTINHIBIT, 5'd1);
            PCINIT + 64'h08: instr_at = csrr(5'd5, CSR_MCOUNTINHIBIT);
            PCINIT + 64'h0c: instr_at = csrr(5'd6, CSR_MCYCLE);
            PCINIT + 64'h10: instr_at = csrr(5'd7, CSR_MINSTRET);
            PCINIT + 64'h14: instr_at = addi(5'd2, 5'd0, 12'sh001);
            PCINIT + 64'h18: instr_at = addi(5'd3, 5'd0, 12'sh002);
            PCINIT + 64'h1c: instr_at = csrr(5'd8, CSR_MCYCLE);
            PCINIT + 64'h20: instr_at = csrr(5'd9, CSR_MINSTRET);
            PCINIT + 64'h24: instr_at = csrw(CSR_MCOUNTINHIBIT, 5'd0);
            PCINIT + 64'h28: instr_at = csrr(5'd10, CSR_MCOUNTINHIBIT);
            PCINIT + 64'h2c: instr_at = csrr(5'd11, CSR_MCYCLE);
            PCINIT + 64'h30: instr_at = addi(5'd4, 5'd0, 12'sh003);
            PCINIT + 64'h34: instr_at = csrr(5'd12, CSR_MCYCLE);
            PCINIT + 64'h38: instr_at = csrr(5'd13, CSR_MINSTRET);
            PCINIT + 64'h3c: instr_at = addi(5'd14, 5'd0, 12'sh004);
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

    always_comb begin
        dresp = '0;
        dresp.addr_ok = dreq.valid;
        dresp.paddr = dreq.addr;
    end

    task automatic expect_mcountinhibit();
        if (dut.gpr[5] != MCOUNTINHIBIT_MASK) begin
            $fatal(1, "mcountinhibit read %h expected %h", dut.gpr[5], MCOUNTINHIBIT_MASK);
        end
        if (dut.gpr[8] != dut.gpr[6]) begin
            $fatal(1, "mcycle advanced while inhibited: before=%h after=%h",
                dut.gpr[6], dut.gpr[8]);
        end
        if (dut.gpr[9] != dut.gpr[7]) begin
            $fatal(1, "minstret advanced while inhibited: before=%h after=%h",
                dut.gpr[7], dut.gpr[9]);
        end
        if (dut.gpr[10] != 64'd0) begin
            $fatal(1, "mcountinhibit clear read %h expected 0", dut.gpr[10]);
        end
        if (dut.gpr[12] <= dut.gpr[11]) begin
            $fatal(1, "mcycle did not resume after clear: before=%h after=%h",
                dut.gpr[11], dut.gpr[12]);
        end
        if (dut.gpr[13] <= dut.gpr[9]) begin
            $fatal(1, "minstret did not resume after clear: before=%h after=%h",
                dut.gpr[9], dut.gpr[13]);
        end
        $display("csr_mcountinhibit_read_write [OK]");
        $display("csr_mcountinhibit_stops_mcycle [OK]");
        $display("csr_mcountinhibit_stops_minstret [OK]");
        $display("csr_mcountinhibit_resume [OK]");
    endtask

    initial begin
        clk = 1'b0;
        reset = 1'b1;
        trint = 1'b0;
        swint = 1'b0;
        exint = 1'b0;
        repeat (3) @(posedge clk);
        reset = 1'b0;

        for (int cycle = 0; cycle < 160; cycle += 1) begin
            @(posedge clk);
            if (dut.gpr[14] == 64'd4) begin
                expect_mcountinhibit();
                $display("CSR mcountinhibit directed test passed.");
                $finish;
            end
        end

        $fatal(1, "timed out waiting for mcountinhibit test completion");
    end

    `UNUSED_OK({satp, mstatus, dreq, if_flush, priv_mode});
endmodule
