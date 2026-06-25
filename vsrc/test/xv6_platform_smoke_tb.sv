`ifdef VERILATOR
`include "include/common.sv"
`endif

module xv6_platform_smoke_tb
    import common::*;
;
    localparam addr_t CLINT_MSIP     = 64'h0000_0000_0200_0000;
    localparam addr_t CLINT_MTIMECMP = 64'h0000_0000_0200_4000;
    localparam addr_t CLINT_MTIME    = 64'h0000_0000_0200_bff8;
    localparam addr_t PLIC_BASE      = 64'h0000_0000_0c00_0000;
    localparam addr_t PLIC_PENDING   = PLIC_BASE + 64'h1000;
    localparam addr_t PLIC_S_ENABLE  = PLIC_BASE + 64'h2080;
    localparam addr_t PLIC_S_THRES   = PLIC_BASE + 64'h201000;
    localparam addr_t PLIC_S_CLAIM   = PLIC_BASE + 64'h201004;
    localparam addr_t UART_BASE      = 64'h0000_0000_1000_0000;
    localparam addr_t UART_RBR_THR_DLL = UART_BASE + 64'h0;
    localparam addr_t UART_IER_DLM   = UART_BASE + 64'h1;
    localparam addr_t UART_IIR_FCR   = UART_BASE + 64'h2;
    localparam addr_t UART_LCR       = UART_BASE + 64'h3;
    localparam addr_t UART_LSR       = UART_BASE + 64'h5;
    localparam addr_t VIRTIO_BASE    = 64'h0000_0000_1000_1000;
    localparam addr_t DMA_ADDR       = 64'h0000_0000_8000_3000;
    localparam int VIRTIO_IRQ = 1;
    localparam int UART_IRQ = 10;

    logic clk, reset;
    cbus_req_t oreq;
    cbus_resp_t oresp;
    logic trint, swint, exint;
    logic uart_out_valid, uart_in_valid;
    logic [7:0] uart_out_ch, uart_in_ch;
    logic [2:0] uart_in_error;

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
        .uart_in_ch(uart_in_ch),
        .uart_in_error(uart_in_error)
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
        #1;
        while (!oresp.last) begin
            @(posedge clk);
            #1;
        end
        data = oresp.data;
        @(posedge clk);
        #1;
        oreq = '0;
        @(posedge clk);
        #1;
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
        #1;
        while (!oresp.last) begin
            @(posedge clk);
            #1;
        end
        @(posedge clk);
        #1;
        oreq = '0;
        @(posedge clk);
        #1;
    endtask

    task automatic read8(input addr_t addr, output u8 data);
        word_t raw;
        cbus_read(addr, MSIZE1, raw);
        data = u8'(raw >> {addr[2:0], 3'b000});
    endtask

    task automatic read32(input addr_t addr, output u32 data);
        word_t raw;
        cbus_read(addr, MSIZE4, raw);
        data = u32'(raw >> {addr[2:0], 3'b000});
    endtask

    task automatic read64(input addr_t addr, output word_t data);
        cbus_read(addr, MSIZE8, data);
    endtask

    task automatic write8(input addr_t addr, input u8 data);
        cbus_write(addr, MSIZE1, {56'd0, data});
    endtask

    task automatic write32(input addr_t addr, input u32 data);
        cbus_write(addr, MSIZE4, {32'd0, data});
    endtask

    task automatic write64(input addr_t addr, input word_t data);
        cbus_write(addr, MSIZE8, data);
    endtask

    task automatic expect8(input addr_t addr, input u8 expected, input string name);
        u8 data;
        read8(addr, data);
        if (data !== expected) begin
            $fatal(1, "%s read %h expected %h", name, data, expected);
        end
        $display("%s [OK]", name);
    endtask

    task automatic expect32(input addr_t addr, input u32 expected, input string name);
        u32 data;
        read32(addr, data);
        if (data !== expected) begin
            $fatal(1, "%s read %h expected %h", name, data, expected);
        end
        $display("%s [OK]", name);
    endtask

    task automatic expect64(input addr_t addr, input word_t expected, input string name);
        word_t data;
        read64(addr, data);
        if (data !== expected) begin
            $fatal(1, "%s read %h expected %h", name, data, expected);
        end
        $display("%s [OK]", name);
    endtask

    task automatic expect_irq(input logic value, input string name);
        @(posedge clk);
        #1;
        if (exint !== value) begin
            $fatal(1, "%s exint=%b expected %b", name, exint, value);
        end
        $display("%s [OK]", name);
    endtask

    task automatic expect_swint(input logic value, input string name);
        @(posedge clk);
        #1;
        if (swint !== value) begin
            $fatal(1, "%s swint=%b expected %b", name, swint, value);
        end
        $display("%s [OK]", name);
    endtask

    task automatic expect_trint(input logic value, input string name);
        @(posedge clk);
        #1;
        if (trint !== value) begin
            $fatal(1, "%s trint=%b expected %b", name, trint, value);
        end
        $display("%s [OK]", name);
    endtask

    task automatic inject_uart(input u8 data, input string name);
        if (!uart_in_valid) begin
            $fatal(1, "%s uart_in_valid is low", name);
        end
        uart_in_ch = data;
        uart_in_error = 3'b000;
        @(posedge clk);
        #1;
        uart_in_ch = 8'hff;
        @(posedge clk);
        #1;
        $display("%s [OK]", name);
    endtask

    task automatic trigger_virtio_irq();
        write64(VIRTIO_BASE + 64'h100, 64'd0);
        write64(VIRTIO_BASE + 64'h108, DMA_ADDR);
        write64(VIRTIO_BASE + 64'h110, 64'd1);
    endtask

    initial begin
        clk = 1'b0;
        reset = 1'b1;
        oreq = '0;
        uart_in_ch = 8'hff;
        uart_in_error = 3'b000;
        repeat (3) @(posedge clk);
        reset = 1'b0;
        @(posedge clk);
        #1;

        write64(CLINT_MSIP, 64'd1);
        expect64(CLINT_MSIP, 64'd1, "xv6_smoke_clint_msip_read");
        expect_swint(1'b1, "xv6_smoke_clint_swint_set");
        write64(CLINT_MSIP, 64'd0);
        expect_swint(1'b0, "xv6_smoke_clint_swint_clear");

        write64(CLINT_MTIMECMP, 64'd10);
        write64(CLINT_MTIME, 64'd20);
        expect_trint(1'b1, "xv6_smoke_clint_trint_set");
        write64(CLINT_MTIMECMP, 64'd1000);
        expect_trint(1'b0, "xv6_smoke_clint_trint_clear");

        write32(PLIC_BASE + 64'(VIRTIO_IRQ * 4), 32'd3);
        write32(PLIC_BASE + 64'(UART_IRQ * 4), 32'd2);
        write32(PLIC_S_ENABLE, 32'((1 << VIRTIO_IRQ) | (1 << UART_IRQ)));
        write32(PLIC_S_THRES, 32'd0);
        expect32(PLIC_S_ENABLE, 32'((1 << VIRTIO_IRQ) | (1 << UART_IRQ)),
            "xv6_smoke_plic_s_enable");

        write8(UART_LCR, 8'h80);
        write8(UART_RBR_THR_DLL, 8'h03);
        write8(UART_IER_DLM, 8'h00);
        write8(UART_LCR, 8'h03);
        write8(UART_IIR_FCR, 8'h07);
        write8(UART_IER_DLM, 8'h01);
        inject_uart(8'h4b, "xv6_smoke_uart_rx_inject");
        expect8(UART_LSR, 8'h61, "xv6_smoke_uart_lsr_ready");
        expect32(PLIC_PENDING, 32'(1 << UART_IRQ), "xv6_smoke_uart_pending");
        expect_irq(1'b1, "xv6_smoke_uart_exint");
        expect32(PLIC_S_CLAIM, 32'(UART_IRQ), "xv6_smoke_uart_s_claim");
        expect8(UART_RBR_THR_DLL, 8'h4b, "xv6_smoke_uart_rbr");
        write32(PLIC_S_CLAIM, 32'(UART_IRQ));
        expect_irq(1'b0, "xv6_smoke_uart_complete");

        trigger_virtio_irq();
        expect32(PLIC_PENDING, 32'(1 << VIRTIO_IRQ), "xv6_smoke_virtio_pending");
        expect_irq(1'b1, "xv6_smoke_virtio_exint");
        expect32(PLIC_S_CLAIM, 32'(VIRTIO_IRQ), "xv6_smoke_virtio_s_claim");
        write32(PLIC_S_CLAIM, 32'(VIRTIO_IRQ));
        expect_irq(1'b0, "xv6_smoke_virtio_complete");

        trigger_virtio_irq();
        inject_uart(8'h55, "xv6_smoke_multi_uart_inject");
        expect32(PLIC_PENDING, 32'((1 << VIRTIO_IRQ) | (1 << UART_IRQ)),
            "xv6_smoke_multi_pending");
        expect32(PLIC_S_CLAIM, 32'(VIRTIO_IRQ), "xv6_smoke_multi_claim_virtio_first");
        expect32(PLIC_S_CLAIM, 32'(UART_IRQ), "xv6_smoke_multi_claim_uart_second");
        expect8(UART_RBR_THR_DLL, 8'h55, "xv6_smoke_multi_uart_rbr");
        write32(PLIC_S_CLAIM, 32'(VIRTIO_IRQ));
        write32(PLIC_S_CLAIM, 32'(UART_IRQ));
        expect_irq(1'b0, "xv6_smoke_multi_complete");

        $display("xv6 platform smoke test passed.");
        $finish;
    end

    `UNUSED_OK({uart_out_valid, uart_out_ch});
endmodule
