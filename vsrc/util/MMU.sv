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
    localparam logic [1:0] PRIV_M = 2'b11;
    localparam logic [3:0] SATP_MODE_BARE = 4'd0;
    localparam logic [3:0] SATP_MODE_SV39 = 4'd8;

    typedef enum logic [1:0] {
        S_IDLE,
        S_WALK,
        S_FINAL
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
                        level <= 2'd0;
                        walk_addr <= pte_addr({20'd0, satp[43:0]}, ireq.addr, 2'd0);
                        state <= S_WALK;
                    end
                end

                S_WALK: begin
                    if (oresp.last) begin
                        if (!oresp.data[0] || (oresp.data[2] && !oresp.data[1])) begin
                            final_paddr <= '0;
                            state <= S_FINAL;
                        end
                        else if (pte_leaf(oresp.data) || level == 2'd2) begin
                            final_paddr <= translated_addr(oresp.data, saved_req.addr, level);
                            state <= S_FINAL;
                        end
                        else begin
                            level <= level + 2'd1;
                            walk_addr <= pte_addr({20'd0, oresp.data[53:10]}, saved_req.addr, level + 2'd1);
                        end
                    end
                end

                S_FINAL: begin
                    if (oresp.last) begin
                        state <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    `UNUSED_OK({SATP_MODE_BARE, oresp.paddr});
endmodule

`endif
