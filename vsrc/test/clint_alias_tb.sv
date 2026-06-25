`ifdef VERILATOR
`include "include/common.sv"
`endif

module clint_alias_tb
    import common::*;
;
    localparam addr_t LEGACY_MSIP     = 64'h0000_0000_3800_0000;
    localparam addr_t LEGACY_MTIMECMP = 64'h0000_0000_3800_4000;
    localparam addr_t LEGACY_MTIME    = 64'h0000_0000_3800_bff8;
    localparam addr_t QEMU_MSIP       = 64'h0000_0000_0200_0000;
    localparam addr_t QEMU_MTIMECMP   = 64'h0000_0000_0200_4000;
    localparam addr_t QEMU_MTIME      = 64'h0000_0000_0200_bff8;

    logic clk, reset;
    cbus_req_t oreq;
    cbus_resp_t oresp;
    logic trint, swint, exint;
    logic uart_out_valid, uart_in_valid;
    logic [7:0] uart_out_ch, uart_in_ch;

    SimMemoryWithVirtio dut(
        .clk(clk),
        .reset(reset),
        .oreq(oreq),
        .oresp(oresp),
        .trint(trint),
        .swint(swint),
        .exint(exint),
        .uart_out_valid(uart_out_valid),
        .uart_out_ch(uart_out_ch),
        .uart_in_valid(uart_in_valid),
        .uart_in_ch(uart_in_ch)
    );

    always #5 clk = ~clk;

    function automatic strobe_t make_strobe(input msize_t size, input logic [2:0] ofs);
        unique case (size)
            MSIZE1: make_strobe = 8'b0000_0001 << ofs;
            MSIZE2: make_strobe = 8'b0000_0011 << ofs;
            MSIZE4: make_strobe = 8'b0000_1111 << ofs;
            default: make_strobe = 8'b1111_1111;
        endcase
    endfunction

    function automatic word_t shift_store(input msize_t size, input logic [2:0] ofs, input word_t data);
        word_t payload;
        unique case (size)
            MSIZE1: payload = {56'd0, data[7:0]};
            MSIZE2: payload = {48'd0, data[15:0]};
            MSIZE4: payload = {32'd0, data[31:0]};
            default: payload = data;
        endcase
        shift_store = payload << {ofs, 3'b000};
    endfunction

    task automatic cbus_read(input addr_t addr, input msize_t size, output word_t data);
        oreq = '0;
        oreq.valid = 1'b1;
        oreq.is_write = 1'b0;
        oreq.size = size;
        oreq.addr = addr;
        oreq.len = MLEN1;
        oreq.burst = AXI_BURST_FIXED;
        @(posedge clk);
        #1;
        while (!oresp.last) begin
            @(posedge clk);
            #1;
        end
        data = oresp.data;
        oreq = '0;
        @(posedge clk);
    endtask

    task automatic cbus_write(input addr_t addr, input msize_t size, input word_t data);
        oreq = '0;
        oreq.valid = 1'b1;
        oreq.is_write = 1'b1;
        oreq.size = size;
        oreq.addr = addr;
        oreq.strobe = make_strobe(size, addr[2:0]);
        oreq.data = shift_store(size, addr[2:0], data);
        oreq.len = MLEN1;
        oreq.burst = AXI_BURST_FIXED;
        @(posedge clk);
        #1;
        while (!oresp.last) begin
            @(posedge clk);
            #1;
        end
        oreq = '0;
        @(posedge clk);
    endtask

    task automatic read64(input addr_t addr, output word_t data);
        cbus_read(addr, MSIZE8, data);
    endtask

    task automatic write64(input addr_t addr, input word_t data);
        cbus_write(addr, MSIZE8, data);
    endtask

    task automatic expect64(input addr_t addr, input word_t expected, input string name);
        word_t data;
        read64(addr, data);
        if (data !== expected) begin
            $fatal(1, "%s read %h expected %h", name, data, expected);
        end
        $display("%s [OK]", name);
    endtask

    task automatic expect_swint(input logic expected, input string name);
        @(posedge clk);
        if (swint !== expected) begin
            $fatal(1, "%s swint=%b expected %b", name, swint, expected);
        end
        $display("%s [OK]", name);
    endtask

    task automatic expect_trint(input logic expected, input string name);
        @(posedge clk);
        if (trint !== expected) begin
            $fatal(1, "%s trint=%b expected %b", name, trint, expected);
        end
        $display("%s [OK]", name);
    endtask

    initial begin
        clk = 1'b0;
        reset = 1'b1;
        oreq = '0;
        uart_in_ch = 8'hff;
        repeat (3) @(posedge clk);
        reset = 1'b0;
        @(posedge clk);

        expect_swint(1'b0, "clint_swint_reset");
        expect_trint(1'b0, "clint_trint_reset");

        write64(LEGACY_MSIP, 64'd1);
        expect64(LEGACY_MSIP, 64'd1, "clint_legacy_msip_self_read");
        expect_swint(1'b1, "clint_legacy_msip_sets_swint");

        write64(LEGACY_MSIP, 64'd0);
        expect64(LEGACY_MSIP, 64'd0, "clint_legacy_msip_self_clear");
        expect_swint(1'b0, "clint_legacy_msip_self_clears_swint");

        write64(QEMU_MSIP, 64'd1);
        expect64(LEGACY_MSIP, 64'd1, "clint_qemu_msip_to_legacy_read");
        expect_swint(1'b1, "clint_qemu_msip_sets_swint");

        write64(LEGACY_MSIP, 64'd0);
        expect64(QEMU_MSIP, 64'd0, "clint_legacy_msip_to_qemu_read");
        expect_swint(1'b0, "clint_legacy_msip_clears_swint");

        write64(QEMU_MTIMECMP, 64'h1234_5678_9abc_def0);
        expect64(LEGACY_MTIMECMP, 64'h1234_5678_9abc_def0, "clint_qemu_mtimecmp_to_legacy_read");

        write64(LEGACY_MTIMECMP, 64'd10);
        write64(QEMU_MTIME, 64'd20);
        expect_trint(1'b1, "clint_qemu_mtime_sets_trint");

        write64(QEMU_MTIMECMP, 64'd1000);
        expect64(LEGACY_MTIMECMP, 64'd1000, "clint_qemu_mtimecmp_updates_legacy");
        expect_trint(1'b0, "clint_qemu_mtimecmp_clears_trint");

        write64(LEGACY_MTIME, 64'd2000);
        write64(QEMU_MTIMECMP, 64'd1999);
        expect_trint(1'b1, "clint_legacy_mtime_sets_trint");

        if (exint !== 1'b0) begin
            $fatal(1, "CLINT test expected exint to stay low");
        end
        $display("CLINT alias directed tests passed.");
        $finish;
    end

    `UNUSED_OK({uart_out_valid, uart_out_ch, uart_in_valid});
endmodule
