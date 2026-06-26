`ifdef VERILATOR
`include "include/common.sv"
`endif

module mmu_page_fault_tb
    import common::*;
;
    localparam logic [1:0] PRIV_U = 2'b00;
    localparam logic [1:0] PRIV_S = 2'b01;
    localparam logic [1:0] PRIV_M = 2'b11;
    localparam addr_t ROOT_PTE_ADDR = 64'h0000_0000_0000_1000;
    localparam addr_t L1_PTE_ADDR   = 64'h0000_0000_0000_2000;
    localparam addr_t L0_PTE_ADDR   = 64'h0000_0000_0000_3000;
    localparam addr_t LEAF_PADDR    = 64'h0000_0000_0000_4000;

    localparam word_t PTE_V = 64'h001;
    localparam word_t PTE_R = 64'h002;
    localparam word_t PTE_W = 64'h004;
    localparam word_t PTE_X = 64'h008;
    localparam word_t PTE_U = 64'h010;
    localparam word_t PTE_A = 64'h040;
    localparam word_t PTE_D = 64'h080;
    localparam word_t MSTATUS_MPRV = 64'h0000_0000_0002_0000;
    localparam word_t MSTATUS_SUM  = 64'h0000_0000_0004_0000;
    localparam word_t MSTATUS_MPP_S = 64'h0000_0000_0000_0800;

    logic clk, reset;
    logic [1:0] priv_mode;
    word_t satp, mstatus;
    cbus_req_t ireq, oreq;
    cbus_resp_t iresp, oresp;
    word_t leaf_pte;
    cbus_req_t mem_req_q;
    logic mem_resp_pending;

    MMU dut(
        .clk(clk),
        .reset(reset),
        .priv_mode(priv_mode),
        .satp(satp),
        .mstatus(mstatus),
        .ireq(ireq),
        .iresp(iresp),
        .oreq(oreq),
        .oresp(oresp)
    );

    function automatic word_t make_pte(input word_t ppn, input word_t flags);
        make_pte = (ppn << 10) | flags;
    endfunction

    function automatic word_t mem_read(input addr_t addr);
        unique case (addr)
            ROOT_PTE_ADDR: mem_read = make_pte(64'd2, PTE_V);
            L1_PTE_ADDR:   mem_read = make_pte(64'd3, PTE_V);
            L0_PTE_ADDR:   mem_read = leaf_pte;
            LEAF_PADDR:    mem_read = 64'h1122_3344_5566_7788;
            default:       mem_read = 64'd0;
        endcase
    endfunction

    always #5 clk = ~clk;

    always_ff @(posedge clk) begin
        if (reset) begin
            oresp <= '0;
            mem_req_q <= '0;
            mem_resp_pending <= 1'b0;
        end
        else begin
            oresp <= '0;
            if (mem_resp_pending) begin
                oresp.ready <= 1'b1;
                oresp.last <= 1'b1;
                oresp.data <= mem_read(mem_req_q.addr);
                oresp.paddr <= mem_req_q.addr;
                oresp.page_fault <= 1'b0;
                mem_resp_pending <= 1'b0;
            end
            else if (oreq.valid && !oresp.last) begin
                mem_req_q <= oreq;
                mem_resp_pending <= 1'b1;
            end
        end
    end

    task automatic reset_dut();
        clk = 1'b0;
        reset = 1'b1;
        priv_mode = PRIV_U;
        satp = (64'h8 << 60) | 64'd1;
        mstatus = 64'd0;
        ireq = '0;
        leaf_pte = make_pte(64'd4, PTE_V | PTE_R | PTE_U | PTE_A | PTE_D);
        repeat (2) @(posedge clk);
        reset = 1'b0;
        @(posedge clk);
    endtask

    task automatic start_request(input logic is_instr, input logic is_write);
        ireq = '0;
        ireq.valid = 1'b1;
        ireq.is_instr = is_instr;
        ireq.is_write = is_write;
        ireq.size = is_instr ? MSIZE4 : MSIZE8;
        ireq.addr = 64'd0;
        ireq.strobe = is_write ? 8'hff : 8'h00;
        ireq.data = is_write ? 64'hfeed_face_cafe_beef : 64'd0;
        ireq.len = MLEN1;
        ireq.burst = AXI_BURST_FIXED;
        @(posedge clk);
        ireq.valid = 1'b0;
    endtask

    task automatic wait_response(input string name);
        int timeout;
        timeout = 30;
        while (!iresp.last && timeout > 0) begin
            @(posedge clk);
            timeout--;
        end
        if (timeout == 0) begin
            $fatal(1, "%s timed out waiting for MMU response", name);
        end
    endtask

    task automatic run_case(
        input string name,
        input logic is_instr,
        input logic is_write,
        input word_t flags,
        input logic expect_fault
    );
        leaf_pte = make_pte(64'd4, flags);
        start_request(is_instr, is_write);
        wait_response(name);
        if (iresp.page_fault !== expect_fault) begin
            $fatal(1, "%s page_fault=%0d expected=%0d", name, iresp.page_fault, expect_fault);
        end
        if (!expect_fault && iresp.paddr !== LEAF_PADDR) begin
            $fatal(1, "%s paddr=%h expected=%h", name, iresp.paddr, LEAF_PADDR);
        end
        $display("%s [OK]", name);
        @(posedge clk);
    endtask

    task automatic run_pass_through_case(input string name, input logic is_instr);
        leaf_pte = make_pte(64'd4, 64'd0);
        start_request(is_instr, 1'b0);
        wait_response(name);
        if (iresp.page_fault) begin
            $fatal(1, "%s unexpectedly raised page_fault", name);
        end
        if (iresp.paddr !== 64'd0) begin
            $fatal(1, "%s paddr=%h expected bare paddr 0", name, iresp.paddr);
        end
        $display("%s [OK]", name);
        @(posedge clk);
    endtask

    initial begin
        reset_dut();
        run_case("instruction_page_fault", 1'b1, 1'b0, PTE_V | PTE_R | PTE_U | PTE_A | PTE_D, 1'b1);
        run_case("load_page_fault",        1'b0, 1'b0, PTE_V | PTE_X | PTE_U | PTE_A | PTE_D, 1'b1);
        run_case("store_page_fault",       1'b0, 1'b1, PTE_V | PTE_R | PTE_U | PTE_A | PTE_D, 1'b1);
        run_case("load_ok",                1'b0, 1'b0, PTE_V | PTE_R | PTE_U | PTE_A | PTE_D, 1'b0);
        priv_mode = PRIV_M;
        mstatus = MSTATUS_MPRV;
        run_pass_through_case("mprv_instruction_ignored", 1'b1);
        run_case("mprv_u_load_rejects_supervisor_page", 1'b0, 1'b0, PTE_V | PTE_R | PTE_A | PTE_D, 1'b1);
        run_case("mprv_u_load_user_page_ok",            1'b0, 1'b0, PTE_V | PTE_R | PTE_U | PTE_A | PTE_D, 1'b0);
        mstatus = MSTATUS_MPRV | MSTATUS_MPP_S;
        run_case("mprv_s_load_user_page_sum_clear",     1'b0, 1'b0, PTE_V | PTE_R | PTE_U | PTE_A | PTE_D, 1'b1);
        mstatus = MSTATUS_MPRV | MSTATUS_MPP_S | MSTATUS_SUM;
        run_case("mprv_s_load_user_page_sum_ok",        1'b0, 1'b0, PTE_V | PTE_R | PTE_U | PTE_A | PTE_D, 1'b0);
        $display("MMU page fault directed tests passed.");
        $finish;
    end
endmodule
