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
    output logic exint
);
    localparam addr_t PLIC_BASE = 64'h0000_0000_0c00_0000;
    localparam addr_t PLIC_END  = 64'h0000_0000_1000_0000;
    localparam int PLIC_SOURCES = 16;
    localparam int PLIC_VIRTIO_SOURCE = 1;

    localparam addr_t VIRTIO_BASE = 64'h0000_0000_1000_1000;
    localparam addr_t VIRTIO_MASK = 64'hffff_ffff_ffff_fe00;
    localparam word_t VIRTIO_MAGIC_VERSION = {32'd2, 32'h7472_6976};
    localparam word_t VIRTIO_DEVICE_VENDOR = {32'h554d_4551, 32'd2};
    localparam int SIMPLE_BLK_SECTORS = 16;
    localparam int SIMPLE_BLK_WORDS_PER_SECTOR = 64;
    localparam int SIMPLE_BLK_WORDS = SIMPLE_BLK_SECTORS * SIMPLE_BLK_WORDS_PER_SECTOR;

    cbus_req_t ram_req;
    cbus_resp_t ram_resp;
    logic local_req_active;
    logic ram_exint, plic_irq_m, plic_irq_s;
    word_t blk_sector, blk_mem_addr, blk_cmd, blk_status;
    word_t disk [SIMPLE_BLK_WORDS];
    word_t plic_priority [PLIC_SOURCES:0];
    logic [PLIC_SOURCES:0] plic_pending, plic_enable_m, plic_enable_s;
    logic [PLIC_SOURCES:0] plic_claim_clear_mask;
    word_t plic_threshold_m, plic_threshold_s;

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

    function automatic logic is_plic_addr(input addr_t addr);
        is_plic_addr = (addr >= PLIC_BASE) && (addr < PLIC_END);
    endfunction

    function automatic logic is_virtio_addr(input addr_t addr);
        is_virtio_addr = ((addr & VIRTIO_MASK) == VIRTIO_BASE);
    endfunction

    function automatic logic is_local_addr(input addr_t addr);
        is_local_addr = is_virtio_addr(addr) || is_plic_addr(addr);
    endfunction

    function automatic addr_t ram_idx(input addr_t addr);
        ram_idx = (addr > 64'h8000_0000) ? ((addr - 64'h8000_0000) >> 3) : 64'd0;
    endfunction

    function automatic strobe_t size_strobe(input msize_t size, input logic [2:0] ofs);
        unique case (size)
            MSIZE1: size_strobe = 8'b0000_0001 << ofs;
            MSIZE2: size_strobe = 8'b0000_0011 << ofs;
            MSIZE4: size_strobe = 8'b0000_1111 << ofs;
            default: size_strobe = 8'b1111_1111;
        endcase
    endfunction

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

    function automatic word_t virtio_read(input addr_t addr);
        unique case (addr & 64'hffff_ffff_ffff_fff8)
            VIRTIO_BASE + 64'h000: virtio_read = VIRTIO_MAGIC_VERSION;
            VIRTIO_BASE + 64'h008: virtio_read = VIRTIO_DEVICE_VENDOR;
            VIRTIO_BASE + 64'h010: virtio_read = 64'd0;
            VIRTIO_BASE + 64'h100: virtio_read = blk_sector;
            VIRTIO_BASE + 64'h108: virtio_read = blk_mem_addr;
            VIRTIO_BASE + 64'h110: virtio_read = blk_cmd;
            VIRTIO_BASE + 64'h118: virtio_read = blk_status;
            VIRTIO_BASE + 64'h120: virtio_read = 64'(SIMPLE_BLK_SECTORS);
            VIRTIO_BASE + 64'h128: virtio_read = 64'd512;
            default:               virtio_read = 64'd0;
        endcase
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

    task automatic virtio_write(input addr_t addr, input word_t data);
        unique case (addr & 64'hffff_ffff_ffff_fff8)
            VIRTIO_BASE + 64'h100: blk_sector <= data;
            VIRTIO_BASE + 64'h108: blk_mem_addr <= data;
            VIRTIO_BASE + 64'h110: run_block_command(data);
            VIRTIO_BASE + 64'h118: blk_status <= data;
            default: begin end
        endcase
    endtask

    assign plic_irq_m = (plic_best_source(1'b0) != 0);
    assign plic_irq_s = (plic_best_source(1'b1) != 0);

    assign ram_req = (oreq.valid && is_local_addr(oreq.addr)) ? '0 : oreq;

    always_comb begin
        if (oreq.valid && is_virtio_addr(oreq.addr)) begin
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
            blk_sector <= 64'd0;
            blk_mem_addr <= 64'h0000_0000_8000_1000;
            blk_cmd <= 64'd0;
            blk_status <= 64'd0;
            plic_threshold_m <= 64'd0;
            plic_threshold_s <= 64'd0;
            plic_pending <= '0;
            plic_enable_m <= '0;
            plic_enable_s <= '0;
            plic_claim_clear_mask <= '0;
            for (int source_idx = 0; source_idx <= PLIC_SOURCES; source_idx += 1) begin
                plic_priority[source_idx] <= 64'd0;
            end
            for (int i = 0; i < SIMPLE_BLK_WORDS; i += 1) begin
                disk[i] <= 64'h5342_4c4b_0000_0000 | 64'(i);
            end
        end
        else begin
            for (int source_idx = 1; source_idx <= PLIC_SOURCES; source_idx += 1) begin
                if (plic_claim_clear_mask[source_idx]) begin
                    plic_pending[source_idx] <= 1'b0;
                end
            end
            plic_claim_clear_mask <= '0;
            if (!(oreq.valid && is_local_addr(oreq.addr))) begin
                local_req_active <= 1'b0;
            end
            else if (!local_req_active) begin
                local_req_active <= 1'b1;
                if (is_virtio_addr(oreq.addr)) begin
                    if (oreq.is_write && |oreq.strobe) begin
                        virtio_write(oreq.addr, oreq.data);
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
