# 26-Arch Lab2 实验报告

## 1. 基本信息

- 姓名：潘孝圆
- 学号：24300240128
- 课程：计算机组成与体系结构（26-Arch）
- 实验：Lab2

## 2. 作业要求理解

Lab2 的核心要求是让 CPU 支持数据访存，并通过 `make test-lab2`。需要支持的指令为：

- Load 类：`ld`、`lb`、`lh`、`lw`、`lbu`、`lhu`、`lwu`
- Store 类：`sd`、`sb`、`sh`、`sw`
- 立即数类：`lui`

同时要正确使用数据总线 `dreq/dresp`，完成：

- 读写请求发起与握手等待（`data_ok/addr_ok`）
- `strobe` 与写数据对齐
- load 数据切片与符号/零扩展
- difftest 的 load/store 事件提交

## 3. 实现做法

### 3.1 总体执行策略

本次实现沿用 Lab1 的顺序执行风格，在访存指令上采用“阻塞式访存”策略：

1. 非访存指令按原路径执行并写回。
2. 遇到 `load/store` 后，锁存访存上下文并进入 `mem_pending`。
3. `mem_pending` 期间持续驱动 `dreq`，等待 `dresp.data_ok`。
4. 访存完成后再统一进入写回/提交路径。

这样改动范围小，便于保证正确性。

### 3.2 指令译码与地址计算

在译码中补齐了 Lab2 相关控制信号：

- `id_is_load` / `id_is_store` / `id_is_lui`
- `id_mem_size`（`MSIZE1/2/4/8`）
- `id_load_optype`（区分 `lb/lh/lw/ld/lbu/lhu/lwu`）

地址计算：

- load：`rs1 + imm_i`
- store：`rs1 + imm_s`
- lui：直接写入 `imm_u`

### 3.3 dreq 生成与 store 对齐

对 store 实现了两部分关键逻辑：

- `make_store_mask(size, addr[2:0])`：生成字节写掩码 `strobe`
- `make_store_data(size, addr[2:0], rs2)`：把待写数据移动到正确 byte lane

这部分保证了在总线按 8 字节对齐处理时，写入字节仍准确落在目标地址。

### 3.4 load 数据抽取与扩展

实现了 `make_load_data(raw, ofs, optype)`：

1. 先按 `ofs = addr[2:0]` 右移到目标字节位。
2. 按 `optype` 取 8/16/32/64 位数据。
3. 对 `lb/lh/lw` 做符号扩展，对 `lbu/lhu/lwu` 做零扩展。

### 3.5 difftest 事件

在提交路径中补齐：

- `DifftestStoreEvent`
- `DifftestLoadEvent`

并保证地址、掩码、写数据、load 类型与提交时序一致。

## 4. 关键调试与修复

调试过程中遇到一个关键问题：

- `lb` 在总线返回值正确时，写回寄存器却出现 0。

定位后发现问题出在 `make_load_data` 的实现细节上。修复方式是将其改为**直接拼接实现符号/零扩展**，避免嵌套函数调用导致的异常写回行为。修复后 load 写回与 difftest 一致。

## 5. 实验结果

### 5.1 Lab2 主测试

执行命令：

```bash
make test-lab2
```

结果：

- 终端输出 `HIT GOOD TRAP at pc = 0x8001fffc`
- Lab2 测试通过

### 5.2 回归测试

执行命令：

```bash
make test-lab1
```

结果：

- 终端输出 `HIT GOOD TRAP at pc = 0x80010004`
- 说明本次改动没有破坏 Lab1 基础功能

## 6. 总结

本次 Lab2 完成了 CPU 从“纯运算”到“可正确访存”的关键扩展。核心收益在于：

- 正确构建了 `dreq/dresp` 交互流程
- 正确处理了 store 的 `strobe/data` 对齐
- 正确实现了 load 的切片与符号扩展
- 通过了 Lab2 测试并完成了基本回归

## 7. AI 使用说明（按课程要求）

本次实验中使用了 AI（Codex）作为辅助工具，主要用于：

- 教学讲解：解释总线握手、`strobe` 语义、load/store 扩展规则
- 辅助定位：根据日志协助缩小错误范围
- 文档整理：协助组织报告结构和语言表达

特别说明：

- 本实验的实现思路、设计取舍和最终代码决策由我本人完成。
- AI 仅用于教学解释与辅助排错，不替代本人思考与实现。
- 最终提交内容由本人审阅、修改并确认。
