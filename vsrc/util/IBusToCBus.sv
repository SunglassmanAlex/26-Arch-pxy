`ifndef __IBUSTOCBUS_SV
`define __IBUSTOCBUS_SV

`ifdef VERILATOR
`include "include/common.sv"
`else

`endif

module IBusToCBus 
    import common::*;(
    input  logic       clk,
    input  logic       reset,
    input  ibus_req_t  ireq,
    output ibus_resp_t iresp,
    input  logic       if_flush,
    output cbus_req_t  icreq,
    input  cbus_resp_t icresp
);
    addr_t line_addr;
    word_t line_data;
    logic line_valid, line_hit;

    dbus_req_t dreq;
    dbus_resp_t dresp;

    assign line_hit = line_valid && ireq.valid && (line_addr == {ireq.addr[63:3], 3'b000});

    assign dreq.valid  = ireq.valid && !line_hit;
    assign dreq.addr   = ireq.addr;
    assign dreq.size   = MSIZE4;
    assign dreq.strobe = 8'b0;
    assign dreq.data   = 64'b0;

    DBusToCBus #(.IS_INSTR(1'b1)) inst(
        .dreq(dreq),
        .dresp(dresp),
        .dcreq(icreq),
        .dcresp(icresp)
    );

    assign iresp.addr_ok = line_hit ? 1'b1 : dresp.addr_ok;
    assign iresp.data_ok = line_hit ? 1'b1 : dresp.data_ok;
    assign iresp.data = line_hit ?
        (ireq.addr[2] ? line_data[63:32] : line_data[31:0]) :
        (ireq.addr[2] ? dresp.data[63:32] : dresp.data[31:0]);
    assign iresp.page_fault = line_hit ? 1'b0 : dresp.page_fault;

    always_ff @(posedge clk) begin
        if (reset || if_flush) begin
            line_valid <= 1'b0;
            line_addr <= '0;
            line_data <= '0;
        end
        else if (dresp.data_ok && !dresp.page_fault) begin
            line_valid <= 1'b1;
            line_addr <= {ireq.addr[63:3], 3'b000};
            line_data <= dresp.data;
        end
    end
endmodule



`endif
