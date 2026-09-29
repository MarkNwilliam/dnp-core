SIM ?= icarus
TOPLEVEL_LANG ?= verilog

VERILOG_SOURCES = ../rtl/np_time.sv \
                  ../rtl/np_id.sv \
                  ../rtl/np_toll.sv \
                  ../rtl/np_edr.sv \
                  ../rtl/np_audit.sv \
                  ../rtl/np_tamper.sv \
                  ../rtl/np_digest.sv \
                  ../rtl/np_core.sv

COMPILE_ARGS += -g2012

TOPLEVEL = np_core
MODULE   = test_np

include $(shell cocotb-config --makefiles)/Makefile.sim

clean::
	rm -rf sim_build results.xml results.log __pycache__

.PHONY: clean
