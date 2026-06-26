`ifdef VERILATOR
`include "include/common.sv"
`include "include/csr.sv"
`include "src/core.sv"
`endif

module amo_d_tb
    import common::*;
;
    localparam addr_t DATA_ADDR = PCINIT + 64'h100;
    localparam word_t INIT_DATA = 64'h1234_5678_9abc_def0;

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
    word_t data_word;

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

    function automatic u32 auipc(input u5 rd, input logic [19:0] imm20);
        auipc = {imm20, rd, 7'b0010111};
    endfunction

    function automatic u32 ld(input u5 rd, input u5 rs1, input logic signed [11:0] imm);
        ld = instr_i(imm, rs1, 3'b011, rd, 7'b0000011);
    endfunction

    function automatic u32 amo_d(input logic [4:0] op, input u5 rd, input u5 rs1, input u5 rs2);
        amo_d = {op, 2'b00, rs2, rs1, 3'b011, rd, 7'b0101111};
    endfunction

    function automatic u32 instr_at(input addr_t addr);
        unique case (addr)
            PCINIT + 64'h00: instr_at = auipc(5'd5, 20'd0);
            PCINIT + 64'h04: instr_at = addi(5'd5, 5'd5, 12'sh100);
            PCINIT + 64'h08: instr_at = addi(5'd6, 5'd0, 12'sh011);
            PCINIT + 64'h0c: instr_at = amo_d(5'b00001, 5'd7, 5'd5, 5'd6);  // amoswap.d
            PCINIT + 64'h10: instr_at = ld(5'd8, 5'd5, 12'sh000);
            PCINIT + 64'h14: instr_at = addi(5'd9, 5'd0, 12'sh001);
            PCINIT + 64'h18: instr_at = amo_d(5'b00000, 5'd10, 5'd5, 5'd9); // amoadd.d
            PCINIT + 64'h1c: instr_at = ld(5'd11, 5'd5, 12'sh000);
            PCINIT + 64'h20: instr_at = amo_d(5'b00010, 5'd12, 5'd5, 5'd0); // lr.d
            PCINIT + 64'h24: instr_at = addi(5'd13, 5'd0, 12'sh022);
            PCINIT + 64'h28: instr_at = amo_d(5'b00011, 5'd14, 5'd5, 5'd13); // sc.d success
            PCINIT + 64'h2c: instr_at = ld(5'd15, 5'd5, 12'sh000);
            PCINIT + 64'h30: instr_at = amo_d(5'b00011, 5'd17, 5'd5, 5'd13); // sc.d fail
            PCINIT + 64'h34: instr_at = ld(5'd18, 5'd5, 12'sh000);
            PCINIT + 64'h38: instr_at = addi(5'd19, 5'd0, 12'sh001);
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

    always_ff @(posedge clk) begin
        if (reset) begin
            data_word <= INIT_DATA;
        end
        else if (dreq.valid && |dreq.strobe && (dreq.addr == DATA_ADDR)) begin
            for (int i = 0; i < 8; i += 1) begin
                if (dreq.strobe[i]) begin
                    data_word[i * 8 +: 8] <= dreq.data[i * 8 +: 8];
                end
            end
        end
    end

    always_comb begin
        dresp = '0;
        dresp.addr_ok = dreq.valid;
        dresp.data_ok = dreq.valid;
        dresp.paddr = dreq.addr;
        dresp.data = (dreq.addr == DATA_ADDR) ? data_word : 64'd0;
    end

    task automatic expect_amo_d();
        if (dut.gpr[7] != INIT_DATA) begin
            $fatal(1, "amoswap.d returned %h", dut.gpr[7]);
        end
        if (dut.gpr[8] != 64'h11) begin
            $fatal(1, "amoswap.d memory readback %h", dut.gpr[8]);
        end
        if (dut.gpr[10] != 64'h11) begin
            $fatal(1, "amoadd.d returned %h", dut.gpr[10]);
        end
        if (dut.gpr[11] != 64'h12) begin
            $fatal(1, "amoadd.d memory readback %h", dut.gpr[11]);
        end
        if (dut.gpr[12] != 64'h12) begin
            $fatal(1, "lr.d returned %h", dut.gpr[12]);
        end
        if (dut.gpr[14] != 64'd0) begin
            $fatal(1, "sc.d success returned %h", dut.gpr[14]);
        end
        if (dut.gpr[15] != 64'h22) begin
            $fatal(1, "sc.d success memory readback %h", dut.gpr[15]);
        end
        if (dut.gpr[17] != 64'd1) begin
            $fatal(1, "sc.d fail returned %h", dut.gpr[17]);
        end
        if (dut.gpr[18] != 64'h22 || data_word != 64'h22) begin
            $fatal(1, "sc.d fail changed memory: reg=%h mem=%h", dut.gpr[18], data_word);
        end
        $display("amo_d_swap_add [OK]");
        $display("amo_d_lr_sc_success [OK]");
        $display("amo_d_sc_fail [OK]");
    endtask

    initial begin
        clk = 1'b0;
        reset = 1'b1;
        trint = 1'b0;
        swint = 1'b0;
        exint = 1'b0;
        repeat (3) @(posedge clk);
        reset = 1'b0;

        for (int cycle = 0; cycle < 240; cycle += 1) begin
            @(posedge clk);
            if (dut.gpr[19] == 64'd1) begin
                expect_amo_d();
                $display("AMO.D directed test passed.");
                $finish;
            end
        end

        $fatal(1, "timed out waiting for AMO.D program completion");
    end

    `UNUSED_OK({satp, mstatus, dreq, if_flush, priv_mode});
endmodule
