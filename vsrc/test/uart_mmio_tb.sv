`ifdef VERILATOR
`include "include/common.sv"
`endif

module uart_mmio_tb
    import common::*;
;
    localparam addr_t UART_BASE = 64'h0000_0000_1000_0000;
    localparam addr_t UART_RBR_THR_DLL = UART_BASE + 64'h0;
    localparam addr_t UART_IER_DLM = UART_BASE + 64'h1;
    localparam addr_t UART_IIR_FCR = UART_BASE + 64'h2;
    localparam addr_t UART_LCR = UART_BASE + 64'h3;
    localparam addr_t UART_MCR = UART_BASE + 64'h4;
    localparam addr_t UART_LSR = UART_BASE + 64'h5;
    localparam addr_t UART_SCR = UART_BASE + 64'h7;

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

    task automatic read8(input addr_t addr, output u8 data);
        word_t raw;
        oreq = '0;
        oreq.valid = 1'b1;
        oreq.is_write = 1'b0;
        oreq.size = MSIZE1;
        oreq.addr = addr;
        oreq.len = MLEN1;
        oreq.burst = AXI_BURST_FIXED;
        #1;
        while (!oresp.last) begin
            @(posedge clk);
            #1;
        end
        raw = oresp.data;
        data = u8'(raw >> {addr[2:0], 3'b000});
        @(posedge clk);
        oreq = '0;
        @(posedge clk);
        #1;
    endtask

    task automatic write8(
        input addr_t addr,
        input u8 data,
        input logic expect_tx,
        input u8 expected_tx,
        input string name
    );
        oreq = '0;
        oreq.valid = 1'b1;
        oreq.is_write = 1'b1;
        oreq.size = MSIZE1;
        oreq.addr = addr;
        oreq.strobe = 8'b0000_0001 << addr[2:0];
        oreq.data = {56'd0, data} << {addr[2:0], 3'b000};
        oreq.len = MLEN1;
        oreq.burst = AXI_BURST_FIXED;
        #1;
        while (!oresp.last) begin
            @(posedge clk);
            #1;
        end
        @(posedge clk);
        #1;
        if (expect_tx) begin
            if (!uart_out_valid || (uart_out_ch !== expected_tx)) begin
                $fatal(1, "%s tx valid=%b ch=%h expected %h",
                    name, uart_out_valid, uart_out_ch, expected_tx);
            end
        end
        else if (uart_out_valid) begin
            $fatal(1, "%s unexpected tx ch=%h", name, uart_out_ch);
        end
        oreq = '0;
        @(posedge clk);
        #1;
        $display("%s [OK]", name);
    endtask

    task automatic expect8(input addr_t addr, input u8 expected, input string name);
        u8 data;
        read8(addr, data);
        if (data !== expected) begin
            $fatal(1, "%s read %h expected %h", name, data, expected);
        end
        $display("%s [OK]", name);
    endtask

    initial begin
        clk = 1'b0;
        reset = 1'b1;
        oreq = '0;
        uart_in_ch = 8'd0;
        repeat (3) @(posedge clk);
        reset = 1'b0;
        @(posedge clk);

        expect8(UART_LSR, 8'h60, "uart_lsr_reset");
        expect8(UART_IIR_FCR, 8'h01, "uart_iir_no_interrupt");

        write8(UART_LCR, 8'h80, 1'b0, 8'd0, "uart_lcr_set_dlab");
        write8(UART_RBR_THR_DLL, 8'h03, 1'b0, 8'd0, "uart_dll_write_no_tx");
        write8(UART_IER_DLM, 8'h00, 1'b0, 8'd0, "uart_dlm_write");
        expect8(UART_RBR_THR_DLL, 8'h03, "uart_dll_read");
        expect8(UART_IER_DLM, 8'h00, "uart_dlm_read");

        write8(UART_LCR, 8'h03, 1'b0, 8'd0, "uart_lcr_8n1");
        expect8(UART_LCR, 8'h03, "uart_lcr_read");
        write8(UART_IER_DLM, 8'h01, 1'b0, 8'd0, "uart_ier_enable_rx");
        expect8(UART_IER_DLM, 8'h01, "uart_ier_read");
        write8(UART_MCR, 8'h08, 1'b0, 8'd0, "uart_mcr_write");
        expect8(UART_MCR, 8'h08, "uart_mcr_read");
        write8(UART_SCR, 8'h5a, 1'b0, 8'd0, "uart_scr_write");
        expect8(UART_SCR, 8'h5a, "uart_scr_read");

        write8(UART_RBR_THR_DLL, 8'h41, 1'b1, 8'h41, "uart_tx_A");

        $display("UART MMIO directed tests passed.");
        $finish;
    end

    `UNUSED_OK({trint, swint, exint, uart_in_valid});
endmodule
