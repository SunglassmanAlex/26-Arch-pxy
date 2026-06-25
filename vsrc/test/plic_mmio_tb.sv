`ifdef VERILATOR
`include "include/common.sv"
`endif

module plic_mmio_tb
    import common::*;
;
    localparam addr_t PLIC_BASE = 64'h0000_0000_0c00_0000;
    localparam addr_t PLIC_PENDING = PLIC_BASE + 64'h1000;
    localparam addr_t PLIC_M_ENABLE = PLIC_BASE + 64'h2000;
    localparam addr_t PLIC_S_ENABLE = PLIC_BASE + 64'h2080;
    localparam addr_t PLIC_M_THRESHOLD = PLIC_BASE + 64'h200000;
    localparam addr_t PLIC_M_CLAIM = PLIC_BASE + 64'h200004;
    localparam addr_t PLIC_S_THRESHOLD = PLIC_BASE + 64'h201000;
    localparam addr_t PLIC_S_CLAIM = PLIC_BASE + 64'h201004;
    localparam addr_t VIRTIO_BASE = 64'h0000_0000_1000_1000;
    localparam addr_t DMA_ADDR = 64'h0000_0000_8000_2000;
    localparam addr_t UART_BASE = 64'h0000_0000_1000_0000;
    localparam addr_t UART_IER_DLM = UART_BASE + 64'h1;
    localparam int VIRTIO_IRQ = 1;
    localparam int UART_IRQ = 10;

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
        do begin
            @(posedge clk);
        end while (!oresp.last);
        oreq = '0;
        @(posedge clk);
    endtask

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

    task automatic read32(input addr_t addr, output u32 data);
        word_t raw;
        cbus_read(addr, MSIZE4, raw);
        data = u32'(raw >> {addr[2:0], 3'b000});
    endtask

    task automatic write32(input addr_t addr, input u32 data);
        cbus_write(addr, MSIZE4, {32'd0, data});
    endtask

    task automatic write8(input addr_t addr, input u8 data);
        cbus_write(addr, MSIZE1, {56'd0, data});
    endtask

    task automatic write64(input addr_t addr, input word_t data);
        cbus_write(addr, MSIZE8, data);
    endtask

    task automatic expect32(input addr_t addr, input u32 expected, input string name);
        u32 data;
        read32(addr, data);
        if (data !== expected) begin
            $fatal(1, "%s read %h expected %h", name, data, expected);
        end
        $display("%s [OK]", name);
    endtask

    task automatic expect_exint(input logic expected, input string name);
        @(posedge clk);
        if (exint !== expected) begin
            $fatal(1, "%s exint=%b expected %b", name, exint, expected);
        end
        $display("%s [OK]", name);
    endtask

    task automatic trigger_virtio_irq();
        write64(VIRTIO_BASE + 64'h100, 64'd0);
        write64(VIRTIO_BASE + 64'h108, DMA_ADDR);
        write64(VIRTIO_BASE + 64'h110, 64'd1);
    endtask

    task automatic trigger_uart_irq();
        write8(UART_IER_DLM, 8'h02);
    endtask

    initial begin
        clk = 1'b0;
        reset = 1'b1;
        oreq = '0;
        uart_in_ch = 8'hff;
        repeat (3) @(posedge clk);
        reset = 1'b0;
        @(posedge clk);

        expect32(PLIC_BASE + 64'(VIRTIO_IRQ * 4), 32'd0, "plic_priority_reset");
        expect32(PLIC_PENDING, 32'd0, "plic_pending_reset");
        expect_exint(1'b0, "plic_irq_reset");

        write32(PLIC_BASE + 64'(VIRTIO_IRQ * 4), 32'd3);
        write32(PLIC_M_ENABLE, 32'(1 << VIRTIO_IRQ));
        write32(PLIC_M_THRESHOLD, 32'd0);
        expect32(PLIC_BASE + 64'(VIRTIO_IRQ * 4), 32'd3, "plic_priority_write");
        expect32(PLIC_M_ENABLE, 32'(1 << VIRTIO_IRQ), "plic_m_enable_write");

        trigger_virtio_irq();
        expect32(PLIC_PENDING, 32'(1 << VIRTIO_IRQ), "plic_pending_after_virtio");
        expect_exint(1'b1, "plic_m_irq_pending");
        expect32(PLIC_M_THRESHOLD, 32'd0, "plic_m_threshold_read_no_claim");
        expect_exint(1'b1, "plic_m_irq_after_threshold_read");
        expect32(PLIC_M_CLAIM, 32'(VIRTIO_IRQ), "plic_m_claim");
        expect_exint(1'b0, "plic_m_claim_clears_pending");
        write32(PLIC_M_CLAIM, 32'(VIRTIO_IRQ));
        expect_exint(1'b0, "plic_m_complete_no_repend");

        write32(PLIC_M_ENABLE, 32'd0);
        write32(PLIC_S_ENABLE, 32'(1 << VIRTIO_IRQ));
        write32(PLIC_S_THRESHOLD, 32'd3);
        trigger_virtio_irq();
        expect32(PLIC_PENDING, 32'(1 << VIRTIO_IRQ), "plic_s_pending_with_threshold");
        expect_exint(1'b0, "plic_s_threshold_blocks_irq");
        write32(PLIC_S_THRESHOLD, 32'd2);
        expect_exint(1'b1, "plic_s_threshold_allows_irq");
        expect32(PLIC_S_CLAIM, 32'(VIRTIO_IRQ), "plic_s_claim");
        write32(PLIC_S_CLAIM, 32'(VIRTIO_IRQ));
        expect_exint(1'b0, "plic_s_complete");

        write32(PLIC_BASE + 64'(VIRTIO_IRQ * 4), 32'd3);
        write32(PLIC_BASE + 64'(UART_IRQ * 4), 32'd7);
        write32(PLIC_M_ENABLE, 32'((1 << VIRTIO_IRQ) | (1 << UART_IRQ)));
        write32(PLIC_M_THRESHOLD, 32'd0);
        trigger_virtio_irq();
        trigger_uart_irq();
        expect32(
            PLIC_PENDING,
            32'((1 << VIRTIO_IRQ) | (1 << UART_IRQ)),
            "plic_multi_pending"
        );
        expect32(PLIC_M_CLAIM, 32'(UART_IRQ), "plic_multi_claim_high_priority_uart");
        expect32(PLIC_PENDING, 32'(1 << VIRTIO_IRQ), "plic_multi_claim_leaves_virtio");
        expect32(PLIC_M_CLAIM, 32'(VIRTIO_IRQ), "plic_multi_claim_remaining_virtio");
        write32(PLIC_M_CLAIM, 32'(UART_IRQ));
        write32(PLIC_M_CLAIM, 32'(VIRTIO_IRQ));
        expect_exint(1'b0, "plic_multi_complete");

        write32(PLIC_BASE + 64'(UART_IRQ * 4), 32'd3);
        trigger_virtio_irq();
        trigger_uart_irq();
        expect32(
            PLIC_PENDING,
            32'((1 << VIRTIO_IRQ) | (1 << UART_IRQ)),
            "plic_equal_priority_pending"
        );
        expect32(PLIC_M_CLAIM, 32'(VIRTIO_IRQ), "plic_equal_priority_claim_low_id");
        expect32(PLIC_M_CLAIM, 32'(UART_IRQ), "plic_equal_priority_claim_next_id");
        write32(PLIC_M_CLAIM, 32'(VIRTIO_IRQ));
        write32(PLIC_M_CLAIM, 32'(UART_IRQ));
        expect_exint(1'b0, "plic_equal_priority_complete");

        $display("PLIC MMIO directed tests passed.");
        $finish;
    end

    `UNUSED_OK({trint, swint, uart_out_valid, uart_out_ch, uart_in_valid});
endmodule
