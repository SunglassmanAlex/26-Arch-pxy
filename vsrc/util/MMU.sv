`ifndef __MMU_SV
`define __MMU_SV

`ifdef VERILATOR
`include "include/common.sv"
`endif

module MMU
    import common::*;
(
    input  logic      clk,
    input  logic      reset,
    input  logic [1:0] priv_mode,
    input  word_t     satp,

    input  cbus_req_t  ireq,
    output cbus_resp_t iresp,
    output cbus_req_t  oreq,
    input  cbus_resp_t oresp
);
    localparam logic [1:0] PRIV_U = 2'b00;
    localparam logic [1:0] PRIV_S = 2'b01;
    localparam logic [1:0] PRIV_M = 2'b11;
    localparam logic [3:0] SATP_MODE_BARE = 4'd0;
    localparam logic [3:0] SATP_MODE_SV39 = 4'd8;

    typedef enum logic [1:0] {
        S_IDLE,
        S_WALK,
        S_FINAL,
        S_FAULT
    } state_t;

    state_t state;
    cbus_req_t saved_req;
    addr_t walk_addr, final_paddr;
    logic [1:0] level;

    function automatic logic mmu_enabled(input logic [1:0] mode, input word_t satp_val);
        mmu_enabled = (mode != PRIV_M) && (satp_val[63:60] == SATP_MODE_SV39);
    endfunction

    function automatic logic [8:0] vpn_index(input addr_t va, input logic [1:0] lvl);
        unique case (lvl)
            2'd0: vpn_index = va[38:30];
            2'd1: vpn_index = va[29:21];
            default: vpn_index = va[20:12];
        endcase
    endfunction

    function automatic addr_t pte_addr(input word_t ppn, input addr_t va, input logic [1:0] lvl);
        pte_addr = {8'd0, ppn[43:0], 12'b0} + {52'd0, vpn_index(va, lvl), 3'b000};
    endfunction

    function automatic logic pte_leaf(input word_t pte);
        pte_leaf = pte[1] || pte[3];
    endfunction

    function automatic logic sv39_va_valid(input addr_t va);
        sv39_va_valid = (va[63:39] == {25{va[38]}});
    endfunction

    function automatic logic pte_invalid(input word_t pte);
        pte_invalid = !pte[0] || (pte[2] && !pte[1]);
    endfunction

    function automatic logic superpage_misaligned(input word_t pte, input logic [1:0] lvl);
        unique case (lvl)
            2'd0: superpage_misaligned = |pte[27:10];
            2'd1: superpage_misaligned = |pte[18:10];
            default: superpage_misaligned = 1'b0;
        endcase
    endfunction

    function automatic logic pte_perm_fault(input word_t pte, input cbus_req_t req, input logic [1:0] mode);
        logic pte_r, pte_w, pte_x, pte_u;
        pte_r = pte[1];
        pte_w = pte[2];
        pte_x = pte[3];
        pte_u = pte[4];

        pte_perm_fault = 1'b0;
        if (req.is_instr) begin
            pte_perm_fault = !pte_x;
        end
        else if (req.is_write) begin
            pte_perm_fault = !pte_w;
        end
        else begin
            pte_perm_fault = !pte_r;
        end

        if ((mode == PRIV_U) && !pte_u) pte_perm_fault = 1'b1;
        if ((mode == PRIV_S) && pte_u) pte_perm_fault = 1'b1;
    endfunction

    function automatic addr_t translated_addr(input word_t pte, input addr_t va, input logic [1:0] lvl);
        unique case (lvl)
            2'd0: translated_addr = {8'd0, pte[53:28], va[29:0]};
            2'd1: translated_addr = {8'd0, pte[53:19], va[20:0]};
            default: translated_addr = {8'd0, pte[53:10], va[11:0]};
        endcase
    endfunction

    always_comb begin
        oreq = '0;
        iresp = '0;

        if (state == S_IDLE && !mmu_enabled(priv_mode, satp)) begin
            oreq = ireq;
            iresp = oresp;
            iresp.paddr = ireq.addr;
            iresp.page_fault = 1'b0;
        end
        else if (state == S_WALK) begin
            oreq.valid = 1'b1;
            oreq.is_write = 1'b0;
            oreq.size = MSIZE8;
            oreq.addr = walk_addr;
            oreq.strobe = '0;
            oreq.data = '0;
            oreq.len = MLEN1;
            oreq.burst = AXI_BURST_FIXED;
        end
        else if (state == S_FINAL) begin
            oreq = saved_req;
            oreq.addr = final_paddr;
            iresp = oresp;
            iresp.paddr = final_paddr;
        end
        else if (state == S_FAULT) begin
            iresp.ready = 1'b1;
            iresp.last = 1'b1;
            iresp.data = '0;
            iresp.paddr = saved_req.addr;
            iresp.page_fault = 1'b1;
        end
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            state <= S_IDLE;
            saved_req <= '0;
            walk_addr <= '0;
            final_paddr <= '0;
            level <= '0;
        end
        else begin
            unique case (state)
                S_IDLE: begin
                    if (ireq.valid && mmu_enabled(priv_mode, satp)) begin
                        saved_req <= ireq;
                        if (!sv39_va_valid(ireq.addr)) begin
                            state <= S_FAULT;
                        end
                        else begin
                            level <= 2'd0;
                            walk_addr <= pte_addr({20'd0, satp[43:0]}, ireq.addr, 2'd0);
                            state <= S_WALK;
                        end
                    end
                end

                S_WALK: begin
                    if (oresp.last) begin
                        if (pte_invalid(oresp.data)) begin
                            state <= S_FAULT;
                        end
                        else if (!pte_leaf(oresp.data)) begin
                            if (level == 2'd2) begin
                                state <= S_FAULT;
                            end
                            else begin
                                level <= level + 2'd1;
                                walk_addr <= pte_addr({20'd0, oresp.data[53:10]}, saved_req.addr, level + 2'd1);
                            end
                        end
                        else if (superpage_misaligned(oresp.data, level) ||
                            pte_perm_fault(oresp.data, saved_req, priv_mode)) begin
                            state <= S_FAULT;
                        end
                        else begin
                            final_paddr <= translated_addr(oresp.data, saved_req.addr, level);
                            state <= S_FINAL;
                        end
                    end
                end

                S_FINAL: begin
                    if (oresp.last) begin
                        state <= S_IDLE;
                    end
                end

                S_FAULT: begin
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    `UNUSED_OK({SATP_MODE_BARE, oresp.paddr});
endmodule

`endif
