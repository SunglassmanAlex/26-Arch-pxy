# Nexys4 DDR 上板前清单

这份清单用于实体板测试前的最后确认。当前环境没有连接 Nexys4 DDR，也没有可用的 Vivado/bootgen 命令，因此这里记录的是已经能在本地静态确认的内容，以及拿到板子后需要人工确认的步骤。

## 1. 当前可烧写产物

- Vivado 工程：`vivado/test-cpu/project/project_1.xpr`
- 工程 target part：`xc7a100tcsg324-1`
- 工程综合顶层：`basys3_top`
- 实际 Nexys4 顶层：`vivado/src/with_delay/basys3_top.sv` 中的 `nexys4_top`
- 兼容包装：`basys3_top` 仅实例化 `nexys4_top`，用于保留旧工程 top 名称
- Bitstream：`vivado/test-cpu/project/project_1.runs/impl_1/basys3_top.bit`
- Bitstream 大小：`3825895` bytes
- Bitstream 时间戳：`2026-05-26 15:03:00 +0800`
- Bitstream SHA256：`a241ead93ec40e5d7d8e5df113d11f4b84d8236c2aef45a9e56cbdc4f7efd7d0`

当前目录下没有对应 `.bin` 文件，并且本机 PATH 中没有 `vivado` 或 `bootgen`。因此当前可直接用于 Vivado Hardware Manager 烧写 FPGA 的产物是 `.bit`；如果后续需要烧写 flash，需要在安装 Vivado/bootgen 的机器上重新导出 `.bin` 或 `.mcs`。

## 2. Vivado routed report 状态

`make test-labplus-vivado-precheck` 已检查以下 routed artifacts：

- `basys3_top.bit` 存在且大小大于 1 MiB。
- 脚本输出当前 `.bit` 的 path、size、mtime 和 SHA256，便于和实体板烧写文件比对。
- 脚本提示当前 implementation 目录没有 `.bin`，需要用 `.bit` program device 或重新生成 flash image。
- `basys3_top_route_status.rpt` 显示 routing errors 为 0。
- `basys3_top_drc_routed.rpt` 显示 `Violations found: 0`。
- `basys3_top_timing_summary_routed.rpt` 显示 WNS 非负，当前解析到并输出的 WNS 为 `0.574 ns`。
- Timing summary 包含 `All user specified timing constraints are met.`。

如果后续修改了 `vivado/src` 或 IP，需要重新跑 Vivado implementation，并再次执行：

```bash
make test-labplus-vivado-precheck
```

## 3. Nexys4 DDR 管脚

当前 XDC 文件为 `vivado/src/Basys-3-Master.xdc`，内容已改成 Nexys4 DDR 的最小约束。文件名保留旧名称是为了兼容原工程。

| 端口 | Nexys4 DDR 管脚 | 用途 |
| --- | --- | --- |
| `clk` | `E3` | 100 MHz system clock |
| `btnC` | `N17` | 同步 reset 输入 |
| `sw[0]` | `J15` | 软件可读开关 |
| `sw[1]` | `L16` | 软件可读开关 |
| `sw[2]` | `M13` | 软件可读开关 |
| `sw[3]` | `R15` | 软件可读开关 |
| `led[0]` | `H17` | finish 指示 |
| `led[1]` | `K15` | finish 指示 |
| `led[2]` | `J13` | finish 指示 |
| `led[3]` | `N14` | finish 指示 |
| `RsTx` | `D4` | FPGA TX 到 PC RX |
| `RsRx` | `C4` | PC TX 到 FPGA RX，当前顶层保留但 CPU 未使用 |

## 4. 串口和板级行为

`vivado/src/device.sv` 中板级 UART 使用 `BIT_TMR_MAX = 10416`。在 100 MHz 输入时，对应约 9600 baud，因此串口工具应设置为：

- Baud rate：`9600`
- Data bits：`8`
- Parity：`none`
- Stop bits：`1`
- Flow control：`none`

预期上板行为：

- 按下 `BTNC` 会 reset。
- 程序向 `FINISH_ADDR = 0x23333000` 写入后，`led[3:0]` 全部点亮。
- 同一次 finish 会通过 `RsTx` 输出 `Hello World!\r\n`。
- 软件写 `TX_DATA = 0x40600004` 时，硬件从 `wdata[39:32]` 取 1 个字符发送。
- 软件读 `TX_READY = 0x40600008` 可判断 UART 发送状态。

开关读数来自 `SW_ADDR = 0x23333008`：

| `sw[3:0]` | 读出值 |
| --- | --- |
| `0` | `31` |
| `1` | `1` |
| `2` | `2` |
| `3` | `4` |
| `4` | `8` |
| `5` | `16` |
| 其它 | `0` |

## 5. 上板前命令

在没有实体板的情况下，最后一轮本地检查使用：

```bash
make test-labplus-preboard
```

该入口串行执行 Vivado precheck、MMU page fault、S-mode interrupt、SFENCE.VMA、WFI、CLINT、PLIC、UART、virtio 和 xv6 platform smoke 测试。当前这些测试已经通过，关键收尾输出包括：

```text
Vivado pre-board check passed.
MMU page fault directed tests passed.
S-mode interrupt pending delegation test passed.
SFENCE.VMA directed test passed.
WFI directed test passed.
CLINT alias directed tests passed.
PLIC MMIO directed tests passed.
UART MMIO directed tests passed.
simple virtio block MMIO test passed.
xv6 platform smoke test passed.
```

在 `/mnt/e` 这类 WSL Windows mount 上偶尔会出现 `Clock skew detected` 的 make warning。只要命令退出码为 0，且上述收尾输出完整出现，就不是功能失败。

## 6. 拿到板子后的人工步骤

1. 用 Vivado 打开 `vivado/test-cpu/project/project_1.xpr`。
2. 连接 Nexys4 DDR，通过 Hardware Manager program device。
3. 选择 `project_1.runs/impl_1/basys3_top.bit`。
4. 打开 USB UART 对应串口，设置为 `9600 8N1`。
5. 按 `BTNC` reset。
6. 观察 `led[3:0]` 是否在程序 finish 后全部点亮。
7. 观察串口是否输出 `Hello World!` 或当前测试程序的输出。

如果没有串口输出，优先检查：

- 是否烧写的是本清单记录 SHA256 对应的 `.bit`。
- 串口是否选到 Nexys4 DDR 的 USB UART 端口，而不是 JTAG 或其它 USB 设备。
- 串口参数是否为 `9600 8N1`。
- `BTNC` 是否没有被持续按住。
- XDC 中 `RsTx` 是否仍约束在 `D4`。
- Vivado implementation 是否在修改后重新生成，并且 routed DRC/timing 仍通过。

## 7. 当前限制

- 这份清单不代表已经完成实体板验证；真实上板输出还需要拿到 Nexys4 DDR 后截图或拍照记录。
- 当前 FPGA 侧仍是课程板级 device/BRAM/串口框架，不是完整 QEMU virt 平台；仿真侧 xv6/virtio/PLIC/UART 兼容工作不能直接等价为 FPGA 侧完整 xv6 上板。
- 本地没有 Vivado/bootgen，不能在当前环境重新综合实现或生成 flash 用 `.bin/.mcs`。
