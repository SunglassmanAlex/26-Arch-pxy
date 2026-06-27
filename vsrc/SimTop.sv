`ifdef VERILATOR
`include "include/common.sv"
`include "include/csr.sv"
`include "src/core.sv"
`include "util/IBusToCBus.sv"
`include "util/DBusToCBus.sv"
`include "util/CBusArbiter.sv"
`include "util/MMU.sv"
`include "util/SimMemoryWithVirtio.sv"

module SimTop import common::*;(
  input         clock,
  input         reset,
  input  [63:0] io_logCtrl_log_begin,
  input  [63:0] io_logCtrl_log_end,
  input  [63:0] io_logCtrl_log_level,
  input         io_perfInfo_clean,
  input         io_perfInfo_dump,
  output        io_uart_out_valid,
  output [7:0]  io_uart_out_ch,
  output        io_uart_in_valid,
  input  [7:0]  io_uart_in_ch
);

    /* verilator lint_off UNOPTFLAT */
    cbus_req_t  oreq, cpu_oreq;
    cbus_resp_t oresp, cpu_oresp;
    /* verilator lint_on UNOPTFLAT */
    logic trint, swint, exint;
    logic if_flush;
    logic [1:0] priv_mode;
    word_t satp, mstatus;
    logic ram_uart_out_valid, ram_uart_in_valid;
    logic [7:0] ram_uart_out_ch, ram_uart_in_ch, scripted_uart_in_ch;

    localparam string UART_INPUT_TRIGGER = "init: starting sh";
    string uart_input_hex;
    int uart_input_hex_len;
    int uart_input_idx;
    int uart_trigger_idx;
    int uart_input_gap_cycles;
    int uart_input_wait;
    logic uart_input_enabled;
    logic uart_input_ready;

    ibus_req_t  ireq;
    ibus_resp_t iresp;
    dbus_req_t  dreq;
    dbus_resp_t dresp;
    cbus_req_t  icreq,  dcreq;
    cbus_resp_t icresp, dcresp;

    core core(
      .clk(clock), .reset, .ireq, .iresp, .if_flush, .dreq, .dresp,
      .priv_mode(priv_mode), .satp(satp), .mstatus(mstatus),
      .trint, .swint, .exint
    );

    IBusToCBus icvt(
        .clk(clock), .reset, .ireq, .iresp, .if_flush, .icreq, .icresp
    );
    DBusToCBus dcvt(.*);
    CBusArbiter mux(
        .clk(clock), .reset,
        .ireqs({icreq, dcreq}),
        .iresps({icresp, dcresp}),
        .oreq(cpu_oreq),
        .oresp(cpu_oresp)
    );

    MMU mmu(
        .clk(clock), .reset,
        .priv_mode(priv_mode),
        .satp(satp),
        .mstatus(mstatus),
        .ireq(cpu_oreq),
        .iresp(cpu_oresp),
        .oreq(oreq),
        .oresp(oresp)
    );

    assign io_uart_out_valid = ram_uart_out_valid;
    assign io_uart_out_ch = ram_uart_out_ch;
    assign io_uart_in_valid = ram_uart_in_valid;
    assign ram_uart_in_ch = uart_input_enabled ? scripted_uart_in_ch : io_uart_in_ch;

    function automatic int hex_value(input byte ch);
        begin
            if ((ch >= 8'h30) && (ch <= 8'h39)) begin
                hex_value = int'(ch) - 32'h30;
            end
            else if ((ch >= 8'h61) && (ch <= 8'h66)) begin
                hex_value = int'(ch) - 32'h61 + 10;
            end
            else if ((ch >= 8'h41) && (ch <= 8'h46)) begin
                hex_value = int'(ch) - 32'h41 + 10;
            end
            else begin
                hex_value = -1;
            end
        end
    endfunction

    function automatic logic [7:0] uart_input_byte(input int byte_idx);
        int hi;
        int lo;
        logic [3:0] hi_nibble;
        logic [3:0] lo_nibble;
        begin
            hi = hex_value(uart_input_hex.getc(byte_idx * 2));
            lo = hex_value(uart_input_hex.getc(byte_idx * 2 + 1));
            hi_nibble = hi[3:0];
            lo_nibble = lo[3:0];
            uart_input_byte = {hi_nibble, lo_nibble};
        end
    endfunction

    initial begin
        uart_input_enabled = $value$plusargs("uart_input_hex=%s", uart_input_hex);
        if (!$value$plusargs("uart_input_gap=%d", uart_input_gap_cycles)) begin
            uart_input_gap_cycles = 0;
        end
        uart_input_hex_len = uart_input_enabled ? uart_input_hex.len() : 0;
        if (uart_input_enabled) begin
            if ((uart_input_hex_len & 1) != 0) begin
                $fatal(1, "uart_input_hex must contain an even number of hex digits");
            end
            for (int i = 0; i < uart_input_hex_len; i += 1) begin
                if (hex_value(uart_input_hex.getc(i)) < 0) begin
                    $fatal(1, "uart_input_hex contains a non-hex character at index %0d", i);
                end
            end
            $display("uart input script loaded: %0d bytes", uart_input_hex_len / 2);
            $display("uart input gap: %0d cycles", uart_input_gap_cycles);
        end
    end

    always_ff @(posedge clock) begin
        if (reset) begin
            scripted_uart_in_ch <= 8'hff;
            uart_input_idx <= 0;
            uart_trigger_idx <= 0;
            uart_input_wait <= 0;
            uart_input_ready <= 1'b0;
        end
        else begin
            scripted_uart_in_ch <= 8'hff;

            if (uart_input_enabled && !uart_input_ready && ram_uart_out_valid) begin
                if (ram_uart_out_ch == UART_INPUT_TRIGGER.getc(uart_trigger_idx)) begin
                    if (uart_trigger_idx == UART_INPUT_TRIGGER.len() - 1) begin
                        uart_trigger_idx <= 0;
                        uart_input_ready <= 1'b1;
                        $display("uart input script armed after trigger: %s", UART_INPUT_TRIGGER);
                    end
                    else begin
                        uart_trigger_idx <= uart_trigger_idx + 1;
                    end
                end
                else begin
                    uart_trigger_idx <= (ram_uart_out_ch == UART_INPUT_TRIGGER.getc(0)) ? 1 : 0;
                end
            end

            if (uart_input_wait > 0) begin
                uart_input_wait <= uart_input_wait - 1;
            end
            else if (uart_input_enabled && uart_input_ready &&
                (uart_input_idx < (uart_input_hex_len / 2)) && ram_uart_in_valid) begin
                scripted_uart_in_ch <= uart_input_byte(uart_input_idx);
                uart_input_idx <= uart_input_idx + 1;
                uart_input_wait <= uart_input_gap_cycles;
                if ((uart_input_idx + 1) == (uart_input_hex_len / 2)) begin
                    $display("uart input script finished");
                end
            end
        end
    end

    SimMemoryWithVirtio ram(
        .clk(clock),
        .reset(reset),
        .oreq(oreq),
        .oresp(oresp),
        .trint(trint),
        .swint(swint),
        .exint(exint),
        .uart_out_valid(ram_uart_out_valid),
        .uart_out_ch(ram_uart_out_ch),
        .uart_in_valid(ram_uart_in_valid),
        .uart_in_ch(ram_uart_in_ch),
        .uart_in_error(3'b000)
    );

endmodule
`endif
