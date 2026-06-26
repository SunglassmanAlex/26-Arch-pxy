.DEFAULT_GOAL := no_arguments

no_arguments:
	@echo "Please specify a target to build"
	@echo "  - init: Initialize submodules"
	@echo "  - handin: Create a zip file for handin"
	@echo "  - test-lab1: Run lab1 test"
	@echo "  - test-lab2: Run lab2 test"
	@echo "  - test-lab3: Run lab3 test"
	@echo "  - test-lab4: Run lab4 test"
	@echo "  - test-lab5: Run lab5 test"
	@echo "  - test-lab6: Run lab6 test"
	@echo "  - test-labplus-2: Run Lab+ performance test"
	@echo "  - test-labplus-3: Run Lab+ atomic extension test"
	@echo "  - test-labplus-4: Run Lab+ PMP test"
	@echo "  - test-labplus-pagefault: Run Lab+ directed MMU page-fault test"
	@echo "  - test-labplus-sinterrupt: Run Lab+ directed S-mode interrupt test"
	@echo "  - test-labplus-sfence: Run Lab+ directed SFENCE.VMA test"
	@echo "  - test-labplus-wfi: Run Lab+ directed WFI test"
	@echo "  - test-labplus-clint: Run Lab+ directed CLINT alias test"
	@echo "  - test-labplus-plic: Run Lab+ directed PLIC MMIO test"
	@echo "  - test-labplus-uart: Run Lab+ directed UART MMIO test"
	@echo "  - test-labplus-virtio: Run Lab+ directed simple virtio block test"
	@echo "  - test-labplus-xv6smoke: Run Lab+ xv6 platform MMIO smoke test"
	@echo "  - test-labplus-vivado-precheck: Run Lab+ Vivado project static pre-board check"
	@echo "  - test-labplus-board-device: Run Lab+ Nexys4 board device UART/LED test"
	@echo "  - test-labplus-board-soc-trace: Run Nexys4 soc_top trace simulation"
	@echo "  - test-labplus-preboard: Run Lab+ non-Vivado pre-board regression"
	@echo "  - vivado-nexys4-bitstream: Rebuild Nexys4 DDR bitstream with Vivado"
	@echo "  - vivado-nexys4-program: Program Nexys4 DDR bitstream with Vivado Hardware Manager"
	@echo "  - nexys4-uart-check: Capture Nexys4 UART output, set SERIAL=/dev/ttyUSBx"

init:
	git submodule update --init --recursive

handin:
	@if [ ! -f docs/report.pdf ]; then \
		echo "Please write your report in the 'docs' folder and convert it to 'report.pdf' first"; \
		exit 1; \
	fi; \
	echo "Please enter your 'student id-name' (e.g., 12345678910-someone)"; \
	read filename; \
	echo "Please enter lab number (e.g., 1)"; \
	read lab_n; \
	zip -q -r "docs/$$filename-lab$$lab_n.zip" \
	  include vsrc docs/report.pdf

sim-verilog:
	@echo "I don't know why, just make difftest happy..."

# DIFFTEST_OPTS = DELAY=0 # remove on lab 2

emu:
	$(MAKE) -C ./difftest emu $(DIFFTEST_OPTS)

export NOOP_HOME=$(abspath .)
export NEMU_HOME=$(abspath ./ready-to-run)

sim:
	rm -rf build
	mkdir -p build
	make EMU_TRACE=1 emu -j12 NOOP_HOME=$(NOOP_HOME) NEMU_HOME=$(NEMU_HOME)

test-lab1: sim
	TEST=$(TEST) ./build/emu --diff $(NEMU_HOME)/riscv64-nemu-interpreter-so -i ./ready-to-run/lab1/lab1-test.bin $(VOPT) || true

test-lab1-extra: sim
	TEST=$(TEST) ./build/emu --diff $(NEMU_HOME)/riscv64-nemu-interpreter-so -i ./ready-to-run/lab1/lab1-extra-test.bin $(VOPT) || true

test-lab2: sim
	TEST=$(TEST) ./build/emu --diff $(NEMU_HOME)/riscv64-nemu-interpreter-so -i ./ready-to-run/lab2/lab2-test.bin $(VOPT) || true

test-lab3: sim
	TEST=$(TEST) ./build/emu --diff $(NEMU_HOME)/riscv64-nemu-interpreter-so -i ./ready-to-run/lab3/lab3-test.bin $(VOPT) || true

test-lab3-extra: sim
	TEST=$(TEST) ./build/emu --diff $(NEMU_HOME)/riscv64-nemu-interpreter-so -i ./ready-to-run/lab3/lab3-extra-test.bin $(VOPT) || true

test-lab4: sim
	TEST=$(TEST) ./build/emu --diff $(NEMU_HOME)/riscv64-nemu-interpreter-so -i ./ready-to-run/lab4/lab4-test.bin $(VOPT) || true

test-lab5: sim
	TEST=$(TEST) ./build/emu --diff $(NEMU_HOME)/riscv64-nemu-interpreter-so -i ./ready-to-run/lab5/kernel.bin $(VOPT) || true

test-lab6: sim
	TEST=sys ./build/emu --no-diff -i ./ready-to-run/lab6/lab6-test.bin $(VOPT) || true

test-labplus-2: sim
	TEST=$(TEST) ./build/emu --diff $(NEMU_HOME)/riscv64-nemu-interpreter-so -i ./ready-to-run/lab+/2/microbench-riscv64-nutshell.bin $(VOPT) || true

test-labplus-3: sim
	TEST=$(TEST) ./build/emu --diff $(NEMU_HOME)/riscv64-nemu-interpreter-so -i ./ready-to-run/lab+/3/atomicity.bin $(VOPT) || true

test-labplus-4: sim
	TEST=all ./build/emu --no-diff -i ./ready-to-run/lab+/4/all-test-privfull.bin $(VOPT) || true

test-labplus-pagefault:
	rm -rf build/mmu-page-fault
	verilator --binary --timing --top-module mmu_page_fault_tb \
	  +define+VERILATOR=1 -I$(NOOP_HOME)/vsrc \
	  -Mdir build/mmu-page-fault -o mmu_page_fault_tb \
	  vsrc/test/mmu_page_fault_tb.sv vsrc/util/MMU.sv
	./build/mmu-page-fault/mmu_page_fault_tb

test-labplus-sinterrupt:
	rm -rf build/s-interrupt
	verilator --binary --timing --top-module s_interrupt_pending_tb \
	  +define+VERILATOR=1 -I$(NOOP_HOME)/vsrc \
	  -Mdir build/s-interrupt -o s_interrupt_pending_tb \
	  vsrc/test/difftest_stubs.sv vsrc/test/s_interrupt_pending_tb.sv
	./build/s-interrupt/s_interrupt_pending_tb

test-labplus-sfence:
	rm -rf build/sfence-vma
	verilator --binary --timing --top-module sfence_vma_tb \
	  +define+VERILATOR=1 -I$(NOOP_HOME)/vsrc \
	  -Mdir build/sfence-vma -o sfence_vma_tb \
	  vsrc/test/difftest_stubs.sv vsrc/test/sfence_vma_tb.sv
	./build/sfence-vma/sfence_vma_tb

test-labplus-wfi:
	rm -rf build/wfi
	verilator --binary --timing --top-module wfi_tb \
	  +define+VERILATOR=1 -I$(NOOP_HOME)/vsrc \
	  -Mdir build/wfi -o wfi_tb \
	  vsrc/test/difftest_stubs.sv vsrc/test/wfi_tb.sv
	./build/wfi/wfi_tb

test-labplus-clint:
	rm -rf build/clint-alias
	verilator --binary --timing --top-module clint_alias_tb \
	  +define+VERILATOR=1 +define+RANDOMIZE_DELAY=1 -I$(NOOP_HOME)/vsrc \
	  -Mdir build/clint-alias -o clint_alias_tb \
	  difftest/src/test/vsrc/common/ram.v \
	  difftest/src/test/vsrc/common/ram.sv \
	  vsrc/util/SimMemoryWithVirtio.sv \
	  vsrc/test/clint_alias_tb.sv \
	  vsrc/test/ram_dpi_stubs.cpp
	./build/clint-alias/clint_alias_tb

test-labplus-plic:
	rm -rf build/plic-mmio
	verilator --binary --timing --top-module plic_mmio_tb \
	  +define+VERILATOR=1 -I$(NOOP_HOME)/vsrc \
	  -Mdir build/plic-mmio -o plic_mmio_tb \
	  difftest/src/test/vsrc/common/ram.v \
	  difftest/src/test/vsrc/common/ram.sv \
	  vsrc/util/SimMemoryWithVirtio.sv \
	  vsrc/test/plic_mmio_tb.sv \
	  vsrc/test/ram_dpi_stubs.cpp
	./build/plic-mmio/plic_mmio_tb

test-labplus-uart:
	rm -rf build/uart-mmio
	verilator --binary --timing --top-module uart_mmio_tb \
	  +define+VERILATOR=1 -I$(NOOP_HOME)/vsrc \
	  -Mdir build/uart-mmio -o uart_mmio_tb \
	  difftest/src/test/vsrc/common/ram.v \
	  difftest/src/test/vsrc/common/ram.sv \
	  vsrc/util/SimMemoryWithVirtio.sv \
	  vsrc/test/uart_mmio_tb.sv \
	  vsrc/test/ram_dpi_stubs.cpp
	./build/uart-mmio/uart_mmio_tb

test-labplus-virtio:
	rm -rf build/simple-virtio
	verilator --binary --timing --top-module simple_virtio_block_tb \
	  +define+VERILATOR=1 -I$(NOOP_HOME)/vsrc \
	  -Mdir build/simple-virtio -o simple_virtio_block_tb \
	  difftest/src/test/vsrc/common/ram.v \
	  difftest/src/test/vsrc/common/ram.sv \
	  vsrc/util/SimMemoryWithVirtio.sv \
	  vsrc/test/simple_virtio_block_tb.sv \
	  vsrc/test/ram_dpi_stubs.cpp
	./build/simple-virtio/simple_virtio_block_tb +simple_blk_image=build/simple-virtio/simple-blk.img

test-labplus-xv6smoke:
	rm -rf build/xv6-platform-smoke
	verilator --binary --timing --top-module xv6_platform_smoke_tb \
	  +define+VERILATOR=1 +define+RANDOMIZE_DELAY=1 -I$(NOOP_HOME)/vsrc \
	  -Mdir build/xv6-platform-smoke -o xv6_platform_smoke_tb \
	  difftest/src/test/vsrc/common/ram.v \
	  difftest/src/test/vsrc/common/ram.sv \
	  vsrc/util/SimMemoryWithVirtio.sv \
	  vsrc/test/xv6_platform_smoke_tb.sv \
	  vsrc/test/ram_dpi_stubs.cpp
	./build/xv6-platform-smoke/xv6_platform_smoke_tb

test-labplus-vivado-precheck:
	python3 tools/preboard_check.py

test-labplus-board-device:
	rm -rf build/board-device
	CCACHE_DISABLE=1 verilator --binary --timing --top-module board_device_tb \
	  +define+VERILATOR=1 -I$(NOOP_HOME)/vivado/src \
	  -Mdir build/board-device -o board_device_tb \
	  vsrc/test/board_device_tb.sv vivado/src/device.sv
	./build/board-device/board_device_tb

test-labplus-board-soc-trace:
	rm -rf build/board-soc-trace
	CCACHE_DISABLE=1 verilator --binary --timing --trace-fst --top-module board_soc_trace_tb \
	  -Wno-WIDTHEXPAND -Wno-UNOPTFLAT \
	  +define+VERILATOR=1 -I$(NOOP_HOME)/vsrc -I$(NOOP_HOME)/vivado/src \
	  -I$(NOOP_HOME)/vivado/src/with_delay \
	  -Mdir build/board-soc-trace -o board_soc_trace_tb \
	  vsrc/test/difftest_stubs.sv vsrc/test/board_soc_trace_tb.sv \
	  vivado/src/device.sv vivado/src/with_delay/cbus_crossbar.sv \
	  vivado/src/with_delay/bram_wrapper.sv vivado/src/with_delay/soc_top.sv
	./build/board-soc-trace/board_soc_trace_tb

test-labplus-preboard:
	$(MAKE) test-labplus-vivado-precheck
	$(MAKE) test-labplus-board-device
	$(MAKE) test-labplus-pagefault
	$(MAKE) test-labplus-sinterrupt
	$(MAKE) test-labplus-sfence
	$(MAKE) test-labplus-wfi
	$(MAKE) test-labplus-clint
	$(MAKE) test-labplus-plic
	$(MAKE) test-labplus-uart
	$(MAKE) test-labplus-virtio
	$(MAKE) test-labplus-xv6smoke

vivado-nexys4-bitstream:
	@if ! command -v vivado >/dev/null 2>&1; then \
		echo "vivado not found in PATH; run this target on a machine with Vivado installed"; \
		exit 127; \
	fi
	vivado -mode batch -source tools/rebuild_nexys4_bitstream.tcl

vivado-nexys4-program:
	@if ! command -v vivado >/dev/null 2>&1; then \
		echo "vivado not found in PATH; run this target on a machine with Vivado installed"; \
		exit 127; \
	fi
	vivado -mode batch -source tools/program_nexys4_bitstream.tcl

nexys4-uart-check:
	@if [ -z "$(SERIAL)" ]; then \
		echo "Please set SERIAL=/dev/ttyUSBx or another board UART device"; \
		exit 2; \
	fi
	python3 tools/check_board_uart.py --port "$(SERIAL)" --baud 9600 --expect "Hello World!"

clean:
	rm -rf build

include verilate/Makefile.include
include verilate/Makefile.verilate.mk
include verilate/Makefile.vsim.mk

.PHONY: emu clean sim test-labplus-preboard test-labplus-xv6smoke test-labplus-vivado-precheck test-labplus-board-device test-labplus-board-soc-trace vivado-nexys4-bitstream vivado-nexys4-program nexys4-uart-check
