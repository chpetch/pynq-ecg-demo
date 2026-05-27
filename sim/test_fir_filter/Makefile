TOPLEVEL_LANG = verilog
VERILOG_SOURCES = $(shell pwd)/../../pl/fir_filter.v
TOPLEVEL = fir_filter
MODULE = test_fir_filter
COCOTB_RESULTS_FILE = ../results/fir_filter_results.xml

include $(shell python3 -m cocotb_tools.config --makefiles)/Makefile.sim
