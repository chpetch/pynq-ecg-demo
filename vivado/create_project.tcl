# ==============================================================================
# create_project.tcl  —  PYNQ-Z2 ECG Demo
# Vivado 2022.1  |  Batch mode  |  Fully unattended
#
# Run from the repo root:
#   vivado -mode batch -source vivado/create_project.tcl
#
# Outputs (written to ps/ when bitstream completes):
#   ps/ecg_demo.bit   ~2 MB
#   ps/ecg_demo.hwh   XML hardware handoff for PYNQ overlay
# ==============================================================================

# ------------------------------------------------------------------------------
# 1 — Project setup
# ------------------------------------------------------------------------------
puts "INFO: === Step 1: Creating project ==="

set script_dir [file normalize [file dirname [info script]]]
set repo_root  [file normalize [file join $script_dir ..]]

set project_name ecg_demo
set project_dir  [file join $script_dir build]
set part         xc7z020clg400-1
set board        tul.com.tw:pynq-z2:part0:1.0

create_project $project_name $project_dir -part $part -force
# Board part is optional — only set if board files are installed
if {[catch {set_property board_part $board [current_project]} err]} {
    puts "WARNING: Board files for '$board' not found — continuing with part only ($part)"
    puts "WARNING: To install: copy pynq-z2 folder to Vivado/2022.1/data/boards/board_files/"
} else {
    puts "INFO: Board part '$board' set"
}

puts "INFO: Project '$project_name' created in $project_dir"

# ------------------------------------------------------------------------------
# 2 — Add RTL sources
# ------------------------------------------------------------------------------
puts "INFO: === Step 2: Adding RTL sources ==="

set pl_dir [file join $repo_root pl]

add_files -norecurse [glob [file join $pl_dir *.v]]
update_compile_order -fileset sources_1

# Constraints
add_files -fileset constrs_1 -norecurse [file join $pl_dir constraints.xdc]

puts "INFO: RTL sources and constraints added from $pl_dir"

# ------------------------------------------------------------------------------
# 3 — Create block design
# ------------------------------------------------------------------------------
puts "INFO: === Step 3: Creating block design ==="

create_bd_design "ecg_system"
update_compile_order -fileset sources_1

# 3a — Zynq PS7
puts "INFO:   Adding Zynq PS7..."
set ps7 [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 processing_system7_0]
# apply_board_preset "1" requires board files; omit if not installed
if {[catch {
    apply_bd_automation \
        -rule xilinx.com:bd_rule:processing_system7 \
        -config {make_external "FIXED_IO, DDR" apply_board_preset "1"} \
        $ps7
} err]} {
    puts "WARNING: Board preset not applied ($err) — applying minimal config"
    apply_bd_automation \
        -rule xilinx.com:bd_rule:processing_system7 \
        -config {make_external "FIXED_IO, DDR"} \
        $ps7
}
set_property -dict [list \
    CONFIG.PCW_USE_M_AXI_GP0            {1}   \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {100} \
    CONFIG.PCW_USE_FABRIC_INTERRUPT     {0}   \
    CONFIG.PCW_DDR_RAM_HIGHADDR         {0x1FFFFFFF} \
] $ps7

# 3b — Processor System Reset
puts "INFO:   Adding Proc System Reset..."
set rst [create_bd_cell \
    -type ip \
    -vlnv xilinx.com:ip:proc_sys_reset:5.0 \
    proc_sys_reset_0]

# 3c — AXI Interconnect (1 master GP0, 1 slave = ecg_process_top)
puts "INFO:   Adding AXI Interconnect..."
set axi_ic [create_bd_cell \
    -type ip \
    -vlnv xilinx.com:ip:axi_interconnect:2.1 \
    axi_interconnect_0]
set_property CONFIG.NUM_SI {1} $axi_ic
set_property CONFIG.NUM_MI {1} $axi_ic

# 3d — ecg_process_top (RTL module with AXI4-Lite slave)
puts "INFO:   Adding ecg_process_top RTL module..."
set ecg_proc [create_bd_cell \
    -type module \
    -reference ecg_process_top \
    ecg_process_top_0]

# 3e — ecg_signal_gen_top (RTL module, plain-wire BPM inputs)
puts "INFO:   Adding ecg_signal_gen_top RTL module..."
set ecg_gen [create_bd_cell \
    -type module \
    -reference ecg_signal_gen_top \
    ecg_signal_gen_top_0]

# ------------------------------------------------------------------------------
# 4 — Clock connections (all from FCLK_CLK0 @ 100 MHz)
# ------------------------------------------------------------------------------
puts "INFO: === Step 4: Connecting clocks ==="

# Proc reset clock
connect_bd_net \
    [get_bd_pins $ps7/FCLK_CLK0] \
    [get_bd_pins $rst/slowest_sync_clk]

# AXI interconnect clocks
connect_bd_net \
    [get_bd_pins $ps7/FCLK_CLK0] \
    [get_bd_pins $axi_ic/ACLK]
connect_bd_net \
    [get_bd_pins $ps7/FCLK_CLK0] \
    [get_bd_pins $axi_ic/S00_ACLK]
connect_bd_net \
    [get_bd_pins $ps7/FCLK_CLK0] \
    [get_bd_pins $axi_ic/M00_ACLK]

# ecg_process_top clocks (both clk and s_axi_aclk)
connect_bd_net \
    [get_bd_pins $ps7/FCLK_CLK0] \
    [get_bd_pins $ecg_proc/clk]
connect_bd_net \
    [get_bd_pins $ps7/FCLK_CLK0] \
    [get_bd_pins $ecg_proc/s_axi_aclk]

# PS7 M_AXI_GP0_ACLK must be driven (AXI master clock — easy to miss)
connect_bd_net \
    [get_bd_pins $ps7/FCLK_CLK0] \
    [get_bd_pins $ps7/M_AXI_GP0_ACLK]

# ecg_signal_gen_top clock
connect_bd_net \
    [get_bd_pins $ps7/FCLK_CLK0] \
    [get_bd_pins $ecg_gen/clk]

# ------------------------------------------------------------------------------
# 5 — Reset connections
# ------------------------------------------------------------------------------
puts "INFO: === Step 5: Connecting resets ==="

# FCLK_RESET0_N → proc_sys_reset ext_reset_in
connect_bd_net \
    [get_bd_pins $ps7/FCLK_RESET0_N] \
    [get_bd_pins $rst/ext_reset_in]

# peripheral_aresetn → AXI interconnect resets
connect_bd_net \
    [get_bd_pins $rst/peripheral_aresetn] \
    [get_bd_pins $axi_ic/ARESETN]
connect_bd_net \
    [get_bd_pins $rst/peripheral_aresetn] \
    [get_bd_pins $axi_ic/S00_ARESETN]
connect_bd_net \
    [get_bd_pins $rst/peripheral_aresetn] \
    [get_bd_pins $axi_ic/M00_ARESETN]

# peripheral_aresetn → ecg_process_top s_axi_aresetn + rst_n
connect_bd_net \
    [get_bd_pins $rst/peripheral_aresetn] \
    [get_bd_pins $ecg_proc/s_axi_aresetn]
connect_bd_net \
    [get_bd_pins $rst/peripheral_aresetn] \
    [get_bd_pins $ecg_proc/rst_n]

# peripheral_aresetn → ecg_signal_gen_top rst_n
connect_bd_net \
    [get_bd_pins $rst/peripheral_aresetn] \
    [get_bd_pins $ecg_gen/rst_n]

# ------------------------------------------------------------------------------
# 6 — AXI bus: PS M_AXI_GP0 → Interconnect → ecg_process_top
# ------------------------------------------------------------------------------
puts "INFO: === Step 6: Connecting AXI bus ==="

connect_bd_intf_net \
    [get_bd_intf_pins $ps7/M_AXI_GP0] \
    [get_bd_intf_pins $axi_ic/S00_AXI]

connect_bd_intf_net \
    [get_bd_intf_pins $axi_ic/M00_AXI] \
    [get_bd_intf_pins $ecg_proc/S_AXI]

# ------------------------------------------------------------------------------
# 7 — Internal signal connections (ecg_process_top <-> ecg_signal_gen_top)
# ------------------------------------------------------------------------------
puts "INFO: === Step 7: Connecting internal signals ==="

# ecg_signal_gen_top.sample_valid_out → ecg_process_top.sample_trigger
connect_bd_net \
    [get_bd_pins $ecg_gen/sample_valid_out] \
    [get_bd_pins $ecg_proc/sample_trigger]

# ecg_signal_gen_top.sample_data_out → ecg_process_top.dac_sample_in
connect_bd_net \
    [get_bd_pins $ecg_gen/sample_data_out] \
    [get_bd_pins $ecg_proc/dac_sample_in]

# ecg_process_top BPM/fluct outputs → ecg_signal_gen_top inputs
foreach ch {a b c d e f g h} {
    connect_bd_net \
        [get_bd_pins $ecg_proc/bpm_ch_$ch] \
        [get_bd_pins $ecg_gen/bpm_ch_$ch]
}
connect_bd_net \
    [get_bd_pins $ecg_proc/rr_fluct] \
    [get_bd_pins $ecg_gen/rr_fluct]
connect_bd_net \
    [get_bd_pins $ecg_proc/amp_fluct] \
    [get_bd_pins $ecg_gen/amp_fluct]

# ------------------------------------------------------------------------------
# 8 — External ports (names MUST match constraints.xdc net names)
# ------------------------------------------------------------------------------
puts "INFO: === Step 8: Creating external ports ==="

# DAC SPI — JA header (ecg_signal_gen_top)
make_bd_pins_external [get_bd_pins $ecg_gen/dac_cs_n]
make_bd_pins_external [get_bd_pins $ecg_gen/dac_sclk]
make_bd_pins_external [get_bd_pins $ecg_gen/dac_din]

# Rename to match XDC net names exactly
set_property name DAC_CS_N [get_bd_ports dac_cs_n_0]
set_property name DAC_SCLK [get_bd_ports dac_sclk_0]
set_property name DAC_DIN  [get_bd_ports dac_din_0]

# ADC I2C — JB header (ecg_process_top)
make_bd_pins_external [get_bd_pins $ecg_proc/adc_scl]
# adc_sda is inout — use make_bd_pins_external for inout ports too
make_bd_pins_external [get_bd_pins $ecg_proc/adc_sda]

# Rename to match XDC net names exactly (already lowercase in XDC)
set_property name adc_scl [get_bd_ports adc_scl_0]
set_property name adc_sda [get_bd_ports adc_sda_0]

# Bottom-row JB pads — shorted to adc_scl/adc_sda inside the PMOD AD2
# connector. Constrained with PULLUP in the XDC to keep them from floating
# and injecting noise back onto the I2C bus. Not connected to any logic.
make_bd_pins_external [get_bd_pins $ecg_proc/adc_scl_alt]
make_bd_pins_external [get_bd_pins $ecg_proc/adc_sda_alt]
set_property name adc_scl_alt [get_bd_ports adc_scl_alt_0]
set_property name adc_sda_alt [get_bd_ports adc_sda_alt_0]

# ------------------------------------------------------------------------------
# 9 — Address assignment
# ------------------------------------------------------------------------------
puts "INFO: === Step 9: Assigning AXI address ==="

assign_bd_address \
    -target_address_space /processing_system7_0/Data \
    [get_bd_addr_segs $ecg_proc/S_AXI/reg0] \
    -offset 0x43C00000 \
    -range 64K

# ------------------------------------------------------------------------------
# 10 — Validate and save block design
# ------------------------------------------------------------------------------
puts "INFO: === Step 10: Validating block design ==="

validate_bd_design
save_bd_design

puts "INFO: Block design validated and saved"

# ------------------------------------------------------------------------------
# 11 — Generate wrapper and set as top
# ------------------------------------------------------------------------------
puts "INFO: === Step 11: Generating HDL wrapper ==="

make_wrapper -files [get_files ecg_system.bd] -top
# Vivado 2022.1+ puts generated files in .gen/ (older versions use .srcs/)
set wrapper ""
foreach d {gen srcs} {
    set try [file join $project_dir \
        ${project_name}.${d} sources_1 bd ecg_system hdl ecg_system_wrapper.v]
    if {[file exists $try]} { set wrapper $try; break }
}
if {$wrapper eq ""} {
    error "ERROR: Cannot find ecg_system_wrapper.v in .gen/ or .srcs/"
}
add_files -norecurse $wrapper
set_property top ecg_system_wrapper [current_fileset]
update_compile_order -fileset sources_1

puts "INFO: Top-level wrapper set to ecg_system_wrapper"

# ------------------------------------------------------------------------------
# 12 — Synthesis
# ------------------------------------------------------------------------------
puts "INFO: === Step 12: Running synthesis (this takes ~10 minutes) ==="

launch_runs synth_1 -jobs 4
wait_on_run synth_1

if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
    set status [get_property STATUS [get_runs synth_1]]
    error "ERROR: Synthesis failed — status: $status"
}
puts "INFO: Synthesis complete"

# ------------------------------------------------------------------------------
# 13 — Implementation and bitstream
# ------------------------------------------------------------------------------
puts "INFO: === Step 13: Running implementation + bitstream (~20 minutes) ==="

launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1

if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
    set status [get_property STATUS [get_runs impl_1]]
    error "ERROR: Implementation failed — status: $status"
}
puts "INFO: Implementation and bitstream complete"

# ------------------------------------------------------------------------------
# 14 — Export .bit and .hwh to ps/
# ------------------------------------------------------------------------------
puts "INFO: === Step 14: Exporting bitstream artifacts ==="

set bit_src [file join $project_dir \
    ${project_name}.runs impl_1 ecg_system_wrapper.bit]
# HWH: Vivado 2022.1+ uses .gen/, older uses .srcs/
set hwh_src ""
foreach d {gen srcs} {
    set try [file join $project_dir \
        ${project_name}.${d} sources_1 bd ecg_system hw_handoff ecg_system.hwh]
    if {[file exists $try]} { set hwh_src $try; break }
}
set ps_dir  [file join $repo_root ps]

if {![file exists $bit_src]} {
    error "ERROR: Bitstream not found at $bit_src"
}
if {$hwh_src eq ""} {
    error "ERROR: HWH file not found in .gen/ or .srcs/ hw_handoff/"
}

file copy -force $bit_src [file join $ps_dir ecg_demo.bit]
file copy -force $hwh_src [file join $ps_dir ecg_demo.hwh]

set bit_size [file size [file join $ps_dir ecg_demo.bit]]
puts "INFO: Exported ps/ecg_demo.bit ([expr {$bit_size / 1024}] KB)"
puts "INFO: Exported ps/ecg_demo.hwh"
puts ""
puts "INFO: ============================================================"
puts "INFO: BUILD COMPLETE"
puts "INFO: Bitstream: ps/ecg_demo.bit"
puts "INFO: HWH file:  ps/ecg_demo.hwh"
puts "INFO: Run ps/deploy.sh <board_ip> to copy to the PYNQ-Z2 board"
puts "INFO: ============================================================"
