`ifndef __SIM_MEMORY_WITH_VIRTIO_SV
`define __SIM_MEMORY_WITH_VIRTIO_SV

`ifdef VERILATOR
`include "include/common.sv"
`endif

module SimMemoryWithVirtio
    import common::*;
(
    input  logic clk,
    input  logic reset,
    input  cbus_req_t oreq,
    output cbus_resp_t oresp,
    output logic trint,
    output logic swint,
    output logic exint,
    output logic uart_out_valid,
    output logic [7:0] uart_out_ch,
    output logic uart_in_valid,
    input  logic [7:0] uart_in_ch
);
    localparam addr_t UART_BASE = 64'h0000_0000_1000_0000;
    localparam addr_t UART_END  = 64'h0000_0000_1000_0100;

    localparam addr_t PLIC_BASE = 64'h0000_0000_0c00_0000;
    localparam addr_t PLIC_END  = 64'h0000_0000_1000_0000;
    localparam int PLIC_SOURCES = 16;
    localparam int PLIC_VIRTIO_SOURCE = 1;
    localparam int PLIC_UART_SOURCE = 10;

    localparam addr_t VIRTIO_BASE = 64'h0000_0000_1000_1000;
    localparam addr_t VIRTIO_MASK = 64'hffff_ffff_ffff_fe00;
    localparam word_t VIRTIO_MAGIC_VERSION = {32'd2, 32'h7472_6976};
    localparam word_t VIRTIO_DEVICE_VENDOR = {32'h554d_4551, 32'd2};
    localparam int VIRTQ_NUM_MAX = 8;
    localparam u16 VIRTQ_DESC_F_NEXT = 16'h0001;
    localparam u16 VIRTQ_DESC_F_WRITE = 16'h0002;
    localparam u16 VIRTQ_DESC_F_INDIRECT = 16'h0004;
    localparam u32 VIRTIO_BLK_FEATURE_SIZE_MAX = 32'h0000_0002;
    localparam u32 VIRTIO_BLK_FEATURE_SEG_MAX = 32'h0000_0004;
    localparam u32 VIRTIO_BLK_FEATURE_BLK_SIZE = 32'h0000_0040;
    localparam u32 VIRTIO_FEATURE_RING_INDIRECT = 32'h1000_0000;
    localparam u32 VIRTIO_FEATURE_RING_EVENT_IDX = 32'h2000_0000;
    localparam u32 VIRTIO_BLK_FEATURES_SEL0 =
        VIRTIO_BLK_FEATURE_SIZE_MAX | VIRTIO_BLK_FEATURE_SEG_MAX | VIRTIO_BLK_FEATURE_BLK_SIZE;
    localparam u32 VIRTIO_FEATURES_SEL0 =
        VIRTIO_BLK_FEATURES_SEL0 | VIRTIO_FEATURE_RING_INDIRECT | VIRTIO_FEATURE_RING_EVENT_IDX;
    localparam u32 VIRTIO_FEATURES_SEL1 = 32'h0000_0001;
    localparam u32 VIRTIO_MMIO_INT_VRING = 32'h0000_0001;
    localparam u32 VIRTIO_STATUS_FEATURES_OK = 32'h0000_0008;
    localparam u32 VIRTIO_BLK_T_IN = 32'd0;
    localparam u32 VIRTIO_BLK_T_OUT = 32'd1;
    localparam u8 VIRTIO_BLK_S_OK = 8'd0;
    localparam u8 VIRTIO_BLK_S_IOERR = 8'd1;
    localparam u8 VIRTIO_BLK_S_UNSUPP = 8'd2;
    localparam int SIMPLE_BLK_SECTORS = 16;
    localparam int SIMPLE_BLK_WORDS_PER_SECTOR = 64;
    localparam int SIMPLE_BLK_WORDS = SIMPLE_BLK_SECTORS * SIMPLE_BLK_WORDS_PER_SECTOR;
    localparam int SIMPLE_BLK_BYTES = SIMPLE_BLK_WORDS * 8;
    localparam int UART_RX_FIFO_DEPTH = 16;
    localparam int UART_RX_FIFO_INDEX_BITS = $clog2(UART_RX_FIFO_DEPTH);
    localparam int UART_RX_FIFO_COUNT_BITS = $clog2(UART_RX_FIFO_DEPTH + 1);
    localparam int UART_RX_TIMEOUT_CYCLES = 16;
    localparam int UART_RX_TIMEOUT_BITS = $clog2(UART_RX_TIMEOUT_CYCLES + 1);

    cbus_req_t ram_req;
    cbus_resp_t ram_resp;
    cbus_req_t local_saved_req;
    logic local_req_active;
    logic ram_exint, plic_irq_m, plic_irq_s;
    word_t blk_sector, blk_mem_addr, blk_cmd, blk_status;
    u32 virt_device_features_sel, virt_driver_features_sel;
    u32 virt_driver_features_sel0, virt_driver_features_sel1;
    u32 virt_queue_sel, virt_queue_num, virt_queue_ready, virt_status;
    u32 virt_interrupt_status, virt_config_generation;
    addr_t virt_queue_desc, virt_queue_driver, virt_queue_device;
    u16 virt_last_avail_idx;
    word_t disk_init [SIMPLE_BLK_WORDS];
    word_t disk [SIMPLE_BLK_WORDS];
    byte unsigned blk_image_bytes [SIMPLE_BLK_BYTES];
    logic disk_init_loaded = 1'b0;
    word_t plic_priority [PLIC_SOURCES:0];
    logic [PLIC_SOURCES:0] plic_pending, plic_enable_m, plic_enable_s;
    logic [PLIC_SOURCES:0] plic_claim_clear_mask;
    word_t plic_threshold_m, plic_threshold_s;
    u8 uart_ier, uart_fcr, uart_lcr, uart_mcr, uart_scr, uart_dll, uart_dlm;
    u8 uart_rx_fifo [UART_RX_FIFO_DEPTH];
    logic [UART_RX_FIFO_INDEX_BITS-1:0] uart_rx_head, uart_rx_tail;
    logic [UART_RX_FIFO_COUNT_BITS-1:0] uart_rx_count, uart_rx_count_next;
    logic [UART_RX_TIMEOUT_BITS-1:0] uart_rx_timeout_count;
    logic uart_rx_valid, uart_rx_full;
    logic uart_rx_pop_req, uart_rx_pop_valid, uart_rx_push_req, uart_rx_overrun_req;
    logic uart_lsr_overrun, uart_lsr_read_req, uart_iir_read_req;
    logic uart_rx_irq_active, uart_rx_irq_next_active, uart_rx_timeout_irq_active;
    logic uart_rx_timeout_pending, uart_rx_fifo_activity;
    logic uart_thr_irq_pending, uart_iir_reports_thre;

    RAMHelper2 ram(
        .clk(clk),
        .reset(reset),
        .oreq(ram_req),
        .oresp(ram_resp),
        .trint(trint),
        .swint(swint),
        .exint(ram_exint)
    );

    assign exint = ram_exint || plic_irq_m || plic_irq_s;
    assign uart_rx_valid = (uart_rx_count != '0);
    assign uart_rx_full = (uart_rx_count == UART_RX_FIFO_COUNT_BITS'(UART_RX_FIFO_DEPTH));
    assign uart_in_valid = !uart_rx_full;
    assign uart_rx_push_req = (uart_in_ch != 8'hff) && (!uart_rx_full || uart_rx_pop_valid);
    assign uart_rx_overrun_req = (uart_in_ch != 8'hff) && uart_rx_full && !uart_rx_pop_valid;

    function automatic logic uart_rx_threshold_met_for(
        input logic [1:0] trigger,
        input logic [UART_RX_FIFO_COUNT_BITS-1:0] count
    );
        unique case (trigger)
            2'b00: uart_rx_threshold_met_for = (count >= UART_RX_FIFO_COUNT_BITS'(1));
            2'b01: uart_rx_threshold_met_for = (count >= UART_RX_FIFO_COUNT_BITS'(4));
            2'b10: uart_rx_threshold_met_for = (count >= UART_RX_FIFO_COUNT_BITS'(8));
            2'b11: uart_rx_threshold_met_for = (count >= UART_RX_FIFO_COUNT_BITS'(14));
            default: uart_rx_threshold_met_for = 1'b0;
        endcase
    endfunction

    function automatic logic uart_rx_threshold_met(
        input logic [UART_RX_FIFO_COUNT_BITS-1:0] count
    );
        uart_rx_threshold_met = uart_rx_threshold_met_for(uart_fcr[7:6], count);
    endfunction

    always_comb begin
        uart_rx_count_next = uart_rx_count;
        unique case ({uart_rx_push_req, uart_rx_pop_valid})
            2'b10: uart_rx_count_next = uart_rx_count + 1'b1;
            2'b01: uart_rx_count_next = uart_rx_count - 1'b1;
            default: begin end
        endcase
    end

    assign uart_rx_irq_active = uart_ier[0] && uart_rx_threshold_met(uart_rx_count);
    assign uart_rx_irq_next_active = uart_ier[0] && uart_rx_threshold_met(uart_rx_count_next);
    assign uart_rx_timeout_irq_active = uart_ier[0] && uart_rx_timeout_pending && uart_rx_valid;
    assign uart_rx_fifo_activity = uart_rx_push_req || uart_rx_pop_valid;
    assign uart_iir_reports_thre = uart_thr_irq_pending &&
        !(uart_lsr_overrun && uart_ier[2]) && !uart_rx_irq_active &&
        !uart_rx_timeout_irq_active;

    function automatic logic is_uart_addr(input addr_t addr);
        is_uart_addr = (addr >= UART_BASE) && (addr < UART_END);
    endfunction

    function automatic logic is_plic_addr(input addr_t addr);
        is_plic_addr = (addr >= PLIC_BASE) && (addr < PLIC_END);
    endfunction

    function automatic logic is_virtio_addr(input addr_t addr);
        is_virtio_addr = ((addr & VIRTIO_MASK) == VIRTIO_BASE);
    endfunction

    function automatic logic is_local_addr(input addr_t addr);
        is_local_addr = is_uart_addr(addr) || is_virtio_addr(addr) || is_plic_addr(addr);
    endfunction

    function automatic logic same_local_req(input cbus_req_t req, input cbus_req_t saved_req);
        same_local_req =
            (req.is_write == saved_req.is_write) &&
            (req.is_instr == saved_req.is_instr) &&
            (req.size == saved_req.size) &&
            (req.addr == saved_req.addr) &&
            (req.strobe == saved_req.strobe) &&
            (req.data == saved_req.data) &&
            (req.len == saved_req.len) &&
            (req.burst == saved_req.burst);
    endfunction

    function automatic addr_t ram_idx(input addr_t addr);
        ram_idx = (addr > 64'h8000_0000) ? ((addr - 64'h8000_0000) >> 3) : 64'd0;
    endfunction

    function automatic word_t simple_blk_default_word(input int idx);
        simple_blk_default_word = 64'h5342_4c4b_0000_0000 | 64'(idx);
    endfunction

    task automatic load_disk_init();
        string image_path;
        int image_fd;
        int bytes_read;
        int byte_offset;
        begin
            for (int i = 0; i < SIMPLE_BLK_WORDS; i += 1) begin
                disk_init[i] = simple_blk_default_word(i);
            end
            if ($value$plusargs("simple_blk_image=%s", image_path)) begin
                image_fd = $fopen(image_path, "rb");
                if (image_fd == 0) begin
                    $fatal(1, "failed to open simple block image: %s", image_path);
                end
                bytes_read = $fread(blk_image_bytes, image_fd);
                $fclose(image_fd);
                for (int word_idx = 0; word_idx < SIMPLE_BLK_WORDS; word_idx += 1) begin
                    for (int byte_idx = 0; byte_idx < 8; byte_idx += 1) begin
                        byte_offset = word_idx * 8 + byte_idx;
                        if (byte_offset < bytes_read) begin
                            disk_init[word_idx][byte_idx * 8 +: 8] = blk_image_bytes[byte_offset];
                        end
                    end
                end
                $display("simple block image loaded: %s (%0d bytes, capacity %0d bytes)",
                    image_path, bytes_read, SIMPLE_BLK_BYTES);
            end
        end
    endtask

    function automatic strobe_t size_strobe(input msize_t size, input logic [2:0] ofs);
        unique case (size)
            MSIZE1: size_strobe = 8'b0000_0001 << ofs;
            MSIZE2: size_strobe = 8'b0000_0011 << ofs;
            MSIZE4: size_strobe = 8'b0000_1111 << ofs;
            default: size_strobe = 8'b1111_1111;
        endcase
    endfunction

    function automatic u8 ram_read_byte_addr(input addr_t addr);
        word_t data;
        int shift;
        begin
            data = word_t'(ram_read_helper(1'b1, ram_idx(addr)));
            shift = int'(addr[2:0]) * 8;
            ram_read_byte_addr = u8'(data >> shift);
        end
    endfunction

    function automatic u16 ram_read_u16_addr(input addr_t addr);
        ram_read_u16_addr = '0;
        for (int byte_idx = 0; byte_idx < 2; byte_idx += 1) begin
            ram_read_u16_addr[byte_idx * 8 +: 8] = ram_read_byte_addr(addr + 64'(byte_idx));
        end
    endfunction

    function automatic u32 ram_read_u32_addr(input addr_t addr);
        ram_read_u32_addr = '0;
        for (int byte_idx = 0; byte_idx < 4; byte_idx += 1) begin
            ram_read_u32_addr[byte_idx * 8 +: 8] = ram_read_byte_addr(addr + 64'(byte_idx));
        end
    endfunction

    function automatic word_t ram_read_u64_addr(input addr_t addr);
        ram_read_u64_addr = '0;
        for (int byte_idx = 0; byte_idx < 8; byte_idx += 1) begin
            ram_read_u64_addr[byte_idx * 8 +: 8] = ram_read_byte_addr(addr + 64'(byte_idx));
        end
    endfunction

    task automatic ram_write_byte_addr(input addr_t addr, input u8 data);
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

    task automatic ram_write_u16_addr(input addr_t addr, input u16 data);
        for (int byte_idx = 0; byte_idx < 2; byte_idx += 1) begin
            ram_write_byte_addr(addr + 64'(byte_idx), data[byte_idx * 8 +: 8]);
        end
    endtask

    task automatic ram_write_u32_addr(input addr_t addr, input u32 data);
        for (int byte_idx = 0; byte_idx < 4; byte_idx += 1) begin
            ram_write_byte_addr(addr + 64'(byte_idx), data[byte_idx * 8 +: 8]);
        end
    endtask

    function automatic u8 uart_reg_read_byte(input addr_t addr);
        logic [7:0] offset;
        logic dlab;
        begin
            offset = u8'(addr - UART_BASE);
            dlab = uart_lcr[7];
            unique case (offset[2:0])
                3'h0: uart_reg_read_byte = dlab ? uart_dll :
                    (uart_rx_valid ? uart_rx_fifo[uart_rx_head] : 8'd0);
                3'h1: uart_reg_read_byte = dlab ? uart_dlm : uart_ier;
                3'h2: uart_reg_read_byte = (uart_lsr_overrun && uart_ier[2]) ? 8'h06 :
                    (uart_rx_irq_active ? 8'h04 :
                    (uart_rx_timeout_irq_active ? 8'h0c :
                    (uart_thr_irq_pending ? 8'h02 : 8'h01)));
                3'h3: uart_reg_read_byte = uart_lcr;
                3'h4: uart_reg_read_byte = uart_mcr;
                3'h5: uart_reg_read_byte = {
                    uart_lsr_overrun, 2'b11, 3'b000, uart_lsr_overrun, uart_rx_valid
                };
                3'h6: uart_reg_read_byte = 8'd0;
                3'h7: uart_reg_read_byte = uart_scr;
                default: uart_reg_read_byte = 8'd0;
            endcase
        end
    endfunction

    function automatic word_t uart_read(input addr_t addr);
        addr_t aligned_addr;
        begin
            aligned_addr = {addr[63:3], 3'b000};
            for (int byte_idx = 0; byte_idx < 8; byte_idx += 1) begin
                uart_read[byte_idx * 8 +: 8] = uart_reg_read_byte(aligned_addr + 64'(byte_idx));
            end
        end
    endfunction

    task automatic uart_write_byte(input addr_t addr, input u8 data);
        logic [7:0] offset;
        logic dlab;
        begin
            offset = u8'(addr - UART_BASE);
            dlab = uart_lcr[7];
            unique case (offset[2:0])
                3'h0: begin
                    if (dlab) begin
                        uart_dll <= data;
                    end
                    else begin
                        uart_out_valid <= 1'b1;
                        uart_out_ch <= data;
                        if (uart_ier[1]) begin
                            uart_thr_irq_pending <= 1'b1;
                            plic_pending[PLIC_UART_SOURCE] <= 1'b1;
                        end
                    end
                end
                3'h1: begin
                    if (dlab) begin
                        uart_dlm <= data;
                    end
                    else begin
                        uart_ier <= data;
                        if (data[1]) begin
                            uart_thr_irq_pending <= 1'b1;
                            plic_pending[PLIC_UART_SOURCE] <= 1'b1;
                        end
                        else begin
                            uart_thr_irq_pending <= 1'b0;
                        end
                        if ((data[0] && uart_rx_threshold_met(uart_rx_count)) ||
                            (data[0] && uart_rx_timeout_pending && uart_rx_valid) ||
                            (data[2] && uart_lsr_overrun)) begin
                            plic_pending[PLIC_UART_SOURCE] <= 1'b1;
                        end
                    end
                end
                3'h2: begin
                    uart_fcr <= data;
                    if (data[1]) begin
                        uart_rx_head <= '0;
                        uart_rx_tail <= '0;
                        uart_rx_count <= '0;
                        uart_rx_timeout_count <= '0;
                        uart_rx_timeout_pending <= 1'b0;
                        uart_lsr_overrun <= 1'b0;
                    end
                    else if (uart_ier[0] &&
                        uart_rx_threshold_met_for(data[7:6], uart_rx_count)) begin
                        plic_pending[PLIC_UART_SOURCE] <= 1'b1;
                    end
                end
                3'h3: uart_lcr <= data;
                3'h4: uart_mcr <= data;
                3'h7: uart_scr <= data;
                default: begin end
            endcase
        end
    endtask

    task automatic uart_write(input addr_t addr, input word_t data, input strobe_t strobe);
        addr_t aligned_addr;
        begin
            aligned_addr = {addr[63:3], 3'b000};
            for (int byte_idx = 0; byte_idx < 8; byte_idx += 1) begin
                if (strobe[byte_idx]) begin
                    uart_write_byte(aligned_addr + 64'(byte_idx), data[byte_idx * 8 +: 8]);
                end
            end
        end
    endtask

    function automatic logic uart_addr_is_rx_read(input addr_t addr);
        logic [7:0] offset;
        begin
            offset = u8'(addr - UART_BASE);
            uart_addr_is_rx_read = (offset[2:0] == 3'h0) && !uart_lcr[7];
        end
    endfunction

    function automatic logic uart_read_pops_rx(input addr_t addr, input msize_t size);
        addr_t aligned_addr;
        strobe_t read_mask;
        begin
            aligned_addr = {addr[63:3], 3'b000};
            read_mask = size_strobe(size, addr[2:0]);
            uart_read_pops_rx = 1'b0;
            for (int byte_idx = 0; byte_idx < 8; byte_idx += 1) begin
                if (read_mask[byte_idx] && uart_addr_is_rx_read(aligned_addr + 64'(byte_idx))) begin
                    uart_read_pops_rx = 1'b1;
                end
            end
        end
    endfunction

    function automatic logic uart_read_touches_lsr(input addr_t addr, input msize_t size);
        addr_t aligned_addr;
        strobe_t read_mask;
        begin
            aligned_addr = {addr[63:3], 3'b000};
            read_mask = size_strobe(size, addr[2:0]);
            uart_read_touches_lsr = 1'b0;
            for (int byte_idx = 0; byte_idx < 8; byte_idx += 1) begin
                if (read_mask[byte_idx] &&
                    (((aligned_addr + 64'(byte_idx) - UART_BASE) & 64'h7) == 64'h5)) begin
                    uart_read_touches_lsr = 1'b1;
                end
            end
        end
    endfunction

    function automatic logic uart_read_touches_iir(input addr_t addr, input msize_t size);
        addr_t aligned_addr;
        strobe_t read_mask;
        begin
            aligned_addr = {addr[63:3], 3'b000};
            read_mask = size_strobe(size, addr[2:0]);
            uart_read_touches_iir = 1'b0;
            for (int byte_idx = 0; byte_idx < 8; byte_idx += 1) begin
                if (read_mask[byte_idx] &&
                    (((aligned_addr + 64'(byte_idx) - UART_BASE) & 64'h7) == 64'h2)) begin
                    uart_read_touches_iir = 1'b1;
                end
            end
        end
    endfunction

    assign uart_rx_pop_req = oreq.valid && is_uart_addr(oreq.addr) &&
        !oreq.is_write && uart_read_pops_rx(oreq.addr, oreq.size);
    assign uart_rx_pop_valid = uart_rx_pop_req && uart_rx_valid;
    assign uart_lsr_read_req = oreq.valid && is_uart_addr(oreq.addr) &&
        !oreq.is_write && uart_read_touches_lsr(oreq.addr, oreq.size);
    assign uart_iir_read_req = oreq.valid && is_uart_addr(oreq.addr) &&
        !oreq.is_write && uart_read_touches_iir(oreq.addr, oreq.size);

    function automatic u32 plic_pending_word();
        plic_pending_word = '0;
        for (int source = 1; source <= PLIC_SOURCES; source += 1) begin
            plic_pending_word[source] = plic_pending[source];
        end
    endfunction

    function automatic u32 plic_enable_word(input logic use_s_context);
        plic_enable_word = '0;
        for (int source = 1; source <= PLIC_SOURCES; source += 1) begin
            plic_enable_word[source] = use_s_context ? plic_enable_s[source] : plic_enable_m[source];
        end
    endfunction

    function automatic int plic_best_source(input logic use_s_context);
        int best;
        word_t best_priority;
        word_t threshold;
        logic source_enabled;
        begin
            best = 0;
            best_priority = 64'd0;
            threshold = use_s_context ? plic_threshold_s : plic_threshold_m;
            for (int source = 1; source <= PLIC_SOURCES; source += 1) begin
                source_enabled = use_s_context ? plic_enable_s[source] : plic_enable_m[source];
                if (plic_pending[source] && source_enabled &&
                    (plic_priority[source] > threshold) &&
                    (plic_priority[source] > best_priority)) begin
                    best = source;
                    best_priority = plic_priority[source];
                end
            end
            plic_best_source = best;
        end
    endfunction

    function automatic u32 plic_reg32_read(input addr_t addr);
        addr_t offset;
        int source, ctx;
        begin
            offset = addr - PLIC_BASE;
            plic_reg32_read = 32'd0;
            if (offset < 64'h1000) begin
                source = int'(offset[11:2]);
                if ((source > 0) && (source <= PLIC_SOURCES)) begin
                    plic_reg32_read = u32'(plic_priority[source]);
                end
            end
            else if ((offset >= 64'h1000) && (offset < 64'h1080)) begin
                if (offset[6:2] == 5'd0) begin
                    plic_reg32_read = plic_pending_word();
                end
            end
            else if ((offset >= 64'h2000) && (offset < 64'h3000)) begin
                ctx = int'((offset - 64'h2000) >> 7);
                if (((offset - 64'h2000) & 64'h7f) == 64'd0) begin
                    unique case (ctx)
                        0: plic_reg32_read = plic_enable_word(1'b0);
                        1: plic_reg32_read = plic_enable_word(1'b1);
                        default: plic_reg32_read = 32'd0;
                    endcase
                end
            end
            else if ((offset >= 64'h200000) && (offset < 64'h202000)) begin
                ctx = int'((offset - 64'h200000) >> 12);
                if (((offset - 64'h200000) & 64'hfff) == 64'h000) begin
                    unique case (ctx)
                        0: plic_reg32_read = u32'(plic_threshold_m);
                        1: plic_reg32_read = u32'(plic_threshold_s);
                        default: plic_reg32_read = 32'd0;
                    endcase
                end
                else if (((offset - 64'h200000) & 64'hfff) == 64'h004) begin
                    unique case (ctx)
                        0: plic_reg32_read = u32'(plic_best_source(1'b0));
                        1: plic_reg32_read = u32'(plic_best_source(1'b1));
                        default: plic_reg32_read = 32'd0;
                    endcase
                end
            end
        end
    endfunction

    function automatic word_t plic_read(input addr_t addr);
        addr_t aligned_addr;
        aligned_addr = {addr[63:3], 3'b000};
        plic_read = {plic_reg32_read(aligned_addr + 64'd4), plic_reg32_read(aligned_addr)};
    endfunction

    task automatic plic_write32(input addr_t addr, input u32 data);
        addr_t offset;
        int source, ctx;
        begin
            offset = addr - PLIC_BASE;
            if (offset < 64'h1000) begin
                source = int'(offset[11:2]);
                if ((source > 0) && (source <= PLIC_SOURCES)) begin
                    plic_priority[source] <= {32'd0, data};
                end
            end
            else if ((offset >= 64'h2000) && (offset < 64'h3000)) begin
                ctx = int'((offset - 64'h2000) >> 7);
                if (((offset - 64'h2000) & 64'h7f) == 64'd0) begin
                    unique case (ctx)
                        0: begin
                            for (int source_idx = 1; source_idx <= PLIC_SOURCES; source_idx += 1) begin
                                plic_enable_m[source_idx] <= data[source_idx];
                            end
                        end
                        1: begin
                            for (int source_idx = 1; source_idx <= PLIC_SOURCES; source_idx += 1) begin
                                plic_enable_s[source_idx] <= data[source_idx];
                            end
                        end
                        default: begin end
                    endcase
                end
            end
            else if ((offset >= 64'h200000) && (offset < 64'h202000)) begin
                ctx = int'((offset - 64'h200000) >> 12);
                if (((offset - 64'h200000) & 64'hfff) == 64'h000) begin
                    unique case (ctx)
                        0: plic_threshold_m <= {32'd0, data};
                        1: plic_threshold_s <= {32'd0, data};
                        default: begin end
                    endcase
                end
                else if (((offset - 64'h200000) & 64'hfff) == 64'h004) begin
                    if ((data > 0) && (data <= PLIC_SOURCES)) begin
                        plic_pending[data] <= 1'b0;
                    end
                end
            end
        end
    endtask

    task automatic plic_write(input addr_t addr, input word_t data, input strobe_t strobe);
        addr_t aligned_addr;
        begin
            aligned_addr = {addr[63:3], 3'b000};
            if (|strobe[3:0]) begin
                plic_write32(aligned_addr, data[31:0]);
            end
            if (|strobe[7:4]) begin
                plic_write32(aligned_addr + 64'd4, data[63:32]);
            end
        end
    endtask

    task automatic plic_clear_claim_addr(input addr_t addr);
        addr_t offset;
        int claimed;
        begin
            offset = addr - PLIC_BASE;
            if (offset == 64'h200004) begin
                claimed = plic_best_source(1'b0);
                if (claimed != 0) begin
                    plic_claim_clear_mask[claimed] <= 1'b1;
                end
            end
            else if (offset == 64'h201004) begin
                claimed = plic_best_source(1'b1);
                if (claimed != 0) begin
                    plic_claim_clear_mask[claimed] <= 1'b1;
                end
            end
        end
    endtask

    task automatic plic_read_side_effect(input addr_t addr, input msize_t size);
        addr_t aligned_addr;
        strobe_t read_mask;
        begin
            aligned_addr = {addr[63:3], 3'b000};
            read_mask = size_strobe(size, addr[2:0]);
            if (|read_mask[3:0]) begin
                plic_clear_claim_addr(aligned_addr);
            end
            if (|read_mask[7:4]) begin
                plic_clear_claim_addr(aligned_addr + 64'd4);
            end
        end
    endtask

    task automatic read_virtq_desc_from(
        input addr_t table_base,
        input u16 index,
        output addr_t desc_addr,
        output u32 desc_len,
        output u16 desc_flags,
        output u16 desc_next
    );
        addr_t base;
        begin
            base = table_base + 64'(index) * 64'd16;
            desc_addr = ram_read_u64_addr(base);
            desc_len = ram_read_u32_addr(base + 64'd8);
            desc_flags = ram_read_u16_addr(base + 64'd12);
            desc_next = ram_read_u16_addr(base + 64'd14);
        end
    endtask

    task automatic read_virtq_desc(
        input u16 index,
        output addr_t desc_addr,
        output u32 desc_len,
        output u16 desc_flags,
        output u16 desc_next
    );
        read_virtq_desc_from(virt_queue_desc, index, desc_addr, desc_len, desc_flags, desc_next);
    endtask

    task automatic complete_virtqueue_request(input u16 head, input u32 used_len);
        u16 used_idx;
        u16 next_used_idx;
        u16 used_slot;
        addr_t used_elem_addr;
        logic should_interrupt;
        begin
            used_idx = ram_read_u16_addr(virt_queue_device + 64'd2);
            next_used_idx = used_idx + 16'd1;
            should_interrupt = virtqueue_should_interrupt(used_idx, next_used_idx);
            used_slot = u16'(used_idx % u16'(virt_queue_num[15:0]));
            used_elem_addr = virt_queue_device + 64'd4 + 64'(used_slot) * 64'd8;
            ram_write_u32_addr(used_elem_addr, {16'd0, head});
            ram_write_u32_addr(used_elem_addr + 64'd4, used_len);
            ram_write_u16_addr(virt_queue_device + 64'd2, next_used_idx);
            virt_last_avail_idx <= virt_last_avail_idx + 16'd1;
            if (should_interrupt) begin
                virt_interrupt_status <= virt_interrupt_status | VIRTIO_MMIO_INT_VRING;
                plic_pending[PLIC_VIRTIO_SOURCE] <= 1'b1;
            end
        end
    endtask

    task automatic run_virtqueue_command(input u32 queue_notify);
        u16 avail_idx;
        u16 avail_slot;
        u16 head;
        addr_t desc0_addr, desc1_addr, desc2_addr;
        u32 desc0_len, desc1_len, desc2_len;
        u16 desc0_flags, desc1_flags, desc2_flags;
        u16 desc0_next, desc1_next, desc2_next;
        addr_t desc_table_base;
        u32 indirect_len;
        u16 desc_table_entries;
        u32 req_type;
        word_t req_sector;
        u8 status;
        u32 used_len;
        int disk_base_word;
        word_t write_word;
        logic status_desc_valid;
        begin
            if ((queue_notify != 32'd0) || (virt_queue_sel != 32'd0) ||
                (virt_queue_ready == 32'd0) || (virt_queue_num == 32'd0) ||
                (virt_queue_num > u32'(VIRTQ_NUM_MAX))) begin
                return;
            end

            avail_idx = ram_read_u16_addr(virt_queue_driver + 64'd2);
            if (avail_idx == virt_last_avail_idx) begin
                return;
            end

            avail_slot = u16'(virt_last_avail_idx % u16'(virt_queue_num[15:0]));
            head = ram_read_u16_addr(virt_queue_driver + 64'd4 + 64'(avail_slot) * 64'd2);
            if (head >= u16'(virt_queue_num[15:0])) begin
                return;
            end

            read_virtq_desc(head, desc0_addr, desc0_len, desc0_flags, desc0_next);
            desc_table_base = virt_queue_desc;
            desc_table_entries = u16'(virt_queue_num[15:0]);
            if ((desc0_flags & VIRTQ_DESC_F_INDIRECT) == VIRTQ_DESC_F_INDIRECT) begin
                desc_table_base = desc0_addr;
                indirect_len = desc0_len;
                desc_table_entries = u16'(indirect_len >> 4);
                if ((indirect_len < 32'd48) || (indirect_len[3:0] != 4'd0)) begin
                    desc_table_entries = 16'd0;
                end
                else begin
                    read_virtq_desc_from(desc_table_base, 16'd0,
                        desc0_addr, desc0_len, desc0_flags, desc0_next);
                end
            end
            if (desc0_next < desc_table_entries) begin
                read_virtq_desc_from(desc_table_base, desc0_next,
                    desc1_addr, desc1_len, desc1_flags, desc1_next);
            end
            else begin
                desc1_addr = 64'd0;
                desc1_len = 32'd0;
                desc1_flags = 16'd0;
                desc1_next = 16'd0;
            end
            if (desc1_next < desc_table_entries) begin
                read_virtq_desc_from(desc_table_base, desc1_next,
                    desc2_addr, desc2_len, desc2_flags, desc2_next);
            end
            else begin
                desc2_addr = 64'd0;
                desc2_len = 32'd0;
                desc2_flags = 16'd0;
                desc2_next = 16'd0;
            end
            req_type = ram_read_u32_addr(desc0_addr);
            req_sector = ram_read_u64_addr(desc0_addr + 64'd8);
            status = VIRTIO_BLK_S_IOERR;
            used_len = 32'd1;
            status_desc_valid = (desc2_len >= 32'd1) &&
                ((desc2_flags & VIRTQ_DESC_F_WRITE) == VIRTQ_DESC_F_WRITE);

            if (((desc0_flags & VIRTQ_DESC_F_NEXT) == 16'd0) ||
                ((desc1_flags & VIRTQ_DESC_F_NEXT) == 16'd0) ||
                (desc0_len < 32'd16) || (desc1_len < 32'd512) || (desc2_len < 32'd1) ||
                !status_desc_valid ||
                (req_sector >= 64'(SIMPLE_BLK_SECTORS))) begin
                status = VIRTIO_BLK_S_IOERR;
            end
            else if (req_type == VIRTIO_BLK_T_IN) begin
                if ((desc1_flags & VIRTQ_DESC_F_WRITE) != VIRTQ_DESC_F_WRITE) begin
                    status = VIRTIO_BLK_S_IOERR;
                end
                else begin
                    disk_base_word = int'(req_sector[31:0]) * SIMPLE_BLK_WORDS_PER_SECTOR;
                    for (int word_idx = 0; word_idx < SIMPLE_BLK_WORDS_PER_SECTOR; word_idx += 1) begin
                        for (int byte_idx = 0; byte_idx < 8; byte_idx += 1) begin
                            ram_write_byte_addr(
                                desc1_addr + 64'(word_idx * 8 + byte_idx),
                                disk[disk_base_word + word_idx][byte_idx * 8 +: 8]
                            );
                        end
                    end
                    status = VIRTIO_BLK_S_OK;
                    used_len = 32'd513;
                end
            end
            else if (req_type == VIRTIO_BLK_T_OUT) begin
                if ((desc1_flags & VIRTQ_DESC_F_WRITE) != 16'd0) begin
                    status = VIRTIO_BLK_S_IOERR;
                end
                else begin
                    disk_base_word = int'(req_sector[31:0]) * SIMPLE_BLK_WORDS_PER_SECTOR;
                    for (int word_idx = 0; word_idx < SIMPLE_BLK_WORDS_PER_SECTOR; word_idx += 1) begin
                        write_word = '0;
                        for (int byte_idx = 0; byte_idx < 8; byte_idx += 1) begin
                            write_word[byte_idx * 8 +: 8] =
                                ram_read_byte_addr(desc1_addr + 64'(word_idx * 8 + byte_idx));
                        end
                        disk[disk_base_word + word_idx] <= write_word;
                    end
                    status = VIRTIO_BLK_S_OK;
                end
            end
            else begin
                status = VIRTIO_BLK_S_UNSUPP;
            end

            if (status_desc_valid) begin
                ram_write_byte_addr(desc2_addr, status);
            end
            blk_status <= {56'd0, status};
            complete_virtqueue_request(head, used_len);
        end
    endtask

    function automatic u32 virtio_device_features_selected();
        unique case (virt_device_features_sel)
            32'd0: virtio_device_features_selected = VIRTIO_FEATURES_SEL0;
            32'd1: virtio_device_features_selected = VIRTIO_FEATURES_SEL1;
            default: virtio_device_features_selected = 32'd0;
        endcase
    endfunction

    function automatic u32 virtio_driver_features_selected();
        unique case (virt_driver_features_sel)
            32'd0: virtio_driver_features_selected = virt_driver_features_sel0;
            32'd1: virtio_driver_features_selected = virt_driver_features_sel1;
            default: virtio_driver_features_selected = 32'd0;
        endcase
    endfunction

    function automatic logic virtio_driver_features_supported();
        virtio_driver_features_supported =
            ((virt_driver_features_sel0 & ~VIRTIO_FEATURES_SEL0) == 32'd0) &&
            ((virt_driver_features_sel1 & ~VIRTIO_FEATURES_SEL1) == 32'd0);
    endfunction

    function automatic logic virtio_event_idx_enabled();
        virtio_event_idx_enabled =
            (virt_driver_features_sel0 & VIRTIO_FEATURE_RING_EVENT_IDX) != 32'd0;
    endfunction

    function automatic logic vring_need_event(input u16 event_idx, input u16 new_idx, input u16 old_idx);
        vring_need_event = u16'(new_idx - event_idx - 16'd1) < u16'(new_idx - old_idx);
    endfunction

    function automatic logic virtqueue_should_interrupt(input u16 old_used_idx, input u16 new_used_idx);
        u16 avail_flags;
        u16 used_event;
        begin
            if (virtio_event_idx_enabled()) begin
                used_event = ram_read_u16_addr(virt_queue_driver + 64'd4 + 64'(virt_queue_num[15:0]) * 64'd2);
                virtqueue_should_interrupt = vring_need_event(used_event, new_used_idx, old_used_idx);
            end
            else begin
                avail_flags = ram_read_u16_addr(virt_queue_driver);
                virtqueue_should_interrupt = !avail_flags[0];
            end
        end
    endfunction

    function automatic u32 virtio_reg32_read(input addr_t addr);
        addr_t offset;
        begin
            offset = addr - VIRTIO_BASE;
            unique case (offset)
                64'h000: virtio_reg32_read = 32'h7472_6976;
                64'h004: virtio_reg32_read = 32'd2;
                64'h008: virtio_reg32_read = 32'd2;
                64'h00c: virtio_reg32_read = 32'h554d_4551;
                64'h010: virtio_reg32_read = virtio_device_features_selected();
                64'h014: virtio_reg32_read = virt_device_features_sel;
                64'h020: virtio_reg32_read = virtio_driver_features_selected();
                64'h024: virtio_reg32_read = virt_driver_features_sel;
                64'h030: virtio_reg32_read = virt_queue_sel;
                64'h034: virtio_reg32_read = (virt_queue_sel == 32'd0) ? u32'(VIRTQ_NUM_MAX) : 32'd0;
                64'h038: virtio_reg32_read = virt_queue_num;
                64'h044: virtio_reg32_read = virt_queue_ready;
                64'h060: virtio_reg32_read = virt_interrupt_status;
                64'h070: virtio_reg32_read = virt_status;
                64'h080: virtio_reg32_read = virt_queue_desc[31:0];
                64'h084: virtio_reg32_read = virt_queue_desc[63:32];
                64'h090: virtio_reg32_read = virt_queue_driver[31:0];
                64'h094: virtio_reg32_read = virt_queue_driver[63:32];
                64'h0a0: virtio_reg32_read = virt_queue_device[31:0];
                64'h0a4: virtio_reg32_read = virt_queue_device[63:32];
                64'h0fc: virtio_reg32_read = virt_config_generation;
                64'h100: virtio_reg32_read = u32'(SIMPLE_BLK_SECTORS);
                64'h104: virtio_reg32_read = 32'd0;
                64'h108: virtio_reg32_read = 32'd512;
                64'h10c: virtio_reg32_read = 32'd1;
                64'h114: virtio_reg32_read = 32'd512;
                64'h118: virtio_reg32_read = u32'(blk_status);
                64'h120: virtio_reg32_read = u32'(SIMPLE_BLK_SECTORS);
                64'h128: virtio_reg32_read = 32'd512;
                default: virtio_reg32_read = 32'd0;
            endcase
        end
    endfunction

    function automatic word_t virtio_read(input addr_t addr);
        addr_t aligned_addr;
        begin
            aligned_addr = {addr[63:3], 3'b000};
            virtio_read = {virtio_reg32_read(aligned_addr + 64'd4), virtio_reg32_read(aligned_addr)};
        end
    endfunction

    task automatic run_block_command(input word_t cmd);
        int word_idx;
        int disk_idx;
        addr_t mem_addr;
        begin
            blk_cmd <= cmd;
            if (blk_sector >= 64'(SIMPLE_BLK_SECTORS)) begin
                blk_status <= 64'd2;
            end
            else if (cmd == 64'd1) begin
                for (word_idx = 0; word_idx < SIMPLE_BLK_WORDS_PER_SECTOR; word_idx += 1) begin
                    disk_idx = int'(blk_sector[31:0]) * SIMPLE_BLK_WORDS_PER_SECTOR + word_idx;
                    mem_addr = blk_mem_addr + 64'(word_idx * 8);
                    ram_write_helper(ram_idx(mem_addr), disk[disk_idx], 64'hffff_ffff_ffff_ffff, 1'b1);
                end
                blk_status <= 64'd0;
            end
            else if (cmd == 64'd2) begin
                for (word_idx = 0; word_idx < SIMPLE_BLK_WORDS_PER_SECTOR; word_idx += 1) begin
                    disk_idx = int'(blk_sector[31:0]) * SIMPLE_BLK_WORDS_PER_SECTOR + word_idx;
                    mem_addr = blk_mem_addr + 64'(word_idx * 8);
                    disk[disk_idx] <= word_t'(ram_read_helper(1'b1, ram_idx(mem_addr)));
                end
                blk_status <= 64'd0;
            end
            else begin
                blk_status <= 64'd1;
            end
            plic_pending[PLIC_VIRTIO_SOURCE] <= 1'b1;
        end
    endtask

    task automatic virtio_write32(input addr_t addr, input u32 data);
        addr_t offset;
        begin
            offset = addr - VIRTIO_BASE;
            unique case (offset)
                64'h014: virt_device_features_sel <= data;
                64'h020: begin
                    unique case (virt_driver_features_sel)
                        32'd0: virt_driver_features_sel0 <= data;
                        32'd1: virt_driver_features_sel1 <= data;
                        default: begin end
                    endcase
                end
                64'h024: virt_driver_features_sel <= data;
                64'h030: virt_queue_sel <= data;
                64'h038: virt_queue_num <= data;
                64'h044: virt_queue_ready <= data;
                64'h050: run_virtqueue_command(data);
                64'h064: virt_interrupt_status <= virt_interrupt_status & ~data;
                64'h070: begin
                    if (data == 32'd0) begin
                        virt_status <= 32'd0;
                        blk_sector <= 64'd0;
                        blk_mem_addr <= 64'h0000_0000_8000_1000;
                        blk_cmd <= 64'd0;
                        blk_status <= 64'd0;
                        virt_driver_features_sel0 <= 32'd0;
                        virt_driver_features_sel1 <= 32'd0;
                        virt_driver_features_sel <= 32'd0;
                        virt_device_features_sel <= 32'd0;
                        virt_queue_sel <= 32'd0;
                        virt_queue_num <= 32'd0;
                        virt_queue_ready <= 32'd0;
                        virt_queue_desc <= 64'd0;
                        virt_queue_driver <= 64'd0;
                        virt_queue_device <= 64'd0;
                        virt_last_avail_idx <= 16'd0;
                        virt_interrupt_status <= 32'd0;
                        plic_pending[PLIC_VIRTIO_SOURCE] <= 1'b0;
                    end
                    else begin
                        virt_status <= (((data & VIRTIO_STATUS_FEATURES_OK) != 32'd0) &&
                            !virtio_driver_features_supported()) ?
                            (data & ~VIRTIO_STATUS_FEATURES_OK) : data;
                    end
                end
                64'h080: virt_queue_desc[31:0] <= data;
                64'h084: virt_queue_desc[63:32] <= data;
                64'h090: virt_queue_driver[31:0] <= data;
                64'h094: virt_queue_driver[63:32] <= data;
                64'h0a0: virt_queue_device[31:0] <= data;
                64'h0a4: virt_queue_device[63:32] <= data;
                64'h100: blk_sector[31:0] <= data;
                64'h104: blk_sector[63:32] <= data;
                64'h108: blk_mem_addr[31:0] <= data;
                64'h10c: blk_mem_addr[63:32] <= data;
                64'h110: run_block_command({32'd0, data});
                64'h118: blk_status <= {32'd0, data};
                default: begin end
            endcase
        end
    endtask

    task automatic virtio_write(input addr_t addr, input word_t data, input strobe_t strobe);
        addr_t aligned_addr;
        begin
            aligned_addr = {addr[63:3], 3'b000};
            if (|strobe[3:0]) begin
                virtio_write32(aligned_addr, data[31:0]);
            end
            if (|strobe[7:4]) begin
                virtio_write32(aligned_addr + 64'd4, data[63:32]);
            end
        end
    endtask

    assign plic_irq_m = (plic_best_source(1'b0) != 0);
    assign plic_irq_s = (plic_best_source(1'b1) != 0);

    assign ram_req = (oreq.valid && is_local_addr(oreq.addr)) ? '0 : oreq;

    always_comb begin
        if (oreq.valid && is_uart_addr(oreq.addr)) begin
            oresp.ready = 1'b1;
            oresp.last = 1'b1;
            oresp.data = oreq.is_write ? 64'd0 : uart_read(oreq.addr);
            oresp.paddr = oreq.addr;
            oresp.page_fault = 1'b0;
        end
        else if (oreq.valid && is_virtio_addr(oreq.addr)) begin
            oresp.ready = 1'b1;
            oresp.last = 1'b1;
            oresp.data = oreq.is_write ? 64'd0 : virtio_read(oreq.addr);
            oresp.paddr = oreq.addr;
            oresp.page_fault = 1'b0;
        end
        else if (oreq.valid && is_plic_addr(oreq.addr)) begin
            oresp.ready = 1'b1;
            oresp.last = 1'b1;
            oresp.data = oreq.is_write ? 64'd0 : plic_read(oreq.addr);
            oresp.paddr = oreq.addr;
            oresp.page_fault = 1'b0;
        end
        else begin
            oresp = ram_resp;
        end
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            local_req_active <= 1'b0;
            local_saved_req <= '0;
            blk_sector <= 64'd0;
            blk_mem_addr <= 64'h0000_0000_8000_1000;
            blk_cmd <= 64'd0;
            blk_status <= 64'd0;
            virt_device_features_sel <= 32'd0;
            virt_driver_features_sel <= 32'd0;
            virt_driver_features_sel0 <= 32'd0;
            virt_driver_features_sel1 <= 32'd0;
            virt_queue_sel <= 32'd0;
            virt_queue_num <= 32'd0;
            virt_queue_ready <= 32'd0;
            virt_status <= 32'd0;
            virt_interrupt_status <= 32'd0;
            virt_config_generation <= 32'd0;
            virt_queue_desc <= 64'd0;
            virt_queue_driver <= 64'd0;
            virt_queue_device <= 64'd0;
            virt_last_avail_idx <= 16'd0;
            plic_threshold_m <= 64'd0;
            plic_threshold_s <= 64'd0;
            plic_pending <= '0;
            plic_enable_m <= '0;
            plic_enable_s <= '0;
            plic_claim_clear_mask <= '0;
            if (!disk_init_loaded) begin
                load_disk_init();
                disk_init_loaded <= 1'b1;
            end
            uart_out_valid <= 1'b0;
            uart_out_ch <= 8'd0;
            uart_ier <= 8'd0;
            uart_fcr <= 8'd0;
            uart_lcr <= 8'd0;
            uart_mcr <= 8'd0;
            uart_scr <= 8'd0;
            uart_dll <= 8'd0;
            uart_dlm <= 8'd0;
            uart_rx_head <= '0;
            uart_rx_tail <= '0;
            uart_rx_count <= '0;
            uart_rx_timeout_count <= '0;
            uart_rx_timeout_pending <= 1'b0;
            uart_lsr_overrun <= 1'b0;
            uart_thr_irq_pending <= 1'b0;
            for (int source_idx = 0; source_idx <= PLIC_SOURCES; source_idx += 1) begin
                plic_priority[source_idx] <= 64'd0;
            end
            for (int i = 0; i < SIMPLE_BLK_WORDS; i += 1) begin
                disk[i] <= disk_init[i];
            end
        end
        else begin
            for (int source_idx = 1; source_idx <= PLIC_SOURCES; source_idx += 1) begin
                if (plic_claim_clear_mask[source_idx]) begin
                    plic_pending[source_idx] <= 1'b0;
                end
            end
            plic_claim_clear_mask <= '0;
            uart_out_valid <= 1'b0;
            if (uart_lsr_read_req) begin
                uart_lsr_overrun <= 1'b0;
            end
            if (uart_iir_read_req && uart_iir_reports_thre) begin
                uart_thr_irq_pending <= 1'b0;
            end
            if (uart_rx_pop_valid) begin
                uart_rx_head <= uart_rx_head + 1'b1;
            end
            if (uart_rx_push_req) begin
                uart_rx_fifo[uart_rx_tail] <= uart_in_ch;
                uart_rx_tail <= uart_rx_tail + 1'b1;
                if (uart_rx_irq_next_active) begin
                    plic_pending[PLIC_UART_SOURCE] <= 1'b1;
                end
            end
            if (uart_rx_fifo_activity) begin
                uart_rx_timeout_pending <= 1'b0;
                uart_rx_timeout_count <= (uart_rx_count_next != '0) ?
                    UART_RX_TIMEOUT_BITS'(UART_RX_TIMEOUT_CYCLES) : '0;
            end
            else if (uart_rx_count == '0) begin
                uart_rx_timeout_pending <= 1'b0;
                uart_rx_timeout_count <= '0;
            end
            else if (!uart_rx_timeout_pending && (uart_rx_timeout_count != '0)) begin
                uart_rx_timeout_count <= uart_rx_timeout_count - 1'b1;
                if (uart_rx_timeout_count == UART_RX_TIMEOUT_BITS'(1)) begin
                    uart_rx_timeout_pending <= 1'b1;
                    if (uart_ier[0]) begin
                        plic_pending[PLIC_UART_SOURCE] <= 1'b1;
                    end
                end
            end
            if (uart_rx_overrun_req) begin
                uart_lsr_overrun <= 1'b1;
                if (uart_ier[2]) begin
                    plic_pending[PLIC_UART_SOURCE] <= 1'b1;
                end
            end
            uart_rx_count <= uart_rx_count_next;
            if (!(oreq.valid && is_local_addr(oreq.addr))) begin
                local_req_active <= 1'b0;
            end
            else if (!local_req_active || !same_local_req(oreq, local_saved_req)) begin
                local_req_active <= 1'b1;
                local_saved_req <= oreq;
                if (is_uart_addr(oreq.addr)) begin
                    if (oreq.is_write && |oreq.strobe) begin
                        uart_write(oreq.addr, oreq.data, oreq.strobe);
                    end
                end
                else if (is_virtio_addr(oreq.addr)) begin
                    if (oreq.is_write && |oreq.strobe) begin
                        virtio_write(oreq.addr, oreq.data, oreq.strobe);
                    end
                end
                else if (is_plic_addr(oreq.addr)) begin
                    if (oreq.is_write && |oreq.strobe) begin
                        plic_write(oreq.addr, oreq.data, oreq.strobe);
                    end
                    else if (!oreq.is_write) begin
                        plic_read_side_effect(oreq.addr, oreq.size);
                    end
                end
            end
        end
    end

endmodule

`endif
