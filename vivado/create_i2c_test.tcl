# ==============================================================================
# create_i2c_test.tcl  —  PYNQ-Z2 ECG Demo : I2C bring-up / scope harness
# Vivado 2022.1  |  Batch mode  |  Fully unattended
#
# Builds a DELIBERATELY MINIMAL bitstream that contains ONLY i2c_adc_driver,
# instrumented with:
#   * a VIO  — drive `start`, read back adc_data / adc_valid over JTAG
#   * an ILA — scope the SDA/SCL bus + driver internals (mark_debug nets)
# No AXI, no FIR, no PYNQ overlay — drive it entirely from Vivado Hardware
# Manager over JTAG. Goal: CAPTURE the failing I2C waveform.  See
# vivado/I2C_TEST_README.md and handoffs/milestone_log.md.
#
# Run from the repo root:
#   vivado -mode batch -source vivado/create_i2c_test.tcl
#
# Outputs:
#   vivado/i2c_test.bit   — program this in Hardware Manager
#   vivado/i2c_test.ltx   — debug-probes file (load alongside the .bit)
#
# Independent of the main ecg_demo design — touches nothing in ps/.
# ==============================================================================

# ------------------------------------------------------------------------------
# 1 — Project setup
# ------------------------------------------------------------------------------
puts "INFO: === Step 1: Creating project ==="

set script_dir [file normalize [file dirname [info script]]]
set repo_root  [file normalize [file join $script_dir ..]]

set project_name i2c_test
set project_dir  [file join $script_dir build_i2c_test]
set part         xc7z020clg400-1
set board        tul.com.tw:pynq-z2:part0:1.0

create_project $project_name $project_dir -part $part -force
if {[catch {set_property board_part $board [current_project]} err]} {
    puts "WARNING: Board files for '$board' not found — continuing with part only ($part)"
} else {
    puts "INFO: Board part '$board' set"
}

# ------------------------------------------------------------------------------
# 2 — Add RTL sources (only the two files this harness needs)
# ------------------------------------------------------------------------------
puts "INFO: === Step 2: Adding RTL sources ==="

set pl_dir [file join $repo_root pl]
add_files -norecurse [list \
    [file join $pl_dir i2c_adc_driver.v] \
    [file join $pl_dir i2c_test_top.v]]
add_files -fileset constrs_1 -norecurse [file join $script_dir i2c_test.xdc]
update_compile_order -fileset sources_1

# ------------------------------------------------------------------------------
# 3 — VIO IP  (probe_out0 = start, probe_in0 = adc_data[12], probe_in1 = adc_valid)
# ------------------------------------------------------------------------------
puts "INFO: === Step 3: Creating VIO IP ==="

create_ip -name vio -vendor xilinx.com -library ip -module_name vio_0
set_property -dict [list \
    CONFIG.C_NUM_PROBE_IN    {2}  \
    CONFIG.C_NUM_PROBE_OUT   {1}  \
    CONFIG.C_PROBE_IN0_WIDTH {12} \
    CONFIG.C_PROBE_IN1_WIDTH {1}  \
    CONFIG.C_PROBE_OUT0_WIDTH {1} \
] [get_ips vio_0]
generate_target {synthesis instantiation_template} [get_files vio_0.xci]

# ------------------------------------------------------------------------------
# 4 — Block design: Zynq PS7 + proc_sys_reset (clock + reset source only)
# ------------------------------------------------------------------------------
puts "INFO: === Step 4: Creating block design (PS7 + reset) ==="

create_bd_design "i2c_test_bd"

set ps7 [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 processing_system7_0]
if {[catch {
    apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
        -config {make_external "FIXED_IO, DDR" apply_board_preset "1"} $ps7
} err]} {
    puts "WARNING: Board preset not applied ($err) — applying minimal config"
    apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
        -config {make_external "FIXED_IO, DDR"} $ps7
}
# Force FCLK_CLK0 = 100 MHz exactly (matches CLK_DIV=499 -> 100 kHz SCL) and
# drop unused AXI master to keep the design minimal.
set_property -dict [list \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {100} \
    CONFIG.PCW_USE_M_AXI_GP0            {0}   \
    CONFIG.PCW_USE_FABRIC_INTERRUPT     {0}   \
] $ps7

set rst [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 proc_sys_reset_0]

connect_bd_net [get_bd_pins $ps7/FCLK_CLK0]    [get_bd_pins $rst/slowest_sync_clk]
connect_bd_net [get_bd_pins $ps7/FCLK_RESET0_N] [get_bd_pins $rst/ext_reset_in]

# Expose clock + reset on the wrapper so the RTL top (i2c_test_top) can use them.
make_bd_pins_external -name FCLK_CLK0          [get_bd_pins $ps7/FCLK_CLK0]
make_bd_pins_external -name peripheral_aresetn [get_bd_pins $rst/peripheral_aresetn]

validate_bd_design
save_bd_design

# ------------------------------------------------------------------------------
# 5 — Generate BD wrapper (NOT top — our RTL i2c_test_top is the top)
# ------------------------------------------------------------------------------
puts "INFO: === Step 5: Generating BD wrapper ==="

make_wrapper -files [get_files i2c_test_bd.bd]
set wrapper ""
foreach d {gen srcs} {
    set try [file join $project_dir \
        ${project_name}.${d} sources_1 bd i2c_test_bd hdl i2c_test_bd_wrapper.v]
    if {[file exists $try]} { set wrapper $try; break }
}
if {$wrapper eq ""} { error "ERROR: i2c_test_bd_wrapper.v not found in .gen/ or .srcs/" }
add_files -norecurse $wrapper

set_property top i2c_test_top [current_fileset]
update_compile_order -fileset sources_1
puts "INFO: Top set to i2c_test_top"

# ------------------------------------------------------------------------------
# 6 — Synthesis
# ------------------------------------------------------------------------------
puts "INFO: === Step 6: Running synthesis ==="

launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
    error "ERROR: Synthesis failed — status: [get_property STATUS [get_runs synth_1]]"
}
puts "INFO: Synthesis complete"

# ------------------------------------------------------------------------------
# 7 — Insert ILA on the mark_debug nets (netlist-insertion, project flow)
#     Groups bus bits back into one probe each, then persists the debug core to
#     the constraints set via save_constraints so implementation includes it.
# ------------------------------------------------------------------------------
puts "INFO: === Step 7: Inserting ILA debug core ==="

open_run synth_1 -name synth_1

# Clock net that actually feeds the driver (post-BUFG), found structurally so we
# don't depend on net naming.
set clk_net [get_nets -of_objects [get_pins u_i2c/clk]]
puts "INFO:   ILA sample clock net: $clk_net"

# Collect mark_debug nets and regroup bus bits ( name[N] -> base "name" ).
set dbg_nets [get_nets -hier -filter {MARK_DEBUG}]
if {[llength $dbg_nets] == 0} {
    error "ERROR: no MARK_DEBUG nets found — was synthesis run with the attributed RTL?"
}
set groups [dict create]
foreach n $dbg_nets {
    set base $n
    regsub {\[\d+\]$} $n {} base
    dict lappend groups $base $n
}
puts "INFO:   [dict size $groups] debug probe groups from [llength $dbg_nets] nets"

create_debug_core u_ila_0 ila
set_property C_DATA_DEPTH 8192        [get_debug_cores u_ila_0]
set_property C_INPUT_PIPE_STAGES 0    [get_debug_cores u_ila_0]
set_property C_EN_STRG_QUAL 1         [get_debug_cores u_ila_0]
set_property ALL_PROBE_SAME_MU true   [get_debug_cores u_ila_0]
set_property ALL_PROBE_SAME_MU_CNT 1  [get_debug_cores u_ila_0]

set_property port_width 1 [get_debug_ports u_ila_0/clk]
connect_debug_port u_ila_0/clk $clk_net

set idx 0
foreach base [dict keys $groups] {
    set nets [lsort -dictionary [dict get $groups $base]]
    if {$idx > 0} { create_debug_port u_ila_0 probe }
    set_property port_width [llength $nets] [get_debug_ports u_ila_0/probe$idx]
    set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe$idx]
    connect_debug_port u_ila_0/probe$idx [get_nets $nets]
    puts "INFO:   probe$idx <- $base \[width [llength $nets]\]"
    incr idx
}

# dbg_hub clock
set_property C_CLK_INPUT_FREQ_HZ 100000000 [get_debug_cores dbg_hub]
set_property C_ENABLE_CLK_DIVIDER false     [get_debug_cores dbg_hub]
connect_debug_port dbg_hub/clk $clk_net

# Persist debug-core constraints so implementation builds them in.
save_constraints
close_design
puts "INFO: ILA debug core inserted and saved to constraints"

# ------------------------------------------------------------------------------
# 8 — Implementation + bitstream
# ------------------------------------------------------------------------------
puts "INFO: === Step 8: Implementation + bitstream ==="

launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
    error "ERROR: Implementation failed — status: [get_property STATUS [get_runs impl_1]]"
}
puts "INFO: Implementation + bitstream complete"

# ------------------------------------------------------------------------------
# 9 — Export .bit + .ltx to vivado/
# ------------------------------------------------------------------------------
puts "INFO: === Step 9: Exporting artifacts ==="

set bit_src [file join $project_dir ${project_name}.runs impl_1 i2c_test_top.bit]
if {![file exists $bit_src]} { error "ERROR: bitstream not found at $bit_src" }
file copy -force $bit_src [file join $script_dir i2c_test.bit]

open_run impl_1
write_debug_probes -force [file join $script_dir i2c_test.ltx]
close_design

puts ""
puts "INFO: ============================================================"
puts "INFO: I2C TEST BUILD COMPLETE"
puts "INFO:   vivado/i2c_test.bit   — program in Hardware Manager"
puts "INFO:   vivado/i2c_test.ltx   — load debug probes alongside"
puts "INFO: Open Hardware Manager, program, then drive VIO probe_out0 (start)"
puts "INFO: 0->1 and trigger the ILA on state == 5'd1 (START_SDA_LO)."
puts "INFO: ============================================================"
