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
    localparam addr_t VQ_DESC_ADDR   = 64'h0000_0000_8000_4000;
    localparam addr_t VQ_AVAIL_ADDR  = 64'h0000_0000_8000_4100;
    localparam addr_t VQ_USED_ADDR   = 64'h0000_0000_8000_4200;
    localparam addr_t VQ_REQ_ADDR    = 64'h0000_0000_8000_4300;
    localparam addr_t VQ_BUF_ADDR    = 64'h0000_0000_8000_4400;
    localparam addr_t VQ_STATUS_ADDR = 64'h0000_0000_8000_4600;
    localparam addr_t VQ_WRITE_BUF_ADDR = 64'h0000_0000_8000_4800;
    localparam addr_t VQ_READBACK_BUF_ADDR = 64'h0000_0000_8000_4c00;
    localparam int VIRTIO_IRQ = 1;
    localparam int UART_IRQ = 10;
    localparam u16 VIRTQ_DESC_F_NEXT = 16'h0001;
    localparam u16 VIRTQ_DESC_F_WRITE = 16'h0002;

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

    function automatic word_t simple_blk_default_word(input int idx);
        simple_blk_default_word = 64'h5342_4c4b_0000_0000 | 64'(idx);
    endfunction

    function automatic word_t smoke_write_word(input int idx);
        smoke_write_word = 64'h5856_3657_0000_0000 | 64'(idx);
    endfunction

    task automatic write_virtq_desc(
        input int index,
        input addr_t desc_addr,
        input u32 desc_len,
        input u16 desc_flags,
        input u16 desc_next
    );
        addr_t base;
        begin
            base = VQ_DESC_ADDR + 64'(index) * 64'd16;
            write64(base, desc_addr);
            write32(base + 64'd8, desc_len);
            write32(base + 64'd12, {desc_next, desc_flags});
        end
    endtask

    task automatic write_blk_request(input u32 req_type, input word_t sector);
        write32(VQ_REQ_ADDR, req_type);
        write32(VQ_REQ_ADDR + 64'd4, 32'd0);
        write64(VQ_REQ_ADDR + 64'd8, sector);
    endtask

    task automatic trigger_virtio_irq();
        write64(VIRTIO_BASE + 64'h100, 64'd0);
        write64(VIRTIO_BASE + 64'h108, DMA_ADDR);
        write64(VIRTIO_BASE + 64'h110, 64'd1);
    endtask

    task automatic trigger_virtio_queue_read();
        word_t data;
        begin
            write32(VIRTIO_BASE + 64'h030, 32'd0);
            write32(VIRTIO_BASE + 64'h038, 32'd8);
            write32(VIRTIO_BASE + 64'h080, VQ_DESC_ADDR[31:0]);
            write32(VIRTIO_BASE + 64'h084, VQ_DESC_ADDR[63:32]);
            write32(VIRTIO_BASE + 64'h090, VQ_AVAIL_ADDR[31:0]);
            write32(VIRTIO_BASE + 64'h094, VQ_AVAIL_ADDR[63:32]);
            write32(VIRTIO_BASE + 64'h0a0, VQ_USED_ADDR[31:0]);
            write32(VIRTIO_BASE + 64'h0a4, VQ_USED_ADDR[63:32]);
            write32(VIRTIO_BASE + 64'h044, 32'd1);

            write32(VQ_AVAIL_ADDR, 32'd0);
            write32(VQ_AVAIL_ADDR + 64'd4, 32'd0);
            write32(VQ_USED_ADDR, 32'd0);
            write32(VQ_USED_ADDR + 64'd4, 32'd0);
            write32(VQ_USED_ADDR + 64'd8, 32'd0);
            write_blk_request(32'd0, 64'd7);
            write8(VQ_STATUS_ADDR, 8'hff);
            write_virtq_desc(0, VQ_REQ_ADDR, 32'd16, VIRTQ_DESC_F_NEXT, 16'd1);
            write_virtq_desc(
                1, VQ_BUF_ADDR, 32'd512,
                VIRTQ_DESC_F_NEXT | VIRTQ_DESC_F_WRITE, 16'd2
            );
            write_virtq_desc(2, VQ_STATUS_ADDR, 32'd1, VIRTQ_DESC_F_WRITE, 16'd0);
            write32(VQ_AVAIL_ADDR + 64'd4, 32'd0);
            write32(VQ_AVAIL_ADDR, 32'h0001_0000);

            write32(VIRTIO_BASE + 64'h050, 32'd0);
            expect8(VQ_STATUS_ADDR, 8'd0, "xv6_smoke_virtio_queue_status");
            expect32(VQ_USED_ADDR, 32'h0001_0000, "xv6_smoke_virtio_queue_used_idx");
            expect32(VQ_USED_ADDR + 64'd4, 32'd0, "xv6_smoke_virtio_queue_used_id");
            expect32(VQ_USED_ADDR + 64'd8, 32'd513, "xv6_smoke_virtio_queue_used_len");
            read64(VQ_BUF_ADDR, data);
            if (data !== simple_blk_default_word(7 * 64)) begin
                $fatal(1, "xv6_smoke_virtio_queue_data read %h expected %h",
                    data, simple_blk_default_word(7 * 64));
            end
            $display("xv6_smoke_virtio_queue_data [OK]");
            expect32(VIRTIO_BASE + 64'h060, 32'd1, "xv6_smoke_virtio_queue_interrupt");
        end
    endtask

    task automatic submit_virtio_queue_write();
        word_t data;
        begin
            write_blk_request(32'd1, 64'd8);
            for (int word_idx = 0; word_idx < 64; word_idx += 1) begin
                write64(VQ_WRITE_BUF_ADDR + 64'(word_idx * 8), smoke_write_word(word_idx));
            end
            write8(VQ_STATUS_ADDR, 8'hff);
            write_virtq_desc(3, VQ_REQ_ADDR, 32'd16, VIRTQ_DESC_F_NEXT, 16'd4);
            write_virtq_desc(4, VQ_WRITE_BUF_ADDR, 32'd512, VIRTQ_DESC_F_NEXT, 16'd5);
            write_virtq_desc(5, VQ_STATUS_ADDR, 32'd1, VIRTQ_DESC_F_WRITE, 16'd0);
            write32(VQ_AVAIL_ADDR + 64'd4, 32'h0003_0000);
            write32(VQ_AVAIL_ADDR, 32'h0002_0000);

            write32(VIRTIO_BASE + 64'h050, 32'd0);
            expect8(VQ_STATUS_ADDR, 8'd0, "xv6_smoke_virtio_write_status");
            expect32(VQ_USED_ADDR, 32'h0002_0000, "xv6_smoke_virtio_write_used_idx");
            expect32(VQ_USED_ADDR + 64'd12, 32'd3, "xv6_smoke_virtio_write_used_id");
            expect32(VQ_USED_ADDR + 64'd16, 32'd1, "xv6_smoke_virtio_write_used_len");
            read64(VQ_WRITE_BUF_ADDR, data);
            if (data !== smoke_write_word(0)) begin
                $fatal(1, "xv6_smoke_virtio_write_buffer read %h expected %h",
                    data, smoke_write_word(0));
            end
            $display("xv6_smoke_virtio_write_buffer [OK]");
            expect32(VIRTIO_BASE + 64'h060, 32'd1, "xv6_smoke_virtio_write_interrupt");
        end
    endtask

    task automatic submit_virtio_queue_readback();
        word_t data;
        begin
            write_blk_request(32'd0, 64'd8);
            write8(VQ_STATUS_ADDR, 8'hff);
            write_virtq_desc(0, VQ_REQ_ADDR, 32'd16, VIRTQ_DESC_F_NEXT, 16'd1);
            write_virtq_desc(
                1, VQ_READBACK_BUF_ADDR, 32'd512,
                VIRTQ_DESC_F_NEXT | VIRTQ_DESC_F_WRITE, 16'd2
            );
            write_virtq_desc(2, VQ_STATUS_ADDR, 32'd1, VIRTQ_DESC_F_WRITE, 16'd0);
            write32(VQ_AVAIL_ADDR + 64'd8, 32'd0);
            write32(VQ_AVAIL_ADDR, 32'h0003_0000);

            write32(VIRTIO_BASE + 64'h050, 32'd0);
            expect8(VQ_STATUS_ADDR, 8'd0, "xv6_smoke_virtio_readback_status");
            expect32(VQ_USED_ADDR, 32'h0003_0000, "xv6_smoke_virtio_readback_used_idx");
            expect32(VQ_USED_ADDR + 64'd20, 32'd0, "xv6_smoke_virtio_readback_used_id");
            expect32(VQ_USED_ADDR + 64'd24, 32'd513, "xv6_smoke_virtio_readback_used_len");
            for (int word_idx = 0; word_idx < 64; word_idx += 1) begin
                read64(VQ_READBACK_BUF_ADDR + 64'(word_idx * 8), data);
                if (data !== smoke_write_word(word_idx)) begin
                    $fatal(1, "xv6_smoke_virtio_readback_data word %0d read %h expected %h",
                        word_idx, data, smoke_write_word(word_idx));
                end
            end
            $display("xv6_smoke_virtio_readback_data [OK]");
            expect32(VIRTIO_BASE + 64'h060, 32'd1, "xv6_smoke_virtio_readback_interrupt");
        end
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

        trigger_virtio_queue_read();
        expect32(PLIC_PENDING, 32'(1 << VIRTIO_IRQ), "xv6_smoke_virtio_pending");
        expect_irq(1'b1, "xv6_smoke_virtio_exint");
        expect32(PLIC_S_CLAIM, 32'(VIRTIO_IRQ), "xv6_smoke_virtio_s_claim");
        write32(VIRTIO_BASE + 64'h064, 32'd1);
        write32(PLIC_S_CLAIM, 32'(VIRTIO_IRQ));
        expect_irq(1'b0, "xv6_smoke_virtio_complete");

        submit_virtio_queue_write();
        expect32(PLIC_PENDING, 32'(1 << VIRTIO_IRQ), "xv6_smoke_virtio_write_pending");
        expect_irq(1'b1, "xv6_smoke_virtio_write_exint");
        expect32(PLIC_S_CLAIM, 32'(VIRTIO_IRQ), "xv6_smoke_virtio_write_s_claim");
        write32(VIRTIO_BASE + 64'h064, 32'd1);
        write32(PLIC_S_CLAIM, 32'(VIRTIO_IRQ));
        expect_irq(1'b0, "xv6_smoke_virtio_write_complete");

        submit_virtio_queue_readback();
        expect32(PLIC_PENDING, 32'(1 << VIRTIO_IRQ), "xv6_smoke_virtio_readback_pending");
        expect_irq(1'b1, "xv6_smoke_virtio_readback_exint");
        expect32(PLIC_S_CLAIM, 32'(VIRTIO_IRQ), "xv6_smoke_virtio_readback_s_claim");
        write32(VIRTIO_BASE + 64'h064, 32'd1);
        write32(PLIC_S_CLAIM, 32'(VIRTIO_IRQ));
        expect_irq(1'b0, "xv6_smoke_virtio_readback_complete");

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
