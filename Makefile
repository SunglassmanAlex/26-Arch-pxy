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
	@echo "  - test-labplus-plic: Run Lab+ directed PLIC MMIO test"
	@echo "  - test-labplus-uart: Run Lab+ directed UART MMIO test"
	@echo "  - test-labplus-virtio: Run Lab+ directed simple virtio block test"

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
	./build/simple-virtio/simple_virtio_block_tb

clean:
	rm -rf build

include verilate/Makefile.include
include verilate/Makefile.verilate.mk
include verilate/Makefile.vsim.mk

.PHONY: emu clean sim
