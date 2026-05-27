TOPLEVEL_LANG = verilog
VERILOG_SOURCES = $(shell pwd)/../../pl/ecg_dds.v $(shell pwd)/../../pl/ecg_rom.v
TOPLEVEL = ecg_dds
MODULE = test_ecg_dds
COCOTB_RESULTS_FILE = ../results/ecg_dds_results.xml

include $(shell python3 -m cocotb_tools.config --makefiles)/Makefile.sim
