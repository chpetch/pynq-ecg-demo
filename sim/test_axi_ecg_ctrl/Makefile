TOPLEVEL_LANG = verilog
VERILOG_SOURCES = $(shell pwd)/../../pl/axi_ecg_ctrl.v
TOPLEVEL = axi_ecg_ctrl
MODULE = test_axi_ecg_ctrl
COCOTB_RESULTS_FILE = ../results/axi_ecg_ctrl_results.xml

include $(shell python3 -m cocotb_tools.config --makefiles)/Makefile.sim
