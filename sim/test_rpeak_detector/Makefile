TOPLEVEL_LANG = verilog
VERILOG_SOURCES = $(shell pwd)/../../pl/rpeak_detector.v
TOPLEVEL = rpeak_detector
MODULE = test_rpeak_detector
COCOTB_RESULTS_FILE = ../results/rpeak_detector_results.xml

include $(shell python3 -m cocotb_tools.config --makefiles)/Makefile.sim
