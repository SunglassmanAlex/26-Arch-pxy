`ifdef VERILATOR
`include "include/common.sv"
`endif

module simple_virtio_block_tb
    import common::*;
;
    localparam addr_t VIRTIO_BASE = 64'h0000_0000_1000_1000;
    localparam addr_t DMA_ADDR = 64'h0000_0000_8000_1000;
    localparam addr_t VQ_DESC_ADDR = 64'h0000_0000_8000_2000;
    localparam addr_t VQ_AVAIL_ADDR = 64'h0000_0000_8000_2100;
    localparam addr_t VQ_USED_ADDR = 64'h0000_0000_8000_2200;
    localparam addr_t VQ_REQ_ADDR = 64'h0000_0000_8000_2300;
    localparam addr_t VQ_BUF_ADDR = 64'h0000_0000_8000_2400;
    localparam addr_t VQ_STATUS_ADDR = 64'h0000_0000_8000_2600;
    localparam addr_t VQ_INDIRECT_ADDR = 64'h0000_0000_8000_2700;
    localparam addr_t VQ_REQ2_ADDR = 64'h0000_0000_8000_2800;
    localparam addr_t VQ_BUF2_ADDR = 64'h0000_0000_8000_2900;
    localparam addr_t VQ_STATUS2_ADDR = 64'h0000_0000_8000_2b00;
    localparam addr_t PLIC_PENDING = 64'h0000_0000_0c00_1000;
    localparam int VIRTIO_IRQ = 1;
    localparam word_t MAGIC_VERSION = {32'd2, 32'h7472_6976};
    localparam word_t DEVICE_VENDOR = {32'h554d_4551, 32'd2};
    localparam u16 VIRTQ_DESC_F_NEXT = 16'h0001;
    localparam u16 VIRTQ_DESC_F_WRITE = 16'h0002;
    localparam u16 VIRTQ_DESC_F_INDIRECT = 16'h0004;
    localparam u32 VIRTIO_FEATURE_BLK_SIZE_MAX = 32'h0000_0002;
    localparam u32 VIRTIO_FEATURE_BLK_SEG_MAX = 32'h0000_0004;
    localparam u32 VIRTIO_FEATURE_BLK_SIZE = 32'h0000_0040;
    localparam u32 VIRTIO_FEATURE_INDIRECT = 32'h1000_0000;
    localparam u32 VIRTIO_FEATURE_EVENT_IDX = 32'h2000_0000;
    localparam u32 VIRTIO_FEATURE_BLK =
        VIRTIO_FEATURE_BLK_SIZE_MAX | VIRTIO_FEATURE_BLK_SEG_MAX | VIRTIO_FEATURE_BLK_SIZE;
    localparam u32 VIRTIO_FEATURE_SEL0 =
        VIRTIO_FEATURE_BLK | VIRTIO_FEATURE_INDIRECT | VIRTIO_FEATURE_EVENT_IDX;
    localparam u32 VIRTIO_FEATURE_VERSION_1 = 32'h0000_0001;
    localparam u32 VIRTIO_STATUS_ACK_DRIVER = 32'h0000_0003;
    localparam u32 VIRTIO_STATUS_FEATURES_OK = 32'h0000_0008;
    localparam u32 VIRTIO_STATUS_DRIVER_OK = 32'h0000_0004;
    localparam u32 SIMPLE_BLK_SECTORS = 32'd8192;
    localparam string SIMPLE_BLK_IMAGE_PATH = "build/simple-virtio/simple-blk.img";

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

    task automatic cbus_read32(input addr_t addr, output u32 data);
        word_t raw_data;
        int shift;
        begin
            oreq = '0;
            oreq.valid = 1'b1;
            oreq.is_write = 1'b0;
            oreq.size = MSIZE4;
            oreq.addr = addr;
            oreq.len = MLEN1;
            oreq.burst = AXI_BURST_FIXED;
            do begin
                @(posedge clk);
            end while (!oresp.last);
            shift = int'(addr[2:0]) * 8;
            raw_data = oresp.data >> shift;
            data = raw_data[31:0];
            oreq = '0;
            @(posedge clk);
        end
    endtask

    task automatic cbus_write32(input addr_t addr, input u32 data);
        int shift;
        begin
            shift = int'(addr[2:0]) * 8;
            oreq = '0;
            oreq.valid = 1'b1;
            oreq.is_write = 1'b1;
            oreq.size = MSIZE4;
            oreq.addr = addr;
            oreq.strobe = 8'h0f << addr[2:0];
            oreq.data = word_t'({32'd0, data}) << shift;
            oreq.len = MLEN1;
            oreq.burst = AXI_BURST_FIXED;
            do begin
                @(posedge clk);
            end while (!oresp.last);
            oreq = '0;
            @(posedge clk);
        end
    endtask

    task automatic expect_read(input addr_t addr, input word_t expected, input string name);
        word_t data;
        cbus_read(addr, data);
        if (data !== expected) begin
            $fatal(1, "%s read %h expected %h", name, data, expected);
        end
        $display("%s [OK]", name);
    endtask

    task automatic expect_read32(input addr_t addr, input u32 expected, input string name);
        u32 data;
        cbus_read32(addr, data);
        if (data !== expected) begin
            $fatal(1, "%s read %h expected %h", name, data, expected);
        end
        $display("%s [OK]", name);
    endtask

    function automatic word_t pattern(input int idx);
        pattern = 64'h4453_4b54_0000_0000 | 64'(idx);
    endfunction

    function automatic word_t image_pattern(input int idx);
        image_pattern = 64'h494d_4744_0000_0000 | 64'(idx);
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

    function automatic u8 ram_read_byte(input addr_t addr);
        word_t data;
        int shift;
        begin
            data = ram_read_word(addr);
            shift = int'(addr[2:0]) * 8;
            ram_read_byte = u8'(data >> shift);
        end
    endfunction

    function automatic u16 ram_read_u16(input addr_t addr);
        ram_read_u16 = '0;
        for (int byte_idx = 0; byte_idx < 2; byte_idx += 1) begin
            ram_read_u16[byte_idx * 8 +: 8] = ram_read_byte(addr + 64'(byte_idx));
        end
    endfunction

    function automatic u32 ram_read_u32(input addr_t addr);
        ram_read_u32 = '0;
        for (int byte_idx = 0; byte_idx < 4; byte_idx += 1) begin
            ram_read_u32[byte_idx * 8 +: 8] = ram_read_byte(addr + 64'(byte_idx));
        end
    endfunction

    task automatic ram_write_byte(input addr_t addr, input u8 data);
        int shift;
        word_t write_data;
        word_t write_mask;
        begin
            shift = int'(addr[2:0]) * 8;
            write_data = word_t'({56'd0, data}) << shift;
            write_mask = 64'h0000_0000_0000_00ff << shift;
            ram_write_helper(ram_idx(addr), write_data, write_mask, 1'b1);
        end
    endtask

    task automatic ram_write_u16(input addr_t addr, input u16 data);
        for (int byte_idx = 0; byte_idx < 2; byte_idx += 1) begin
            ram_write_byte(addr + 64'(byte_idx), data[byte_idx * 8 +: 8]);
        end
    endtask

    task automatic ram_write_u32(input addr_t addr, input u32 data);
        for (int byte_idx = 0; byte_idx < 4; byte_idx += 1) begin
            ram_write_byte(addr + 64'(byte_idx), data[byte_idx * 8 +: 8]);
        end
    endtask

    task automatic ram_write_u64(input addr_t addr, input word_t data);
        for (int byte_idx = 0; byte_idx < 8; byte_idx += 1) begin
            ram_write_byte(addr + 64'(byte_idx), data[byte_idx * 8 +: 8]);
        end
    endtask

    task automatic expect_ram_byte(input addr_t addr, input u8 expected, input string name);
        u8 data;
        data = ram_read_byte(addr);
        if (data !== expected) begin
            $fatal(1, "%s read %h expected %h", name, data, expected);
        end
        $display("%s [OK]", name);
    endtask

    task automatic expect_ram_u16(input addr_t addr, input u16 expected, input string name);
        u16 data;
        data = ram_read_u16(addr);
        if (data !== expected) begin
            $fatal(1, "%s read %h expected %h", name, data, expected);
        end
        $display("%s [OK]", name);
    endtask

    task automatic expect_ram_u32(input addr_t addr, input u32 expected, input string name);
        u32 data;
        data = ram_read_u32(addr);
        if (data !== expected) begin
            $fatal(1, "%s read %h expected %h", name, data, expected);
        end
        $display("%s [OK]", name);
    endtask

    task automatic write_desc_at(
        input addr_t table_base,
        input int index,
        input addr_t desc_addr,
        input u32 desc_len,
        input u16 desc_flags,
        input u16 desc_next
    );
        addr_t base;
        begin
            base = table_base + 64'(index) * 64'd16;
            ram_write_u64(base, desc_addr);
            ram_write_u32(base + 64'd8, desc_len);
            ram_write_u16(base + 64'd12, desc_flags);
            ram_write_u16(base + 64'd14, desc_next);
        end
    endtask

    task automatic write_desc(
        input int index,
        input addr_t desc_addr,
        input u32 desc_len,
        input u16 desc_flags,
        input u16 desc_next
    );
        write_desc_at(VQ_DESC_ADDR, index, desc_addr, desc_len, desc_flags, desc_next);
    endtask

    task automatic write_blk_request_at(input addr_t req_addr, input u32 req_type, input word_t sector);
        ram_write_u32(req_addr, req_type);
        ram_write_u32(req_addr + 64'd4, 32'd0);
        ram_write_u64(req_addr + 64'd8, sector);
    endtask

    task automatic write_blk_request(input u32 req_type, input word_t sector);
        write_blk_request_at(VQ_REQ_ADDR, req_type, sector);
    endtask

    task automatic setup_virtqueue();
        ram_write_u16(VQ_AVAIL_ADDR, 16'd0);
        ram_write_u16(VQ_AVAIL_ADDR + 64'd2, 16'd0);
        ram_write_u16(VQ_USED_ADDR, 16'd0);
        ram_write_u16(VQ_USED_ADDR + 64'd2, 16'd0);
        cbus_write32(VIRTIO_BASE + 64'h070, 32'd0);
        cbus_write32(VIRTIO_BASE + 64'h014, 32'd0);
        expect_read32(VIRTIO_BASE + 64'h010, VIRTIO_FEATURE_SEL0, "virtio_features_sel0");
        cbus_write32(VIRTIO_BASE + 64'h014, 32'd1);
        expect_read32(VIRTIO_BASE + 64'h010, VIRTIO_FEATURE_VERSION_1, "virtio_features_version1");
        cbus_write32(VIRTIO_BASE + 64'h024, 32'd0);
        cbus_write32(VIRTIO_BASE + 64'h020, 32'h0000_0001);
        cbus_write32(VIRTIO_BASE + 64'h070, VIRTIO_STATUS_ACK_DRIVER | VIRTIO_STATUS_FEATURES_OK);
        expect_read32(
            VIRTIO_BASE + 64'h070,
            VIRTIO_STATUS_ACK_DRIVER,
            "virtio_features_unsupported_rejected"
        );
        cbus_write32(VIRTIO_BASE + 64'h070, 32'd0);
        cbus_write32(VIRTIO_BASE + 64'h024, 32'd0);
        cbus_write32(VIRTIO_BASE + 64'h020, VIRTIO_FEATURE_SEL0);
        expect_read32(
            VIRTIO_BASE + 64'h020,
            VIRTIO_FEATURE_SEL0,
            "virtio_driver_features_sel0"
        );
        cbus_write32(VIRTIO_BASE + 64'h024, 32'd1);
        cbus_write32(VIRTIO_BASE + 64'h020, VIRTIO_FEATURE_VERSION_1);
        expect_read32(
            VIRTIO_BASE + 64'h020,
            VIRTIO_FEATURE_VERSION_1,
            "virtio_driver_features_version1"
        );
        cbus_write32(VIRTIO_BASE + 64'h030, 32'd0);
        expect_read32(VIRTIO_BASE + 64'h034, 32'd8, "virtio_queue_num_max");
        cbus_write32(VIRTIO_BASE + 64'h038, 32'd8);
        cbus_write32(VIRTIO_BASE + 64'h080, VQ_DESC_ADDR[31:0]);
        cbus_write32(VIRTIO_BASE + 64'h084, VQ_DESC_ADDR[63:32]);
        cbus_write32(VIRTIO_BASE + 64'h090, VQ_AVAIL_ADDR[31:0]);
        cbus_write32(VIRTIO_BASE + 64'h094, VQ_AVAIL_ADDR[63:32]);
        cbus_write32(VIRTIO_BASE + 64'h0a0, VQ_USED_ADDR[31:0]);
        cbus_write32(VIRTIO_BASE + 64'h0a4, VQ_USED_ADDR[63:32]);
        cbus_write32(VIRTIO_BASE + 64'h044, 32'd1);
        cbus_write32(
            VIRTIO_BASE + 64'h070,
            VIRTIO_STATUS_ACK_DRIVER | VIRTIO_STATUS_FEATURES_OK | VIRTIO_STATUS_DRIVER_OK
        );
        expect_read32(
            VIRTIO_BASE + 64'h070,
            VIRTIO_STATUS_ACK_DRIVER | VIRTIO_STATUS_FEATURES_OK | VIRTIO_STATUS_DRIVER_OK,
            "virtio_status_driver_ok"
        );
    endtask


    task automatic write_image_file(input string path);
        int image_fd;
        word_t data;
        byte unsigned data_byte;
        begin
            image_fd = $fopen(path, "wb");
            if (image_fd == 0) begin
                $fatal(1, "failed to create test simple block image: %s", path);
            end
            for (int word_idx = 0; word_idx < 16 * 64; word_idx += 1) begin
                data = image_pattern(word_idx);
                for (int byte_idx = 0; byte_idx < 8; byte_idx += 1) begin
                    data_byte = data[byte_idx * 8 +: 8];
                    $fwrite(image_fd, "%c", data_byte);
                end
            end
            $fclose(image_fd);
            $display("simple_block_image_created [OK]");
        end
    endtask

    initial begin
        clk = 1'b0;
        reset = 1'b1;
        oreq = '0;
        uart_in_ch = 8'hff;
        write_image_file(SIMPLE_BLK_IMAGE_PATH);
        repeat (3) @(posedge clk);
        reset = 1'b0;
        @(posedge clk);

        expect_read(VIRTIO_BASE + 64'h000, MAGIC_VERSION, "virtio_magic_version");
        expect_read(VIRTIO_BASE + 64'h008, DEVICE_VENDOR, "virtio_device_vendor");
        expect_read(VIRTIO_BASE + 64'h120, {32'd0, SIMPLE_BLK_SECTORS}, "simple_block_capacity");
        expect_read(VIRTIO_BASE + 64'h128, 64'd512, "simple_block_sector_size");
        expect_read32(VIRTIO_BASE + 64'h100, SIMPLE_BLK_SECTORS, "virtio_config_capacity_low");
        expect_read32(VIRTIO_BASE + 64'h104, 32'd0, "virtio_config_capacity_high");
        expect_read32(VIRTIO_BASE + 64'h108, 32'd512, "virtio_config_size_max");
        expect_read32(VIRTIO_BASE + 64'h10c, 32'd1, "virtio_config_seg_max");
        expect_read32(VIRTIO_BASE + 64'h114, 32'd512, "virtio_config_blk_size");
        expect_read32(VIRTIO_BASE + 64'h0fc, 32'd0, "virtio_config_generation_initial");

        for (int word_idx = 0; word_idx < 64; word_idx += 1) begin
            ram_write_word(DMA_ADDR + 64'(word_idx * 8), 64'd0);
        end
        cbus_write(VIRTIO_BASE + 64'h100, 64'd5);
        cbus_write(VIRTIO_BASE + 64'h108, DMA_ADDR);
        cbus_write(VIRTIO_BASE + 64'h110, 64'd1);
        expect_read(VIRTIO_BASE + 64'h118, 64'd0, "simple_block_image_read_status");
        for (int word_idx = 0; word_idx < 64; word_idx += 1) begin
            word_t data;
            data = ram_read_word(DMA_ADDR + 64'(word_idx * 8));
            if (data !== image_pattern(5 * 64 + word_idx)) begin
                $fatal(1, "image word %0d read %h expected %h",
                    word_idx, data, image_pattern(5 * 64 + word_idx));
            end
        end
        $display("simple_block_image_read_data [OK]");

        cbus_write(VIRTIO_BASE + 64'h100, 64'd5);
        cbus_write(VIRTIO_BASE + 64'h110, 64'd99);
        expect_read(VIRTIO_BASE + 64'h118, 64'd1, "simple_block_unknown_cmd_status");
        cbus_write(VIRTIO_BASE + 64'h100, {32'd0, SIMPLE_BLK_SECTORS});
        cbus_write(VIRTIO_BASE + 64'h110, 64'd1);
        expect_read(VIRTIO_BASE + 64'h118, 64'd2, "simple_block_oob_status");

        setup_virtqueue();

        for (int word_idx = 0; word_idx < 64; word_idx += 1) begin
            ram_write_word(VQ_BUF_ADDR + 64'(word_idx * 8), 64'd0);
        end
        write_blk_request(32'd0, 64'd6);
        ram_write_byte(VQ_STATUS_ADDR, 8'hff);
        write_desc(0, VQ_REQ_ADDR, 32'd16, VIRTQ_DESC_F_NEXT, 16'd1);
        write_desc(1, VQ_BUF_ADDR, 32'd512, VIRTQ_DESC_F_NEXT | VIRTQ_DESC_F_WRITE, 16'd2);
        write_desc(2, VQ_STATUS_ADDR, 32'd1, VIRTQ_DESC_F_WRITE, 16'd0);
        ram_write_u16(VQ_AVAIL_ADDR + 64'd4, 16'd0);
        ram_write_u16(VQ_AVAIL_ADDR + 64'd2, 16'd1);
        cbus_write32(VIRTIO_BASE + 64'h050, 32'd0);
        expect_ram_byte(VQ_STATUS_ADDR, 8'd0, "virtio_queue_read_status");
        expect_ram_u16(VQ_USED_ADDR + 64'd2, 16'd1, "virtio_queue_read_used_idx");
        expect_ram_u32(VQ_USED_ADDR + 64'd4, 32'd0, "virtio_queue_read_used_id");
        expect_ram_u32(VQ_USED_ADDR + 64'd8, 32'd513, "virtio_queue_read_used_len");
        expect_read32(VIRTIO_BASE + 64'h060, 32'd1, "virtio_queue_interrupt_status");
        expect_read32(PLIC_PENDING, 32'(1 << VIRTIO_IRQ), "plic_virtio_pending_after_queue");
        for (int word_idx = 0; word_idx < 64; word_idx += 1) begin
            word_t data;
            data = ram_read_word(VQ_BUF_ADDR + 64'(word_idx * 8));
            if (data !== image_pattern(6 * 64 + word_idx)) begin
                $fatal(1, "virtqueue read word %0d read %h expected %h",
                    word_idx, data, image_pattern(6 * 64 + word_idx));
            end
        end
        $display("virtio_queue_read_data [OK]");
        cbus_write32(VIRTIO_BASE + 64'h064, 32'd1);
        expect_read32(VIRTIO_BASE + 64'h060, 32'd0, "virtio_queue_interrupt_ack");
        expect_read32(PLIC_PENDING, 32'd0, "plic_virtio_pending_after_ack");

        for (int word_idx = 0; word_idx < 64; word_idx += 1) begin
            ram_write_word(VQ_BUF_ADDR + 64'(word_idx * 8), pattern(word_idx));
        end
        write_blk_request(32'd1, 64'd4);
        ram_write_byte(VQ_STATUS_ADDR, 8'hff);
        write_desc(0, VQ_REQ_ADDR, 32'd16, VIRTQ_DESC_F_NEXT, 16'd1);
        write_desc(1, VQ_BUF_ADDR, 32'd512, VIRTQ_DESC_F_NEXT, 16'd2);
        write_desc(2, VQ_STATUS_ADDR, 32'd1, VIRTQ_DESC_F_WRITE, 16'd0);
        ram_write_u16(VQ_AVAIL_ADDR + 64'd20, 16'd1);
        ram_write_u16(VQ_AVAIL_ADDR + 64'd6, 16'd0);
        ram_write_u16(VQ_AVAIL_ADDR + 64'd2, 16'd2);
        cbus_write32(VIRTIO_BASE + 64'h050, 32'd0);
        expect_ram_byte(VQ_STATUS_ADDR, 8'd0, "virtio_queue_write_status");
        expect_ram_u16(VQ_USED_ADDR + 64'd2, 16'd2, "virtio_queue_write_used_idx");
        expect_ram_u32(VQ_USED_ADDR + 64'd12, 32'd0, "virtio_queue_write_used_id");
        expect_ram_u32(VQ_USED_ADDR + 64'd16, 32'd1, "virtio_queue_write_used_len");
        expect_read32(VIRTIO_BASE + 64'h060, 32'd1, "virtio_queue_write_interrupt_status");
        cbus_write32(VIRTIO_BASE + 64'h064, 32'd1);

        for (int word_idx = 0; word_idx < 64; word_idx += 1) begin
            ram_write_word(DMA_ADDR + 64'(word_idx * 8), 64'd0);
        end
        cbus_write(VIRTIO_BASE + 64'h100, 64'd4);
        cbus_write(VIRTIO_BASE + 64'h108, DMA_ADDR);
        cbus_write(VIRTIO_BASE + 64'h110, 64'd1);
        expect_read(VIRTIO_BASE + 64'h118, 64'd0, "virtio_queue_write_verify_read_status");
        for (int word_idx = 0; word_idx < 64; word_idx += 1) begin
            word_t data;
            data = ram_read_word(DMA_ADDR + 64'(word_idx * 8));
            if (data !== pattern(word_idx)) begin
                $fatal(1, "virtqueue write verify word %0d read %h expected %h",
                    word_idx, data, pattern(word_idx));
            end
        end
        $display("virtio_queue_write_data [OK]");

        for (int word_idx = 0; word_idx < 64; word_idx += 1) begin
            ram_write_word(VQ_BUF_ADDR + 64'(word_idx * 8), 64'd0);
        end
        write_blk_request(32'd0, 64'd7);
        ram_write_byte(VQ_STATUS_ADDR, 8'hff);
        write_desc_at(VQ_INDIRECT_ADDR, 0, VQ_REQ_ADDR, 32'd16, VIRTQ_DESC_F_NEXT, 16'd1);
        write_desc_at(
            VQ_INDIRECT_ADDR, 1, VQ_BUF_ADDR, 32'd512,
            VIRTQ_DESC_F_NEXT | VIRTQ_DESC_F_WRITE, 16'd2
        );
        write_desc_at(VQ_INDIRECT_ADDR, 2, VQ_STATUS_ADDR, 32'd1, VIRTQ_DESC_F_WRITE, 16'd0);
        write_desc(3, VQ_INDIRECT_ADDR, 32'd48, VIRTQ_DESC_F_INDIRECT, 16'd0);
        ram_write_u16(VQ_AVAIL_ADDR + 64'd20, 16'd2);
        ram_write_u16(VQ_AVAIL_ADDR + 64'd8, 16'd3);
        ram_write_u16(VQ_AVAIL_ADDR + 64'd2, 16'd3);
        cbus_write32(VIRTIO_BASE + 64'h050, 32'd0);
        expect_ram_byte(VQ_STATUS_ADDR, 8'd0, "virtio_queue_indirect_read_status");
        expect_ram_u16(VQ_USED_ADDR + 64'd2, 16'd3, "virtio_queue_indirect_used_idx");
        expect_ram_u32(VQ_USED_ADDR + 64'd20, 32'd3, "virtio_queue_indirect_used_id");
        expect_ram_u32(VQ_USED_ADDR + 64'd24, 32'd513, "virtio_queue_indirect_used_len");
        expect_read32(VIRTIO_BASE + 64'h060, 32'd1, "virtio_queue_indirect_interrupt_status");
        for (int word_idx = 0; word_idx < 64; word_idx += 1) begin
            word_t data;
            data = ram_read_word(VQ_BUF_ADDR + 64'(word_idx * 8));
            if (data !== image_pattern(7 * 64 + word_idx)) begin
                $fatal(1, "virtqueue indirect word %0d read %h expected %h",
                    word_idx, data, image_pattern(7 * 64 + word_idx));
            end
        end
        $display("virtio_queue_indirect_read_data [OK]");
        cbus_write32(VIRTIO_BASE + 64'h064, 32'd1);

        for (int word_idx = 0; word_idx < 64; word_idx += 1) begin
            ram_write_word(VQ_BUF_ADDR + 64'(word_idx * 8), 64'd0);
            ram_write_word(VQ_BUF2_ADDR + 64'(word_idx * 8), 64'd0);
        end
        write_blk_request_at(VQ_REQ_ADDR, 32'd0, 64'd10);
        write_blk_request_at(VQ_REQ2_ADDR, 32'd0, 64'd11);
        ram_write_byte(VQ_STATUS_ADDR, 8'hff);
        ram_write_byte(VQ_STATUS2_ADDR, 8'hff);
        write_desc(0, VQ_REQ_ADDR, 32'd16, VIRTQ_DESC_F_NEXT, 16'd1);
        write_desc(1, VQ_BUF_ADDR, 32'd512, VIRTQ_DESC_F_NEXT | VIRTQ_DESC_F_WRITE, 16'd2);
        write_desc(2, VQ_STATUS_ADDR, 32'd1, VIRTQ_DESC_F_WRITE, 16'd0);
        write_desc(3, VQ_REQ2_ADDR, 32'd16, VIRTQ_DESC_F_NEXT, 16'd4);
        write_desc(4, VQ_BUF2_ADDR, 32'd512, VIRTQ_DESC_F_NEXT | VIRTQ_DESC_F_WRITE, 16'd5);
        write_desc(5, VQ_STATUS2_ADDR, 32'd1, VIRTQ_DESC_F_WRITE, 16'd0);
        ram_write_u16(VQ_AVAIL_ADDR + 64'd20, 16'd4);
        ram_write_u16(VQ_AVAIL_ADDR + 64'd10, 16'd0);
        ram_write_u16(VQ_AVAIL_ADDR + 64'd12, 16'd3);
        ram_write_u16(VQ_AVAIL_ADDR + 64'd2, 16'd5);
        cbus_write32(VIRTIO_BASE + 64'h050, 32'd0);
        expect_ram_byte(VQ_STATUS_ADDR, 8'd0, "virtio_queue_multi_first_status");
        expect_ram_byte(VQ_STATUS2_ADDR, 8'd0, "virtio_queue_multi_second_status");
        expect_ram_u16(VQ_USED_ADDR + 64'd2, 16'd5, "virtio_queue_multi_used_idx");
        expect_ram_u32(VQ_USED_ADDR + 64'd28, 32'd0, "virtio_queue_multi_first_used_id");
        expect_ram_u32(VQ_USED_ADDR + 64'd32, 32'd513, "virtio_queue_multi_first_used_len");
        expect_ram_u32(VQ_USED_ADDR + 64'd36, 32'd3, "virtio_queue_multi_second_used_id");
        expect_ram_u32(VQ_USED_ADDR + 64'd40, 32'd513, "virtio_queue_multi_second_used_len");
        expect_read32(VIRTIO_BASE + 64'h060, 32'd1, "virtio_queue_multi_interrupt_status");
        for (int word_idx = 0; word_idx < 64; word_idx += 1) begin
            word_t data;
            data = ram_read_word(VQ_BUF_ADDR + 64'(word_idx * 8));
            if (data !== image_pattern(10 * 64 + word_idx)) begin
                $fatal(1, "virtqueue multi first word %0d read %h expected %h",
                    word_idx, data, image_pattern(10 * 64 + word_idx));
            end
            data = ram_read_word(VQ_BUF2_ADDR + 64'(word_idx * 8));
            if (data !== image_pattern(11 * 64 + word_idx)) begin
                $fatal(1, "virtqueue multi second word %0d read %h expected %h",
                    word_idx, data, image_pattern(11 * 64 + word_idx));
            end
        end
        $display("virtio_queue_multi_first_read_data [OK]");
        $display("virtio_queue_multi_second_read_data [OK]");
        cbus_write32(VIRTIO_BASE + 64'h064, 32'd1);

        for (int word_idx = 0; word_idx < 64; word_idx += 1) begin
            ram_write_word(VQ_BUF_ADDR + 64'(word_idx * 8), 64'd0);
        end
        write_blk_request(32'd0, 64'd8);
        ram_write_byte(VQ_STATUS_ADDR, 8'hff);
        write_desc(4, VQ_REQ_ADDR, 32'd16, VIRTQ_DESC_F_NEXT, 16'd5);
        write_desc(5, VQ_BUF_ADDR, 32'd512, VIRTQ_DESC_F_NEXT | VIRTQ_DESC_F_WRITE, 16'd6);
        write_desc(6, VQ_STATUS_ADDR, 32'd1, VIRTQ_DESC_F_WRITE, 16'd0);
        ram_write_u16(VQ_AVAIL_ADDR + 64'd20, 16'd6);
        ram_write_u16(VQ_AVAIL_ADDR + 64'd14, 16'd4);
        ram_write_u16(VQ_AVAIL_ADDR + 64'd2, 16'd6);
        cbus_write32(VIRTIO_BASE + 64'h050, 32'd0);
        expect_ram_byte(VQ_STATUS_ADDR, 8'd0, "virtio_event_idx_suppressed_status");
        expect_ram_u16(VQ_USED_ADDR + 64'd2, 16'd6, "virtio_event_idx_suppressed_used_idx");
        expect_read32(VIRTIO_BASE + 64'h060, 32'd0, "virtio_event_idx_suppresses_interrupt");
        for (int word_idx = 0; word_idx < 64; word_idx += 1) begin
            word_t data;
            data = ram_read_word(VQ_BUF_ADDR + 64'(word_idx * 8));
            if (data !== image_pattern(8 * 64 + word_idx)) begin
                $fatal(1, "virtqueue event suppressed word %0d read %h expected %h",
                    word_idx, data, image_pattern(8 * 64 + word_idx));
            end
        end
        $display("virtio_event_idx_suppressed_read_data [OK]");

        for (int word_idx = 0; word_idx < 64; word_idx += 1) begin
            ram_write_word(VQ_BUF_ADDR + 64'(word_idx * 8), 64'd0);
        end
        write_blk_request(32'd0, 64'd9);
        ram_write_byte(VQ_STATUS_ADDR, 8'hff);
        ram_write_u16(VQ_AVAIL_ADDR + 64'd20, 16'd6);
        ram_write_u16(VQ_AVAIL_ADDR + 64'd16, 16'd4);
        ram_write_u16(VQ_AVAIL_ADDR + 64'd2, 16'd7);
        cbus_write32(VIRTIO_BASE + 64'h050, 32'd0);
        expect_ram_byte(VQ_STATUS_ADDR, 8'd0, "virtio_event_idx_triggered_status");
        expect_ram_u16(VQ_USED_ADDR + 64'd2, 16'd7, "virtio_event_idx_triggered_used_idx");
        expect_read32(VIRTIO_BASE + 64'h060, 32'd1, "virtio_event_idx_triggers_interrupt");
        for (int word_idx = 0; word_idx < 64; word_idx += 1) begin
            word_t data;
            data = ram_read_word(VQ_BUF_ADDR + 64'(word_idx * 8));
            if (data !== image_pattern(9 * 64 + word_idx)) begin
                $fatal(1, "virtqueue event triggered word %0d read %h expected %h",
                    word_idx, data, image_pattern(9 * 64 + word_idx));
            end
        end
        $display("virtio_event_idx_triggered_read_data [OK]");
        cbus_write32(VIRTIO_BASE + 64'h070, 32'd0);
        expect_read32(VIRTIO_BASE + 64'h070, 32'd0, "virtio_reset_status");
        expect_read32(VIRTIO_BASE + 64'h060, 32'd0, "virtio_reset_interrupt_status");
        expect_read32(VIRTIO_BASE + 64'h014, 32'd0, "virtio_reset_device_features_sel");
        expect_read32(VIRTIO_BASE + 64'h020, 32'd0, "virtio_reset_driver_features");
        expect_read32(VIRTIO_BASE + 64'h024, 32'd0, "virtio_reset_driver_features_sel");
        expect_read32(VIRTIO_BASE + 64'h038, 32'd0, "virtio_reset_queue_num");
        expect_read32(VIRTIO_BASE + 64'h044, 32'd0, "virtio_reset_queue_ready");
        expect_read32(VIRTIO_BASE + 64'h080, 32'd0, "virtio_reset_queue_desc_low");
        expect_read32(VIRTIO_BASE + 64'h0fc, 32'd0, "virtio_config_generation_after_reset");
        expect_read(VIRTIO_BASE + 64'h118, 64'd0, "virtio_reset_simple_block_status");

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
