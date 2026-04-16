# 26-Arch Lab3 实验报告（Markdown 版）

## 1. 基本信息

- 姓名：潘孝圆
- 学号：24300240128
- 课程：计算机组成与体系结构（2026 春）
- 实验：Lab3
- 完成日期：2026-04-16

## 2. 实验目标与要求

Lab3 目标是让 CPU 支持跳转和条件跳转相关指令，并通过 `make test-lab3`。

本次实现并通过测试的指令包括：

- 分支：`beq` `bne` `blt` `bge` `bltu` `bgeu`
- 立即数比较/移位：`slti` `sltiu` `slli` `srli` `srai`
- 寄存器比较/移位：`sll` `slt` `sltu` `srl` `sra`
- 32 位（W）版本：`slliw` `srliw` `sraiw` `sllw` `srlw` `sraw`
- 跳转与 PC 相对：`auipc` `jalr` `jal`

同时按实验要求调整了 Difftest 的 skip 行为，跳过外设地址空间相关访存校验。

## 3. 实现方案

### 3.1 译码扩展

在 `core.sv` 中补充了 B/J 型立即数解码：

- `imm_b`：用于条件分支目标地址
- `imm_j`：用于 `jal` 目标地址

并补充控制信号：

- `id_is_branch`、`id_is_jal`、`id_is_jalr`、`id_is_auipc`
- 分支类型编码 `id_branch_op`
- 重定向控制 `id_redirect` 与 `id_redirect_target`

### 3.2 分支与跳转执行

实现逻辑：

- 分支目标：`if_id_pc + imm_b`
- `jal` 目标：`if_id_pc + imm_j`
- `jalr` 目标：`(rs1 + imm_i) & ~1`
- 链接返回地址（写回 rd）：`if_id_pc + 4`

当 ID 阶段本条指令被消费且需要重定向时，PC 在时序逻辑中更新到目标地址。

### 3.3 ALU 能力扩展

扩展 ALU 运算类型，新增：

- `SLL/SRL/SRA`
- `SLT/SLTU`

并支持：

- OP-IMM / OP 对应的 RV64 版本
- OP-IMM-32 / OP-32 对应 W 指令

W 指令按 32 位计算后进行符号扩展写回。

### 3.4 Difftest skip 与访存事件一致性

按 Lab3 要求增加 skip 逻辑：

- 当指令是 load/store 且地址在 `0x0000_0000 ~ 0x7FFF_FFFF` 时，`skip=1`

并同步修正：

- `DifftestLoadEvent.valid`
- `DifftestStoreEvent.valid`

确保被 skip 的访存不会再触发 Load/Store 事件比对，避免伪不一致。

## 4. 调试过程中的关键问题

### 4.1 `jalr` 目标地址拼接导致编译错误

问题：对表达式直接切片引起 Verilator 报错。

修复：先引入中间变量 `id_jalr_target_raw`，再进行 `{raw[63:1],1'b0}` 拼接。

### 4.2 MMIO 访存在 skip 后仍触发事件导致 Difftest 失败

问题：虽然 `InstrCommit.skip=1`，但 Load/StoreEvent 仍上报，导致不一致。

修复：`LoadEvent/StoreEvent` 的 `valid` 增加 `!dt_skip` 条件。

### 4.3 RV64 移位立即数高位合法性判断

问题：`slli rd, rs1, 32` 被误判为非法（错误使用完整 `fun7` 判定）。

修复：改为按 RV64 规则判断 `instr[31:26]`：

- `slli/srli`：`000000`
- `srai`：`010000`

修复后相关用例通过。

## 5. 实验结果

### 5.1 主测试

执行：

```bash
make test-lab3
```

结果：

- 输出包含 `HIT GOOD TRAP at pc = 0x80000030`
- `instrCnt = 1243686`
- `cycleCnt = 7072805`
- `IPC = 0.175841`
- AES correctness 全部 `PASS`

### 5.2 扩展测试

执行：

```bash
make test-lab3-extra
```

结果：

- 输出包含 `HIT GOOD TRAP at pc = 0x80000030`
- `instrCnt = 180723`
- `cycleCnt = 1048071`
- `IPC = 0.172434`
- AES correctness 全部 `PASS`

## 6. 上板测试说明

本地仿真部分已完成并通过。Vivado 上板测试需要在实验板环境执行，建议在最终 PDF 版报告中补充：

- bitstream 下载截图
- 串口/输出结果截图
- 与仿真结果的一致性说明

## 7. AI 使用说明（课程要求）

本实验使用了 AI（Codex）作为辅助工具，主要用于：

- 教学讲解：帮助解释 Lab3 中分支/跳转语义、Difftest skip 规则和 RV64 移位编码约束；
- 辅助排错：根据报错和日志提供定位建议；
- 文档整理：协助整理报告结构与表述。

明确说明：

- 本实验的核心思路、设计取舍与最终实现决策由我本人完成；
- AI 仅作为教学和辅助工具，不替代本人分析与编码；
- 最终代码与报告内容均由本人审阅、确认并负责。
