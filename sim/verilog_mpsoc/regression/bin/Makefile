all: build

build:
	@if [ ! -e work ]; then vlib work; fi
	@vlog -sv +incdir+../../../../rtl/verilog/pkg -f mpsoc.vc
	vsim -c -do run.do work.riscv_mpsoc
