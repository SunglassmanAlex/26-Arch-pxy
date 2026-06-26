`include "device.svh"

module board_device_tb;
    localparam int BIT_TICKS = 16;
    localparam int STR_LEN = 14;
    localparam logic [STR_LEN-1:0][7:0] EXPECTED = {
        8'h48, 8'h65, 8'h6c, 8'h6c, 8'h6f, 8'h20, 8'h57,
        8'h6f, 8'h72, 8'h6c, 8'h64, 8'h21, 8'h0d, 8'h0a
    };

    logic clk, reset, cpu_clk;
    logic [3:0] led, sw;
    logic tx;
    logic valid, wvalid;
    logic [63:0] addr, wdata, rdata;
    logic [7:0] size;
    logic ready, last;

    device #(
        .SIMULATION(1'b0),
        .BIT_TMR_MAX_VALUE(BIT_TICKS - 1)
    ) dut(
        .clk(clk),
        .reset(reset),
        .cpu_clk(cpu_clk),
        .led(led),
        .sw(sw),
        .tx(tx),
        .valid(valid),
        .addr(addr),
        .wvalid(wvalid),
        .size(size),
        .wdata(wdata),
        .rdata(rdata),
        .ready(ready),
        .last(last)
    );

    assign cpu_clk = clk;
    always #5 clk = ~clk;

    task automatic drive_idle;
        valid = 1'b0;
        wvalid = 1'b0;
        addr = '0;
        size = 8'd8;
        wdata = '0;
    endtask

    task automatic check(input logic condition, input string name);
        if (!condition) begin
            $fatal(1, "%s", name);
        end
        $display("%s [OK]", name);
    endtask

    task automatic read_switch(input logic [3:0] switch_value, input logic [63:0] expected, input string name);
        sw = switch_value;
        @(posedge clk);
        #1;
        valid = 1'b1;
        wvalid = 1'b0;
        addr = SW_ADDR;
        #1;
        check(rdata === expected, name);
        drive_idle();
        @(posedge clk);
        #1;
    endtask

    task automatic write_addr(input logic [63:0] write_addr, input logic [63:0] data);
        valid = 1'b1;
        wvalid = 1'b1;
        addr = write_addr;
        wdata = data;
        #1;
        check(ready, "board_device_write_ready");
        @(posedge clk);
        #1;
        drive_idle();
    endtask

    task automatic hold_write_until_ready(
        input logic [63:0] write_addr,
        input logic [63:0] data,
        input string busy_name,
        input string ready_name
    );
        valid = 1'b1;
        wvalid = 1'b1;
        addr = write_addr;
        wdata = data;
        #1;
        check(!ready, busy_name);
        wait (ready);
        #1;
        check(ready, ready_name);
        @(posedge clk);
        #1;
        drive_idle();
    endtask

    task automatic wait_for_start(input string name);
        int cycles;
        cycles = 0;
        while (tx !== 1'b0 && cycles < (BIT_TICKS * 2)) begin
            @(posedge clk);
            cycles++;
        end
        check(tx === 1'b0, name);
    endtask

    task automatic sample_uart_byte(output logic [7:0] data, input string name);
        int bit_index;
        wait_for_start({name, "_start"});
        repeat (BIT_TICKS + (BIT_TICKS / 2)) @(posedge clk);
        for (bit_index = 0; bit_index < 8; bit_index++) begin
            data[bit_index] = tx;
            repeat (BIT_TICKS) @(posedge clk);
        end
        check(tx === 1'b1, {name, "_stop"});
        repeat (BIT_TICKS / 2) @(posedge clk);
    endtask

    initial begin
        logic [7:0] data;
        clk = 1'b0;
        reset = 1'b1;
        sw = '0;
        drive_idle();
        repeat (5) @(posedge clk);
        reset = 1'b0;
        repeat (2) @(posedge clk);
        #1;

        check(led === 4'b0000, "board_device_led_reset");
        check(tx === 1'b1, "board_device_tx_idle");
        read_switch(4'd0, 64'd31, "board_device_sw0");
        read_switch(4'd5, 64'd16, "board_device_sw5");
        read_switch(4'd9, 64'd0, "board_device_sw_default");

        write_addr(TX_DATA, 64'h0000004100000000);
        fork
            hold_write_until_ready(
                TX_DATA,
                64'h0000004200000000,
                "board_device_uart_backpressure_busy",
                "board_device_uart_backpressure_ready"
            );
            begin
                sample_uart_byte(data, "board_device_backpressure_A");
                check(data === 8'h41, "board_device_backpressure_A_data");
                sample_uart_byte(data, "board_device_backpressure_B");
                check(data === 8'h42, "board_device_backpressure_B_data");
            end
        join

        write_addr(FINISH_ADDR, 64'h1);
        @(posedge clk);
        #1;
        check(led === 4'b1111, "board_device_finish_led");

        for (int i = 0; i < STR_LEN; i++) begin
            sample_uart_byte(data, $sformatf("board_device_uart_%0d", i));
            if (data !== EXPECTED[STR_LEN - 1 - i]) begin
                $fatal(1, "board_device_uart_%0d got %02x expected %02x",
                    i, data, EXPECTED[STR_LEN - 1 - i]);
            end
            $display("board_device_uart_%0d_data [OK]", i);
        end

        check(tx === 1'b1, "board_device_tx_returns_idle");
        $display("board device UART/LED directed test passed.");
        $finish;
    end
endmodule
