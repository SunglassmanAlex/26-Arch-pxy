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
    localparam addr_t PLIC_BASE = 64'h0000_0000_0c00_0000;
    localparam addr_t PLIC_PENDING = PLIC_BASE + 64'h1000;
    localparam addr_t PLIC_M_ENABLE = PLIC_BASE + 64'h2000;
    localparam addr_t PLIC_M_THRESHOLD = PLIC_BASE + 64'h200000;
    localparam addr_t PLIC_M_CLAIM = PLIC_BASE + 64'h200004;
    localparam int UART_IRQ = 10;

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
        #1;
        oreq = '0;
        @(posedge clk);
        #1;
    endtask

    task automatic read32(input addr_t addr, output u32 data);
        word_t raw;
        oreq = '0;
        oreq.valid = 1'b1;
        oreq.is_write = 1'b0;
        oreq.size = MSIZE4;
        oreq.addr = addr;
        oreq.len = MLEN1;
        oreq.burst = AXI_BURST_FIXED;
        #1;
        while (!oresp.last) begin
            @(posedge clk);
            #1;
        end
        raw = oresp.data;
        data = u32'(raw >> {addr[2:0], 3'b000});
        @(posedge clk);
        #1;
        oreq = '0;
        @(posedge clk);
        #1;
    endtask

    task automatic write32(input addr_t addr, input u32 data, input string name);
        oreq = '0;
        oreq.valid = 1'b1;
        oreq.is_write = 1'b1;
        oreq.size = MSIZE4;
        oreq.addr = addr;
        oreq.strobe = 8'b0000_1111 << addr[2:0];
        oreq.data = {32'd0, data} << {addr[2:0], 3'b000};
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
        $display("%s [OK]", name);
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

    task automatic expect32(input addr_t addr, input u32 expected, input string name);
        u32 data;
        read32(addr, data);
        if (data !== expected) begin
            $fatal(1, "%s read %h expected %h", name, data, expected);
        end
        $display("%s [OK]", name);
    endtask

    task automatic expect_exint(input logic expected, input string name);
        @(posedge clk);
        #1;
        if (exint !== expected) begin
            $fatal(1, "%s exint=%b expected %b", name, exint, expected);
        end
        $display("%s [OK]", name);
    endtask

    task automatic expect_uart_in_valid(input logic expected, input string name);
        @(posedge clk);
        #1;
        if (uart_in_valid !== expected) begin
            $fatal(1, "%s uart_in_valid=%b expected %b", name, uart_in_valid, expected);
        end
        $display("%s [OK]", name);
    endtask

    task automatic inject_rx(input u8 data, input string name);
        if (!uart_in_valid) begin
            $fatal(1, "%s uart_in_valid is low", name);
        end
        uart_in_ch = data;
        @(posedge clk);
        #1;
        uart_in_ch = 8'hff;
        @(posedge clk);
        #1;
        $display("%s [OK]", name);
    endtask

    task automatic force_rx(input u8 data, input string name);
        uart_in_ch = data;
        @(posedge clk);
        #1;
        uart_in_ch = 8'hff;
        @(posedge clk);
        #1;
        $display("%s [OK]", name);
    endtask

    task automatic fill_rx_fifo(input u8 base, input string name);
        for (int i = 0; i < 16; i += 1) begin
            inject_rx(u8'(base + i[7:0]), $sformatf("%s_%0d", name, i));
        end
        expect_uart_in_valid(1'b0, {name, "_backpressure"});
    endtask

    initial begin
        clk = 1'b0;
        reset = 1'b1;
        oreq = '0;
        uart_in_ch = 8'hff;
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

        write32(PLIC_BASE + 64'(UART_IRQ * 4), 32'd4, "plic_uart_priority");
        write32(PLIC_M_ENABLE, 32'(1 << UART_IRQ), "plic_uart_m_enable");
        write32(PLIC_M_THRESHOLD, 32'd0, "plic_uart_m_threshold");
        inject_rx(8'h42, "uart_rx_inject_B");
        expect8(UART_LSR, 8'h61, "uart_lsr_rx_ready");
        expect8(UART_IIR_FCR, 8'h04, "uart_iir_rx_pending");
        expect32(PLIC_PENDING, 32'(1 << UART_IRQ), "plic_uart_pending");
        expect_exint(1'b1, "plic_uart_exint");
        expect8(UART_RBR_THR_DLL, 8'h42, "uart_rx_read_B");
        expect8(UART_LSR, 8'h60, "uart_lsr_rx_empty");
        expect8(UART_IIR_FCR, 8'h01, "uart_iir_rx_empty");
        expect32(PLIC_M_CLAIM, 32'(UART_IRQ), "plic_uart_claim");
        expect_exint(1'b0, "plic_uart_claim_clears_exint");
        write32(PLIC_M_CLAIM, 32'(UART_IRQ), "plic_uart_complete");
        inject_rx(8'h43, "uart_rx_fifo_inject_C");
        inject_rx(8'h44, "uart_rx_fifo_inject_D");
        expect8(UART_RBR_THR_DLL, 8'h43, "uart_rx_fifo_read_C");
        expect8(UART_LSR, 8'h61, "uart_lsr_fifo_still_ready");
        expect8(UART_IIR_FCR, 8'h04, "uart_iir_fifo_still_pending");
        expect8(UART_RBR_THR_DLL, 8'h44, "uart_rx_fifo_read_D");
        expect8(UART_LSR, 8'h60, "uart_lsr_fifo_empty");
        expect8(UART_IIR_FCR, 8'h01, "uart_iir_fifo_empty");
        expect32(PLIC_M_CLAIM, 32'(UART_IRQ), "plic_uart_fifo_claim");
        write32(PLIC_M_CLAIM, 32'(UART_IRQ), "plic_uart_fifo_complete");
        write8(UART_IIR_FCR, 8'h41, 1'b0, 8'd0, "uart_fcr_trigger4");
        inject_rx(8'h50, "uart_rx_trigger4_inject_0");
        inject_rx(8'h51, "uart_rx_trigger4_inject_1");
        inject_rx(8'h52, "uart_rx_trigger4_inject_2");
        expect8(UART_IIR_FCR, 8'h01, "uart_iir_below_trigger4");
        expect_exint(1'b0, "plic_uart_below_trigger4");
        inject_rx(8'h53, "uart_rx_trigger4_inject_3");
        expect8(UART_IIR_FCR, 8'h04, "uart_iir_reaches_trigger4");
        expect_exint(1'b1, "plic_uart_reaches_trigger4");
        expect32(PLIC_M_CLAIM, 32'(UART_IRQ), "plic_uart_trigger4_claim");
        write32(PLIC_M_CLAIM, 32'(UART_IRQ), "plic_uart_trigger4_complete");
        write8(UART_IIR_FCR, 8'h43, 1'b0, 8'd0, "uart_fcr_clear_rx_fifo");
        expect8(UART_LSR, 8'h60, "uart_lsr_after_fcr_clear");
        expect8(UART_IIR_FCR, 8'h01, "uart_iir_after_fcr_clear");
        write8(UART_IER_DLM, 8'h05, 1'b0, 8'd0, "uart_ier_enable_line_status");
        write8(UART_IIR_FCR, 8'h03, 1'b0, 8'd0, "uart_fcr_trigger1_clear");
        fill_rx_fifo(8'h80, "uart_rx_fill_fifo");
        force_rx(8'hf0, "uart_rx_force_overrun");
        expect8(UART_IIR_FCR, 8'h06, "uart_iir_overrun_priority");
        expect8(UART_LSR, 8'he3, "uart_lsr_overrun");
        expect8(UART_LSR, 8'h61, "uart_lsr_overrun_cleared");
        write8(UART_IIR_FCR, 8'h03, 1'b0, 8'd0, "uart_fcr_clear_overrun_fifo");
        expect8(UART_LSR, 8'h60, "uart_lsr_overrun_fifo_cleared");
        expect8(UART_IIR_FCR, 8'h01, "uart_iir_overrun_fifo_cleared");
        expect32(PLIC_M_CLAIM, 32'(UART_IRQ), "plic_uart_overrun_claim");
        expect_exint(1'b0, "plic_uart_overrun_claim_clears_exint");
        write32(PLIC_M_CLAIM, 32'(UART_IRQ), "plic_uart_overrun_complete");

        write8(UART_IER_DLM, 8'h02, 1'b0, 8'd0, "uart_ier_enable_thre");
        expect_exint(1'b1, "plic_uart_thre_exint");
        expect8(UART_IIR_FCR, 8'h02, "uart_iir_thre_pending");
        expect8(UART_IIR_FCR, 8'h01, "uart_iir_thre_read_clear");
        expect32(PLIC_M_CLAIM, 32'(UART_IRQ), "plic_uart_thre_claim");
        expect_exint(1'b0, "plic_uart_thre_claim_clears_exint");
        write32(PLIC_M_CLAIM, 32'(UART_IRQ), "plic_uart_thre_complete");
        write8(UART_RBR_THR_DLL, 8'h54, 1'b1, 8'h54, "uart_tx_T_thre_irq");
        expect8(UART_IIR_FCR, 8'h02, "uart_iir_thre_after_tx");
        expect32(PLIC_M_CLAIM, 32'(UART_IRQ), "plic_uart_thre_tx_claim");
        write32(PLIC_M_CLAIM, 32'(UART_IRQ), "plic_uart_thre_tx_complete");

        write8(UART_IER_DLM, 8'h01, 1'b0, 8'd0, "uart_ier_enable_rx_timeout");
        write8(UART_IIR_FCR, 8'h41, 1'b0, 8'd0, "uart_fcr_timeout_trigger4");
        inject_rx(8'h60, "uart_rx_timeout_inject");
        expect8(UART_IIR_FCR, 8'h01, "uart_iir_timeout_waiting");
        expect_exint(1'b0, "plic_uart_timeout_not_yet");
        repeat (20) @(posedge clk);
        #1;
        $display("uart_rx_timeout_wait [OK]");
        expect8(UART_IIR_FCR, 8'h0c, "uart_iir_rx_timeout");
        expect_exint(1'b1, "plic_uart_timeout_exint");
        expect8(UART_RBR_THR_DLL, 8'h60, "uart_rx_timeout_read");
        expect8(UART_IIR_FCR, 8'h01, "uart_iir_timeout_cleared");
        expect32(PLIC_M_CLAIM, 32'(UART_IRQ), "plic_uart_timeout_claim");
        expect_exint(1'b0, "plic_uart_timeout_claim_clears_exint");
        write32(PLIC_M_CLAIM, 32'(UART_IRQ), "plic_uart_timeout_complete");

        $display("UART MMIO directed tests passed.");
        $finish;
    end

    `UNUSED_OK({trint, swint});
endmodule
