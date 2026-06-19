`ifndef DIFFTEST_STUBS_SV
`define DIFFTEST_STUBS_SV

/* verilator lint_off UNUSED */

module DifftestArchEvent(
    input logic clock,
    input logic [7:0] coreid,
    input logic [31:0] intrNO,
    input logic [31:0] cause,
    input logic [63:0] exceptionPC
);
endmodule

module DifftestInstrCommit(
    input logic clock,
    input logic [7:0] coreid,
    input logic [7:0] index,
    input logic valid,
    input logic [63:0] pc,
    input logic [31:0] instr,
    input logic skip,
    input logic isRVC,
    input logic scFailed,
    input logic wen,
    input logic [7:0] wdest,
    input logic [63:0] wdata
);
endmodule

module DifftestArchIntRegState(
    input logic clock,
    input logic [7:0] coreid,
    input logic [63:0] gpr_0,
    input logic [63:0] gpr_1,
    input logic [63:0] gpr_2,
    input logic [63:0] gpr_3,
    input logic [63:0] gpr_4,
    input logic [63:0] gpr_5,
    input logic [63:0] gpr_6,
    input logic [63:0] gpr_7,
    input logic [63:0] gpr_8,
    input logic [63:0] gpr_9,
    input logic [63:0] gpr_10,
    input logic [63:0] gpr_11,
    input logic [63:0] gpr_12,
    input logic [63:0] gpr_13,
    input logic [63:0] gpr_14,
    input logic [63:0] gpr_15,
    input logic [63:0] gpr_16,
    input logic [63:0] gpr_17,
    input logic [63:0] gpr_18,
    input logic [63:0] gpr_19,
    input logic [63:0] gpr_20,
    input logic [63:0] gpr_21,
    input logic [63:0] gpr_22,
    input logic [63:0] gpr_23,
    input logic [63:0] gpr_24,
    input logic [63:0] gpr_25,
    input logic [63:0] gpr_26,
    input logic [63:0] gpr_27,
    input logic [63:0] gpr_28,
    input logic [63:0] gpr_29,
    input logic [63:0] gpr_30,
    input logic [63:0] gpr_31
);
endmodule

module DifftestStoreEvent(
    input logic clock,
    input logic [7:0] coreid,
    input logic [7:0] index,
    input logic valid,
    input logic [63:0] storeAddr,
    input logic [63:0] storeData,
    input logic [7:0] storeMask
);
endmodule

module DifftestLoadEvent(
    input logic clock,
    input logic [7:0] coreid,
    input logic [7:0] index,
    input logic valid,
    input logic [63:0] paddr,
    input logic [7:0] opType,
    input logic [7:0] fuType
);
endmodule

module DifftestAtomicEvent(
    input logic clock,
    input logic [7:0] coreid,
    input logic atomicResp,
    input logic [63:0] atomicAddr,
    input logic [63:0] atomicData,
    input logic [7:0] atomicMask,
    input logic [7:0] atomicFuop,
    input logic [63:0] atomicOut
);
endmodule

module DifftestTrapEvent(
    input logic clock,
    input logic [7:0] coreid,
    input logic valid,
    input logic [2:0] code,
    input logic [63:0] pc,
    input logic [63:0] cycleCnt,
    input logic [63:0] instrCnt
);
endmodule

module DifftestCSRState(
    input logic clock,
    input logic [7:0] coreid,
    input logic [1:0] priviledgeMode,
    input logic [63:0] mstatus,
    input logic [63:0] sstatus,
    input logic [63:0] mepc,
    input logic [63:0] sepc,
    input logic [63:0] mtval,
    input logic [63:0] stval,
    input logic [63:0] mtvec,
    input logic [63:0] stvec,
    input logic [63:0] mcause,
    input logic [63:0] scause,
    input logic [63:0] satp,
    input logic [63:0] mip,
    input logic [63:0] mie,
    input logic [63:0] mscratch,
    input logic [63:0] sscratch,
    input logic [63:0] mideleg,
    input logic [63:0] medeleg
);
endmodule

/* verilator lint_on UNUSED */

`endif
