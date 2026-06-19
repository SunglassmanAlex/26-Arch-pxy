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
    localparam addr_t VIRTIO_BASE = 64'h0000_0000_1000_1000;
    localparam addr_t VIRTIO_MASK = 64'hffff_ffff_ffff_fe00;
    localparam word_t VIRTIO_MAGIC_VERSION = {32'd2, 32'h7472_6976};
    localparam word_t VIRTIO_DEVICE_VENDOR = {32'h554d_4551, 32'd2};
    localparam int SIMPLE_BLK_SECTORS = 16;
    localparam int SIMPLE_BLK_WORDS_PER_SECTOR = 64;
    localparam int SIMPLE_BLK_WORDS = SIMPLE_BLK_SECTORS * SIMPLE_BLK_WORDS_PER_SECTOR;

    cbus_req_t ram_req;
    cbus_resp_t ram_resp;
    logic virtio_req_active;
    word_t blk_sector, blk_mem_addr, blk_cmd, blk_status;
    word_t disk [SIMPLE_BLK_WORDS];

    RAMHelper2 ram(
        .clk(clk),
        .reset(reset),
        .oreq(ram_req),
        .oresp(ram_resp),
        .trint(trint),
        .swint(swint),
        .exint(exint)
    );

    function automatic logic is_virtio_addr(input addr_t addr);
        is_virtio_addr = ((addr & VIRTIO_MASK) == VIRTIO_BASE);
    endfunction

    function automatic addr_t ram_idx(input addr_t addr);
        ram_idx = (addr > 64'h8000_0000) ? ((addr - 64'h8000_0000) >> 3) : 64'd0;
    endfunction

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

    assign ram_req = (oreq.valid && is_virtio_addr(oreq.addr)) ? '0 : oreq;

    always_comb begin
        if (oreq.valid && is_virtio_addr(oreq.addr)) begin
            oresp.ready = 1'b1;
            oresp.last = 1'b1;
            oresp.data = oreq.is_write ? 64'd0 : virtio_read(oreq.addr);
            oresp.paddr = oreq.addr;
            oresp.page_fault = 1'b0;
        end
        else begin
            oresp = ram_resp;
        end
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            virtio_req_active <= 1'b0;
            blk_sector <= 64'd0;
            blk_mem_addr <= 64'h0000_0000_8000_1000;
            blk_cmd <= 64'd0;
            blk_status <= 64'd0;
            for (int i = 0; i < SIMPLE_BLK_WORDS; i += 1) begin
                disk[i] <= 64'h5342_4c4b_0000_0000 | 64'(i);
            end
        end
        else begin
            if (!(oreq.valid && is_virtio_addr(oreq.addr))) begin
                virtio_req_active <= 1'b0;
            end
            else if (!virtio_req_active) begin
                virtio_req_active <= 1'b1;
                if (oreq.is_write && |oreq.strobe) begin
                    virtio_write(oreq.addr, oreq.data);
                end
            end
        end
    end
endmodule

`endif
