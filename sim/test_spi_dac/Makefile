TOPLEVEL_LANG = verilog
VERILOG_SOURCES = $(shell pwd)/../../pl/spi_dac_driver.v
TOPLEVEL = spi_dac_driver
MODULE = test_spi_dac
COCOTB_RESULTS_FILE = ../results/spi_dac_results.xml

include $(shell python3 -m cocotb_tools.config --makefiles)/Makefile.sim
