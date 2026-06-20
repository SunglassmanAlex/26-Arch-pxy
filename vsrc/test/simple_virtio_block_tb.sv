`ifdef VERILATOR
`include "include/common.sv"
`endif

module simple_virtio_block_tb
    import common::*;
;
    localparam addr_t VIRTIO_BASE = 64'h0000_0000_1000_1000;
    localparam addr_t DMA_ADDR = 64'h0000_0000_8000_1000;
    localparam word_t MAGIC_VERSION = {32'd2, 32'h7472_6976};
    localparam word_t DEVICE_VENDOR = {32'h554d_4551, 32'd2};

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

    task automatic cbus_read(input addr_t addr, output word_t data);
        oreq = '0;
        oreq.valid = 1'b1;
        oreq.is_write = 1'b0;
        oreq.size = MSIZE8;
        oreq.addr = addr;
        oreq.len = MLEN1;
        oreq.burst = AXI_BURST_FIXED;
        do begin
            @(posedge clk);
        end while (!oresp.last);
        data = oresp.data;
        oreq = '0;
        @(posedge clk);
    endtask

    task automatic cbus_write(input addr_t addr, input word_t data);
        oreq = '0;
        oreq.valid = 1'b1;
        oreq.is_write = 1'b1;
        oreq.size = MSIZE8;
        oreq.addr = addr;
        oreq.strobe = 8'hff;
        oreq.data = data;
        oreq.len = MLEN1;
        oreq.burst = AXI_BURST_FIXED;
        do begin
            @(posedge clk);
        end while (!oresp.last);
        oreq = '0;
        @(posedge clk);
    endtask

    task automatic expect_read(input addr_t addr, input word_t expected, input string name);
        word_t data;
        cbus_read(addr, data);
        if (data !== expected) begin
            $fatal(1, "%s read %h expected %h", name, data, expected);
        end
        $display("%s [OK]", name);
    endtask

    function automatic word_t pattern(input int idx);
        pattern = 64'h4453_4b54_0000_0000 | 64'(idx);
    endfunction

    function automatic addr_t ram_idx(input addr_t addr);
        ram_idx = (addr > 64'h8000_0000) ? ((addr - 64'h8000_0000) >> 3) : 64'd0;
    endfunction

    task automatic ram_write_word(input addr_t addr, input word_t data);
        ram_write_helper(ram_idx(addr), data, 64'hffff_ffff_ffff_ffff, 1'b1);
    endtask

    function automatic word_t ram_read_word(input addr_t addr);
        ram_read_word = word_t'(ram_read_helper(1'b1, ram_idx(addr)));
    endfunction

    initial begin
        clk = 1'b0;
        reset = 1'b1;
        oreq = '0;
        uart_in_ch = 8'hff;
        repeat (3) @(posedge clk);
        reset = 1'b0;
        @(posedge clk);

        expect_read(VIRTIO_BASE + 64'h000, MAGIC_VERSION, "virtio_magic_version");
        expect_read(VIRTIO_BASE + 64'h008, DEVICE_VENDOR, "virtio_device_vendor");
        expect_read(VIRTIO_BASE + 64'h120, 64'd16, "simple_block_capacity");
        expect_read(VIRTIO_BASE + 64'h128, 64'd512, "simple_block_sector_size");

        for (int word_idx = 0; word_idx < 64; word_idx += 1) begin
            ram_write_word(DMA_ADDR + 64'(word_idx * 8), pattern(word_idx));
        end

        cbus_write(VIRTIO_BASE + 64'h100, 64'd3);
        cbus_write(VIRTIO_BASE + 64'h108, DMA_ADDR);
        cbus_write(VIRTIO_BASE + 64'h110, 64'd2);
        expect_read(VIRTIO_BASE + 64'h118, 64'd0, "simple_block_write_status");

        for (int word_idx = 0; word_idx < 64; word_idx += 1) begin
            ram_write_word(DMA_ADDR + 64'(word_idx * 8), 64'd0);
        end

        cbus_write(VIRTIO_BASE + 64'h100, 64'd3);
        cbus_write(VIRTIO_BASE + 64'h108, DMA_ADDR);
        cbus_write(VIRTIO_BASE + 64'h110, 64'd1);
        expect_read(VIRTIO_BASE + 64'h118, 64'd0, "simple_block_read_status");

        for (int word_idx = 0; word_idx < 64; word_idx += 1) begin
            word_t data;
            data = ram_read_word(DMA_ADDR + 64'(word_idx * 8));
            if (data !== pattern(word_idx)) begin
                $fatal(1, "dma word %0d read %h expected %h", word_idx, data, pattern(word_idx));
            end
        end

        $display("simple virtio block MMIO test passed.");
        $finish;
    end

    `UNUSED_OK({trint, swint, exint, uart_out_valid, uart_out_ch, uart_in_valid});
endmodule
