# ==============================================================================
# create_project_mb.tcl  —  PYNQ-Z2 ECG Demo with embedded MicroBlaze PMODB IOP
# Vivado 2022.1  |  Batch mode  |  Fully unattended
#
# Goal: embed the PYNQ base-overlay PMODB Pmod IOP (MicroBlaze + AXI IIC/SPI/
# GPIO/timer/intc + io_switch) into our custom overlay so PYNQ's
#   Pmod_IIC(overlay.iop_pmodb, 2, 3, 0x28)
# reads the AD7991 ADC on JB[2]/JB[3] (V10/W10) using the PROVEN controller —
# replacing the PL-fabric I2C master that the AD7991 NACKs. Our ECG generation
# (DAC SPI on JA) and AXI processing logic are retained.
#
# Run from the repo root:
#   & "C:/Xilinx/Vivado/2022.1/bin/vivado.bat" -mode batch \
#       -source vivado/create_project_mb.tcl -log build.log -journal build.jou
#
# Outputs (written to ps/ when bitstream completes):
#   ps/ecg_demo.bit   ~3-4 MB
#   ps/ecg_demo.hwh   XML hardware handoff for PYNQ overlay
#
# The two IOP-hierarchy procs (create_hier_cell_lmb_2 and
# create_hier_cell_iop_pmodb) are copied VERBATIM from PYNQ v3.0.0
# boards/Pynq-Z2/base/base.tcl (lines 1312 and 2590). DO NOT rename the
# iop_pmodb hierarchy or change the MB-internal address map — pmod_iic.bin is
# compiled to these exact addresses and PYNQ binds the Pmod driver by name.
# ==============================================================================

# ==============================================================================
# PROC 1 — create_hier_cell_lmb_2  (verbatim from base.tcl line 1312)
# ==============================================================================
proc create_hier_cell_lmb_2 { parentCell nameHier } {

  variable script_folder

  if { $parentCell eq "" || $nameHier eq "" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2092 -severity "ERROR" "create_hier_cell_lmb_2() - Empty argument(s)!"}
     return
  }

  # Get object for parentCell
  set parentObj [get_bd_cells $parentCell]
  if { $parentObj == "" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2090 -severity "ERROR" "Unable to find parent cell <$parentCell>!"}
     return
  }

  # Make sure parentObj is hier blk
  set parentType [get_property TYPE $parentObj]
  if { $parentType ne "hier" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2091 -severity "ERROR" "Parent <$parentObj> has TYPE = <$parentType>. Expected to be <hier>."}
     return
  }

  # Save current instance; Restore later
  set oldCurInst [current_bd_instance .]

  # Set parent object as current
  current_bd_instance $parentObj

  # Create cell and set as current instance
  set hier_obj [create_bd_cell -type hier $nameHier]
  current_bd_instance $hier_obj

  # Create interface pins
  create_bd_intf_pin -mode Slave -vlnv xilinx.com:interface:bram_rtl:1.0 BRAM_PORTB

  create_bd_intf_pin -mode MirroredMaster -vlnv xilinx.com:interface:lmb_rtl:1.0 DLMB

  create_bd_intf_pin -mode MirroredMaster -vlnv xilinx.com:interface:lmb_rtl:1.0 ILMB


  # Create pins
  create_bd_pin -dir I -type clk LMB_Clk
  create_bd_pin -dir I -from 0 -to 0 -type rst SYS_Rst

  # Create instance: dlmb_v10, and set properties
  set dlmb_v10 [ create_bd_cell -type ip -vlnv xilinx.com:ip:lmb_v10:3.0 dlmb_v10 ]

  # Create instance: ilmb_v10, and set properties
  set ilmb_v10 [ create_bd_cell -type ip -vlnv xilinx.com:ip:lmb_v10:3.0 ilmb_v10 ]

  # Create instance: lmb_bram, and set properties
  set lmb_bram [ create_bd_cell -type ip -vlnv xilinx.com:ip:blk_mem_gen:8.4 lmb_bram ]
  set_property -dict [ list \
   CONFIG.Enable_B {Use_ENB_Pin} \
   CONFIG.Memory_Type {True_Dual_Port_RAM} \
   CONFIG.Port_B_Clock {100} \
   CONFIG.Port_B_Enable_Rate {100} \
   CONFIG.Port_B_Write_Rate {50} \
   CONFIG.Use_RSTB_Pin {true} \
   CONFIG.use_bram_block {BRAM_Controller} \
 ] $lmb_bram

  # Create instance: lmb_bram_if_cntlr, and set properties
  set lmb_bram_if_cntlr [ create_bd_cell -type ip -vlnv xilinx.com:ip:lmb_bram_if_cntlr:4.0 lmb_bram_if_cntlr ]
  set_property -dict [ list \
   CONFIG.C_ECC {0} \
   CONFIG.C_NUM_LMB {2} \
 ] $lmb_bram_if_cntlr

  # Create interface connections
  connect_bd_intf_net -intf_net Conn [get_bd_intf_pins dlmb_v10/LMB_Sl_0] [get_bd_intf_pins lmb_bram_if_cntlr/SLMB1]
  connect_bd_intf_net -intf_net Conn1 [get_bd_intf_pins BRAM_PORTB] [get_bd_intf_pins lmb_bram/BRAM_PORTB]
  connect_bd_intf_net -intf_net lmb_bram_if_cntlr_BRAM_PORT [get_bd_intf_pins lmb_bram/BRAM_PORTA] [get_bd_intf_pins lmb_bram_if_cntlr/BRAM_PORT]
  connect_bd_intf_net -intf_net microblaze_0_dlmb [get_bd_intf_pins DLMB] [get_bd_intf_pins dlmb_v10/LMB_M]
  connect_bd_intf_net -intf_net microblaze_0_ilmb [get_bd_intf_pins ILMB] [get_bd_intf_pins ilmb_v10/LMB_M]
  connect_bd_intf_net -intf_net microblaze_0_ilmb_bus [get_bd_intf_pins ilmb_v10/LMB_Sl_0] [get_bd_intf_pins lmb_bram_if_cntlr/SLMB]

  # Create port connections
  connect_bd_net -net SYS_Rst_1 [get_bd_pins SYS_Rst] [get_bd_pins dlmb_v10/SYS_Rst] [get_bd_pins ilmb_v10/SYS_Rst] [get_bd_pins lmb_bram_if_cntlr/LMB_Rst]
  connect_bd_net -net microblaze_0_Clk [get_bd_pins LMB_Clk] [get_bd_pins dlmb_v10/LMB_Clk] [get_bd_pins ilmb_v10/LMB_Clk] [get_bd_pins lmb_bram_if_cntlr/LMB_Clk]

  # Restore current instance
  current_bd_instance $oldCurInst
}

# ==============================================================================
# PROC 2 — create_hier_cell_iop_pmodb  (verbatim from base.tcl line 2590)
# ==============================================================================
proc create_hier_cell_iop_pmodb { parentCell nameHier } {

  variable script_folder

  if { $parentCell eq "" || $nameHier eq "" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2092 -severity "ERROR" "create_hier_cell_iop_pmodb() - Empty argument(s)!"}
     return
  }

  # Get object for parentCell
  set parentObj [get_bd_cells $parentCell]
  if { $parentObj == "" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2090 -severity "ERROR" "Unable to find parent cell <$parentCell>!"}
     return
  }

  # Make sure parentObj is hier blk
  set parentType [get_property TYPE $parentObj]
  if { $parentType ne "hier" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2091 -severity "ERROR" "Parent <$parentObj> has TYPE = <$parentType>. Expected to be <hier>."}
     return
  }

  # Save current instance; Restore later
  set oldCurInst [current_bd_instance .]

  # Set parent object as current
  current_bd_instance $parentObj

  # Create cell and set as current instance
  set hier_obj [create_bd_cell -type hier $nameHier]
  current_bd_instance $hier_obj

  # Create interface pins
  create_bd_intf_pin -mode Slave -vlnv xilinx.com:interface:mbdebug_rtl:3.0 DEBUG

  create_bd_intf_pin -mode Master -vlnv xilinx.com:interface:aximm_rtl:1.0 M_AXI

  create_bd_intf_pin -mode Slave -vlnv xilinx.com:interface:aximm_rtl:1.0 S_AXI

  create_bd_intf_pin -mode Master -vlnv xilinx.com:interface:gpio_rtl:1.0 pmodb_gpio


  # Create pins
  create_bd_pin -dir I -from 0 -to 0 -type rst aux_reset_in
  create_bd_pin -dir I -type clk clk_100M
  create_bd_pin -dir I -from 0 -to 0 intr_ack
  create_bd_pin -dir O -from 0 -to 0 intr_req
  create_bd_pin -dir I -type rst mb_debug_sys_rst
  create_bd_pin -dir O -from 0 -to 0 -type rst peripheral_aresetn
  create_bd_pin -dir I -from 0 -to 0 -type rst s_axi_aresetn

  # Create instance: dff_en_reset_vector_0, and set properties
  set dff_en_reset_vector_0 [ create_bd_cell -type ip -vlnv xilinx.com:user:dff_en_reset_vector:1.0 dff_en_reset_vector_0 ]
  set_property -dict [ list \
   CONFIG.SIZE {1} \
 ] $dff_en_reset_vector_0

  # Create instance: gpio, and set properties
  set gpio [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 gpio ]
  set_property -dict [ list \
   CONFIG.C_ALL_OUTPUTS_2 {0} \
   CONFIG.C_GPIO2_WIDTH {32} \
   CONFIG.C_GPIO_WIDTH {8} \
   CONFIG.C_IS_DUAL {0} \
 ] $gpio

  # Create instance: iic, and set properties
  set iic [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_iic:2.1 iic ]

  # Create instance: intc, and set properties
  set intc [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_intc:4.1 intc ]

  # Create instance: intr, and set properties
  set intr [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 intr ]
  set_property -dict [ list \
   CONFIG.C_ALL_OUTPUTS {1} \
   CONFIG.C_GPIO_WIDTH {1} \
 ] $intr

  # Create instance: intr_concat, and set properties
  set intr_concat [ create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:2.1 intr_concat ]
  set_property -dict [ list \
   CONFIG.NUM_PORTS {3} \
 ] $intr_concat

  # Create instance: io_switch, and set properties
  set io_switch [ create_bd_cell -type ip -vlnv xilinx.com:user:io_switch:1.1 io_switch ]
  set_property -dict [ list \
   CONFIG.C_INTERFACE_TYPE {1} \
   CONFIG.C_IO_SWITCH_WIDTH {8} \
   CONFIG.C_NUM_PWMS {1} \
   CONFIG.C_NUM_TIMERS {1} \
   CONFIG.I2C0_Enable {true} \
   CONFIG.PWM_Enable {true} \
   CONFIG.SPI0_Enable {true} \
   CONFIG.Timer_Enable {true} \
 ] $io_switch

  # Create instance: lmb
  create_hier_cell_lmb_2 $hier_obj lmb

  # Create instance: logic_1, and set properties
  set logic_1 [ create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 logic_1 ]

  # Create instance: mb, and set properties
  set mb [ create_bd_cell -type ip -vlnv xilinx.com:ip:microblaze:11.0 mb ]
  set_property -dict [ list \
   CONFIG.C_DEBUG_ENABLED {1} \
   CONFIG.C_D_AXI {1} \
   CONFIG.C_D_LMB {1} \
   CONFIG.C_I_LMB {1} \
 ] $mb

  # Create instance: mb_bram_ctrl, and set properties
  set mb_bram_ctrl [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_bram_ctrl:4.1 mb_bram_ctrl ]
  set_property -dict [ list \
   CONFIG.SINGLE_PORT_BRAM {1} \
 ] $mb_bram_ctrl

  # Create instance: microblaze_0_axi_periph, and set properties
  set microblaze_0_axi_periph [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 microblaze_0_axi_periph ]
  set_property -dict [ list \
   CONFIG.M00_HAS_REGSLICE {1} \
   CONFIG.M01_HAS_REGSLICE {1} \
   CONFIG.M02_HAS_REGSLICE {1} \
   CONFIG.M03_HAS_REGSLICE {1} \
   CONFIG.M04_HAS_REGSLICE {1} \
   CONFIG.M05_HAS_REGSLICE {1} \
   CONFIG.M06_HAS_REGSLICE {1} \
   CONFIG.M07_HAS_REGSLICE {1} \
   CONFIG.NUM_MI {8} \
   CONFIG.S00_HAS_REGSLICE {1} \
 ] $microblaze_0_axi_periph

  # Create instance: rst_clk_wiz_1_100M, and set properties
  set rst_clk_wiz_1_100M [ create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_clk_wiz_1_100M ]
  set_property -dict [ list \
   CONFIG.C_AUX_RESET_HIGH {1} \
 ] $rst_clk_wiz_1_100M

  # Create instance: spi, and set properties
  set spi [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_quad_spi:3.2 spi ]
  set_property -dict [ list \
   CONFIG.C_USE_STARTUP {0} \
   CONFIG.C_USE_STARTUP_INT {0} \
 ] $spi

  # Create instance: timer, and set properties
  set timer [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_timer:2.0 timer ]

  # Create interface connections
  connect_bd_intf_net -intf_net BRAM_PORTB_1 [get_bd_intf_pins lmb/BRAM_PORTB] [get_bd_intf_pins mb_bram_ctrl/BRAM_PORTA]
  connect_bd_intf_net -intf_net Conn1 [get_bd_intf_pins M_AXI] [get_bd_intf_pins microblaze_0_axi_periph/M07_AXI]
  connect_bd_intf_net -intf_net Conn2 [get_bd_intf_pins S_AXI] [get_bd_intf_pins mb_bram_ctrl/S_AXI]
  connect_bd_intf_net -intf_net Conn3 [get_bd_intf_pins pmodb_gpio] [get_bd_intf_pins io_switch/io]
  connect_bd_intf_net -intf_net gpio_GPIO [get_bd_intf_pins gpio/GPIO] [get_bd_intf_pins io_switch/gpio]
  connect_bd_intf_net -intf_net iic_IIC [get_bd_intf_pins iic/IIC] [get_bd_intf_pins io_switch/iic0]
  connect_bd_intf_net -intf_net mb2_intc_interrupt [get_bd_intf_pins intc/interrupt] [get_bd_intf_pins mb/INTERRUPT]
  connect_bd_intf_net -intf_net microblaze_0_M_AXI_DP [get_bd_intf_pins mb/M_AXI_DP] [get_bd_intf_pins microblaze_0_axi_periph/S00_AXI]
  connect_bd_intf_net -intf_net microblaze_0_axi_periph_M00_AXI [get_bd_intf_pins microblaze_0_axi_periph/M00_AXI] [get_bd_intf_pins spi/AXI_LITE]
  connect_bd_intf_net -intf_net microblaze_0_axi_periph_M01_AXI [get_bd_intf_pins iic/S_AXI] [get_bd_intf_pins microblaze_0_axi_periph/M01_AXI]
  connect_bd_intf_net -intf_net microblaze_0_axi_periph_M02_AXI [get_bd_intf_pins io_switch/S_AXI] [get_bd_intf_pins microblaze_0_axi_periph/M02_AXI]
  connect_bd_intf_net -intf_net microblaze_0_axi_periph_M03_AXI [get_bd_intf_pins gpio/S_AXI] [get_bd_intf_pins microblaze_0_axi_periph/M03_AXI]
  connect_bd_intf_net -intf_net microblaze_0_axi_periph_M04_AXI [get_bd_intf_pins microblaze_0_axi_periph/M04_AXI] [get_bd_intf_pins timer/S_AXI]
  connect_bd_intf_net -intf_net microblaze_0_axi_periph_M05_AXI [get_bd_intf_pins intc/s_axi] [get_bd_intf_pins microblaze_0_axi_periph/M05_AXI]
  connect_bd_intf_net -intf_net microblaze_0_axi_periph_M06_AXI [get_bd_intf_pins intr/S_AXI] [get_bd_intf_pins microblaze_0_axi_periph/M06_AXI]
  connect_bd_intf_net -intf_net microblaze_0_debug [get_bd_intf_pins DEBUG] [get_bd_intf_pins mb/DEBUG]
  connect_bd_intf_net -intf_net microblaze_0_dlmb_1 [get_bd_intf_pins lmb/DLMB] [get_bd_intf_pins mb/DLMB]
  connect_bd_intf_net -intf_net microblaze_0_ilmb_1 [get_bd_intf_pins lmb/ILMB] [get_bd_intf_pins mb/ILMB]
  connect_bd_intf_net -intf_net spi_SPI_0 [get_bd_intf_pins io_switch/spi0] [get_bd_intf_pins spi/SPI_0]

  # Create port connections
  connect_bd_net -net dff_en_reset_vector_0_q [get_bd_pins intr_req] [get_bd_pins dff_en_reset_vector_0/q]
  connect_bd_net -net io_switch_timer_i [get_bd_pins io_switch/timer_i] [get_bd_pins timer/capturetrig0]
  connect_bd_net -net iop2_intr_ack_1 [get_bd_pins intr_ack] [get_bd_pins dff_en_reset_vector_0/reset]
  connect_bd_net -net iop2_intr_gpio_io_o [get_bd_pins dff_en_reset_vector_0/en] [get_bd_pins intr/gpio_io_o]
  connect_bd_net -net logic_1_dout1 [get_bd_pins dff_en_reset_vector_0/d] [get_bd_pins logic_1/dout] [get_bd_pins rst_clk_wiz_1_100M/ext_reset_in]
  connect_bd_net -net mb2_concat_dout [get_bd_pins intc/intr] [get_bd_pins intr_concat/dout]
  connect_bd_net -net mb2_iic_iic2intc_irpt [get_bd_pins iic/iic2intc_irpt] [get_bd_pins intr_concat/In0]
  connect_bd_net -net mb2_spi_ip2intc_irpt [get_bd_pins intr_concat/In1] [get_bd_pins spi/ip2intc_irpt]
  connect_bd_net -net mb2_timer_generateout0 [get_bd_pins io_switch/timer_o] [get_bd_pins timer/generateout0]
  connect_bd_net -net mb2_timer_interrupt [get_bd_pins intr_concat/In2] [get_bd_pins timer/interrupt]
  connect_bd_net -net mb2_timer_pwm0 [get_bd_pins io_switch/pwm_o] [get_bd_pins timer/pwm0]
  connect_bd_net -net mb_1_reset_Dout [get_bd_pins aux_reset_in] [get_bd_pins rst_clk_wiz_1_100M/aux_reset_in]
  connect_bd_net -net mdm_1_debug_sys_rst [get_bd_pins mb_debug_sys_rst] [get_bd_pins rst_clk_wiz_1_100M/mb_debug_sys_rst]
  connect_bd_net -net ps7_0_FCLK_CLK0 [get_bd_pins clk_100M] [get_bd_pins dff_en_reset_vector_0/clk] [get_bd_pins gpio/s_axi_aclk] [get_bd_pins iic/s_axi_aclk] [get_bd_pins intc/s_axi_aclk] [get_bd_pins intr/s_axi_aclk] [get_bd_pins io_switch/s_axi_aclk] [get_bd_pins lmb/LMB_Clk] [get_bd_pins mb/Clk] [get_bd_pins mb_bram_ctrl/s_axi_aclk] [get_bd_pins microblaze_0_axi_periph/ACLK] [get_bd_pins microblaze_0_axi_periph/M00_ACLK] [get_bd_pins microblaze_0_axi_periph/M01_ACLK] [get_bd_pins microblaze_0_axi_periph/M02_ACLK] [get_bd_pins microblaze_0_axi_periph/M03_ACLK] [get_bd_pins microblaze_0_axi_periph/M04_ACLK] [get_bd_pins microblaze_0_axi_periph/M05_ACLK] [get_bd_pins microblaze_0_axi_periph/M06_ACLK] [get_bd_pins microblaze_0_axi_periph/M07_ACLK] [get_bd_pins microblaze_0_axi_periph/S00_ACLK] [get_bd_pins rst_clk_wiz_1_100M/slowest_sync_clk] [get_bd_pins spi/ext_spi_clk] [get_bd_pins spi/s_axi_aclk] [get_bd_pins timer/s_axi_aclk]
  connect_bd_net -net rst_clk_wiz_1_100M_bus_struct_reset [get_bd_pins lmb/SYS_Rst] [get_bd_pins rst_clk_wiz_1_100M/bus_struct_reset]
  connect_bd_net -net rst_clk_wiz_1_100M_interconnect_aresetn [get_bd_pins microblaze_0_axi_periph/ARESETN] [get_bd_pins rst_clk_wiz_1_100M/interconnect_aresetn]
  connect_bd_net -net rst_clk_wiz_1_100M_mb_reset [get_bd_pins mb/Reset] [get_bd_pins rst_clk_wiz_1_100M/mb_reset]
  connect_bd_net -net rst_clk_wiz_1_100M_peripheral_aresetn [get_bd_pins peripheral_aresetn] [get_bd_pins gpio/s_axi_aresetn] [get_bd_pins iic/s_axi_aresetn] [get_bd_pins intc/s_axi_aresetn] [get_bd_pins io_switch/s_axi_aresetn] [get_bd_pins microblaze_0_axi_periph/M00_ARESETN] [get_bd_pins microblaze_0_axi_periph/M01_ARESETN] [get_bd_pins microblaze_0_axi_periph/M02_ARESETN] [get_bd_pins microblaze_0_axi_periph/M03_ARESETN] [get_bd_pins microblaze_0_axi_periph/M04_ARESETN] [get_bd_pins microblaze_0_axi_periph/M05_ARESETN] [get_bd_pins microblaze_0_axi_periph/M06_ARESETN] [get_bd_pins microblaze_0_axi_periph/M07_ARESETN] [get_bd_pins microblaze_0_axi_periph/S00_ARESETN] [get_bd_pins rst_clk_wiz_1_100M/peripheral_aresetn] [get_bd_pins spi/s_axi_aresetn] [get_bd_pins timer/s_axi_aresetn]
  connect_bd_net -net s_axi_aresetn_1 [get_bd_pins s_axi_aresetn] [get_bd_pins intr/s_axi_aresetn] [get_bd_pins mb_bram_ctrl/s_axi_aresetn]

  # Restore current instance
  current_bd_instance $oldCurInst
}

# ==============================================================================
# MAIN BUILD FLOW
# ==============================================================================

# ------------------------------------------------------------------------------
# 1 — Project setup
# ------------------------------------------------------------------------------
puts "INFO: === Step 1: Creating project ==="

set script_dir [file normalize [file dirname [info script]]]
set repo_root  [file normalize [file join $script_dir ..]]

set project_name ecg_demo_mb
set project_dir  [file join $script_dir build_mb]
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

# ------------------------------------------------------------------------------
# 1a — Point at the PYNQ IP repository (io_switch, dff_en_reset_vector,
#      address_remap, etc.) and refresh the catalog so the IOP IP is found.
# ------------------------------------------------------------------------------
set ip_repo [file join $script_dir pynq_src boards ip]
if {![file isdirectory $ip_repo]} {
    error "ERROR: PYNQ IP repo not found at $ip_repo — run the sparse clone (Step 0) first"
}
set_property ip_repo_paths $ip_repo [current_project]
update_ip_catalog
puts "INFO: IP catalog updated from $ip_repo"

puts "INFO: Project '$project_name' created in $project_dir"

# ------------------------------------------------------------------------------
# 2 — Add RTL sources (only the ECG modules; NOT the old i2c_* / axi_iic files)
# ------------------------------------------------------------------------------
puts "INFO: === Step 2: Adding RTL sources ==="

set pl_dir [file join $repo_root pl]

# Add every Verilog file EXCEPT the deprecated PL-fabric I2C harness.
set exclude {i2c_adc_driver.v i2c_test_top.v}
foreach f [glob [file join $pl_dir *.v]] {
    set base [file tail $f]
    if {[lsearch -exact $exclude $base] >= 0} {
        puts "INFO:   skipping deprecated source $base"
        continue
    }
    add_files -norecurse $f
}
update_compile_order -fileset sources_1

# Constraints — the NEW MicroBlaze-IOP constraint set
add_files -fileset constrs_1 -norecurse [file join $script_dir constraints_mb.xdc]

puts "INFO: RTL sources and constraints added"

# ------------------------------------------------------------------------------
# 3 — Create block design
# ------------------------------------------------------------------------------
puts "INFO: === Step 3: Creating block design ==="

create_bd_design "ecg_system"
update_compile_order -fileset sources_1

# 3a — Zynq PS7 -----------------------------------------------------------------
puts "INFO:   Adding Zynq PS7..."
set ps7 [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 processing_system7_0]
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
# Enable: M_AXI_GP0 (PS->PL), S_AXI_GP0 (PL->PS DRAM for MB M_AXI window),
# FCLK0 100 MHz, fabric interrupt + IRQ_F2P, and 10-bit EMIO GPIO for the
# IOP intr_ack/reset slices (mirrors base overlay).
set_property -dict [list \
    CONFIG.PCW_USE_M_AXI_GP0            {1}   \
    CONFIG.PCW_USE_S_AXI_GP0            {1}   \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {100} \
    CONFIG.PCW_EN_CLK0_PORT             {1}   \
    CONFIG.PCW_USE_FABRIC_INTERRUPT     {1}   \
    CONFIG.PCW_IRQ_F2P_INTR             {1}   \
    CONFIG.PCW_IRQ_F2P_MODE             {DIRECT} \
    CONFIG.PCW_GPIO_EMIO_GPIO_ENABLE    {1}   \
    CONFIG.PCW_GPIO_EMIO_GPIO_IO        {10}  \
    CONFIG.PCW_GPIO_EMIO_GPIO_WIDTH     {10}  \
] $ps7

# 3b — Top-level processor system reset (FCLK0 domain) --------------------------
puts "INFO:   Adding Proc System Reset..."
set rst [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_ps7_0_fclk0]

# 3c — PS->PL AXI-Lite interconnect (1 SI, 2 MI: ecg_process_top + IOP S_AXI) ---
puts "INFO:   Adding PS AXI-Lite interconnect..."
set axi_lite_ic [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 ps7_0_axi_periph]
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {2}] $axi_lite_ic

# 3d — PL->PS memory interconnect for the MicroBlaze M_AXI window --------------
# The MB's M_AXI (window into PS DRAM) routes via address_remap_0 ->
# axi_protocol_convert_0 -> a 1->1 interconnect -> PS S_AXI_GP0, exactly as the
# base overlay. address_remap remaps the MB 0x20000000 window to PS 0x0.
puts "INFO:   Adding MB->PS memory path (address_remap + protocol convert)..."
set address_remap [create_bd_cell -type ip -vlnv user.org:user:address_remap:1.0 address_remap_0]
set_property -dict [list \
    CONFIG.C_M_AXI_out_ADDR_WIDTH {29} \
    CONFIG.C_S_AXI_in_ADDR_WIDTH  {29} \
] $address_remap

set proto_conv [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_protocol_converter:2.1 axi_protocol_convert_0]

set mem_ic [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_mem_interconnect]
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] $mem_ic

# 3e — MicroBlaze Debug Module (drives iop_pmodb/DEBUG) -------------------------
puts "INFO:   Adding MicroBlaze Debug Module (mdm_1)..."
set mdm [create_bd_cell -type ip -vlnv xilinx.com:ip:mdm:3.2 mdm_1]

# 3f — Interrupt concat (iop_pmodb/intr_req -> PS IRQ_F2P) ----------------------
puts "INFO:   Adding interrupt concat..."
set irq_concat [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:2.1 xlconcat_0]
set_property CONFIG.NUM_PORTS {1} $irq_concat

# 3g — xlslices off PS GPIO_O for IOP intr_ack (bit5) and reset (bit1) ----------
puts "INFO:   Adding GPIO slices for IOP intr_ack/reset..."
set slice_intr_ack [create_bd_cell -type ip -vlnv xilinx.com:ip:xlslice:1.0 mb_iop_pmodb_intr_ack]
set_property -dict [list CONFIG.DIN_FROM {5} CONFIG.DIN_TO {5} CONFIG.DIN_WIDTH {10} CONFIG.DOUT_WIDTH {1}] $slice_intr_ack
set slice_reset [create_bd_cell -type ip -vlnv xilinx.com:ip:xlslice:1.0 mb_iop_pmodb_reset]
set_property -dict [list CONFIG.DIN_FROM {1} CONFIG.DIN_TO {1} CONFIG.DIN_WIDTH {10} CONFIG.DOUT_WIDTH {1}] $slice_reset

# 3h — The PMODB IOP hierarchy (named iop_pmodb — PYNQ binds the driver here) ---
puts "INFO:   Building iop_pmodb hierarchy..."
create_hier_cell_iop_pmodb [current_bd_instance .] iop_pmodb

# 3i — Our ECG RTL modules ------------------------------------------------------
puts "INFO:   Adding ecg_process_top RTL module..."
set ecg_proc [create_bd_cell -type module -reference ecg_process_top ecg_process_top_0]
puts "INFO:   Adding ecg_signal_gen_top RTL module..."
set ecg_gen [create_bd_cell -type module -reference ecg_signal_gen_top ecg_signal_gen_top_0]

# ------------------------------------------------------------------------------
# 4 — Clock connections (FCLK_CLK0 @ 100 MHz to everything)
# ------------------------------------------------------------------------------
puts "INFO: === Step 4: Connecting clocks ==="
connect_bd_net [get_bd_pins $ps7/FCLK_CLK0] \
    [get_bd_pins $rst/slowest_sync_clk] \
    [get_bd_pins $ps7/M_AXI_GP0_ACLK] \
    [get_bd_pins $ps7/S_AXI_GP0_ACLK] \
    [get_bd_pins $axi_lite_ic/ACLK] \
    [get_bd_pins $axi_lite_ic/S00_ACLK] \
    [get_bd_pins $axi_lite_ic/M00_ACLK] \
    [get_bd_pins $axi_lite_ic/M01_ACLK] \
    [get_bd_pins $mem_ic/ACLK] \
    [get_bd_pins $mem_ic/S00_ACLK] \
    [get_bd_pins $mem_ic/M00_ACLK] \
    [get_bd_pins $address_remap/s_axi_in_aclk] \
    [get_bd_pins $address_remap/m_axi_out_aclk] \
    [get_bd_pins $proto_conv/aclk] \
    [get_bd_pins iop_pmodb/clk_100M] \
    [get_bd_pins $ecg_proc/clk] \
    [get_bd_pins $ecg_proc/s_axi_aclk] \
    [get_bd_pins $ecg_gen/clk]

# ------------------------------------------------------------------------------
# 5 — Reset connections
# ------------------------------------------------------------------------------
puts "INFO: === Step 5: Connecting resets ==="

# FCLK_RESET0_N -> top proc reset ext_reset_in
connect_bd_net [get_bd_pins $ps7/FCLK_RESET0_N] [get_bd_pins $rst/ext_reset_in]

# peripheral_aresetn -> AXI-Lite interconnect + ECG modules + IOP s_axi_aresetn
connect_bd_net [get_bd_pins $rst/peripheral_aresetn] \
    [get_bd_pins $axi_lite_ic/ARESETN] \
    [get_bd_pins $axi_lite_ic/S00_ARESETN] \
    [get_bd_pins $axi_lite_ic/M00_ARESETN] \
    [get_bd_pins $axi_lite_ic/M01_ARESETN] \
    [get_bd_pins iop_pmodb/s_axi_aresetn] \
    [get_bd_pins $ecg_proc/s_axi_aresetn] \
    [get_bd_pins $ecg_proc/rst_n] \
    [get_bd_pins $ecg_gen/rst_n]

# The IOP drives its OWN peripheral_aresetn output, which resets the MB->PS
# memory path components (matches base S01_ARESETN_1 net).
connect_bd_net [get_bd_pins iop_pmodb/peripheral_aresetn] \
    [get_bd_pins $address_remap/s_axi_in_aresetn] \
    [get_bd_pins $address_remap/m_axi_out_aresetn] \
    [get_bd_pins $proto_conv/aresetn] \
    [get_bd_pins $mem_ic/S00_ARESETN] \
    [get_bd_pins $mem_ic/M00_ARESETN] \
    [get_bd_pins $mem_ic/ARESETN]

# ------------------------------------------------------------------------------
# 6 — AXI bus connections
# ------------------------------------------------------------------------------
puts "INFO: === Step 6: Connecting AXI buses ==="

# PS M_AXI_GP0 -> AXI-Lite interconnect S00
connect_bd_intf_net [get_bd_intf_pins $ps7/M_AXI_GP0] [get_bd_intf_pins $axi_lite_ic/S00_AXI]

# M00 -> ecg_process_top S_AXI (0x43C00000)
connect_bd_intf_net [get_bd_intf_pins $axi_lite_ic/M00_AXI] [get_bd_intf_pins $ecg_proc/S_AXI]

# M01 -> iop_pmodb S_AXI (PS writes MB firmware into BRAM @ 0x42000000)
connect_bd_intf_net [get_bd_intf_pins $axi_lite_ic/M01_AXI] [get_bd_intf_pins iop_pmodb/S_AXI]

# MB M_AXI -> address_remap -> protocol convert -> mem interconnect -> PS S_AXI_GP0
connect_bd_intf_net [get_bd_intf_pins iop_pmodb/M_AXI] [get_bd_intf_pins $address_remap/S_AXI_in]
connect_bd_intf_net [get_bd_intf_pins $address_remap/M_AXI_out] [get_bd_intf_pins $proto_conv/S_AXI]
connect_bd_intf_net [get_bd_intf_pins $proto_conv/M_AXI] [get_bd_intf_pins $mem_ic/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins $mem_ic/M00_AXI] [get_bd_intf_pins $ps7/S_AXI_GP0]

# IOP DEBUG <- MDM
connect_bd_intf_net [get_bd_intf_pins iop_pmodb/DEBUG] [get_bd_intf_pins $mdm/MBDEBUG_0]

# ------------------------------------------------------------------------------
# 7 — IOP control-signal wiring (interrupt, intr_ack, reset, debug reset)
# ------------------------------------------------------------------------------
puts "INFO: === Step 7: Connecting IOP control signals ==="

# intr_req -> concat -> PS IRQ_F2P
connect_bd_net [get_bd_pins iop_pmodb/intr_req] [get_bd_pins $irq_concat/In0]
connect_bd_net [get_bd_pins $irq_concat/dout] [get_bd_pins $ps7/IRQ_F2P]

# PS GPIO_O -> both slices ; slices -> IOP intr_ack / aux_reset_in
connect_bd_net [get_bd_pins $ps7/GPIO_O] \
    [get_bd_pins $slice_intr_ack/Din] \
    [get_bd_pins $slice_reset/Din]
connect_bd_net [get_bd_pins $slice_intr_ack/Dout] [get_bd_pins iop_pmodb/intr_ack]
connect_bd_net [get_bd_pins $slice_reset/Dout]    [get_bd_pins iop_pmodb/aux_reset_in]

# MDM debug system reset -> IOP
connect_bd_net [get_bd_pins $mdm/Debug_SYS_Rst] [get_bd_pins iop_pmodb/mb_debug_sys_rst]

# ------------------------------------------------------------------------------
# 8 — Inter-module ECG signal connections (gen <-> process)
# ------------------------------------------------------------------------------
puts "INFO: === Step 8: Connecting ECG datapath signals ==="

# gen.sample_valid_out -> process.sample_trigger
connect_bd_net [get_bd_pins $ecg_gen/sample_valid_out] [get_bd_pins $ecg_proc/sample_trigger]
# gen.sample_data_out  -> process.dac_sample_in
connect_bd_net [get_bd_pins $ecg_gen/sample_data_out]  [get_bd_pins $ecg_proc/dac_sample_in]
# process BPM/fluct outputs -> gen inputs
foreach ch {a b c d e f g h} {
    connect_bd_net [get_bd_pins $ecg_proc/bpm_ch_$ch] [get_bd_pins $ecg_gen/bpm_ch_$ch]
}
connect_bd_net [get_bd_pins $ecg_proc/rr_fluct]  [get_bd_pins $ecg_gen/rr_fluct]
connect_bd_net [get_bd_pins $ecg_proc/amp_fluct] [get_bd_pins $ecg_gen/amp_fluct]

# ------------------------------------------------------------------------------
# 9 — External ports
# ------------------------------------------------------------------------------
puts "INFO: === Step 9: Creating external ports ==="

# DAC SPI — JA header (ecg_signal_gen_top). Names match constraints_mb.xdc.
make_bd_pins_external [get_bd_pins $ecg_gen/dac_cs_n]
make_bd_pins_external [get_bd_pins $ecg_gen/dac_sclk]
make_bd_pins_external [get_bd_pins $ecg_gen/dac_din]
set_property name DAC_CS_N [get_bd_ports dac_cs_n_0]
set_property name DAC_SCLK [get_bd_ports dac_sclk_0]
set_property name DAC_DIN  [get_bd_ports dac_din_0]

# PMODB GPIO (io_switch tri-state bus) -> external gpio_rtl port "pmodb_gpio".
# The wrapper infers IOBUFs and exposes top-level inout pmodb_gpio_tri_io[7:0].
make_bd_intf_pins_external -name pmodb_gpio [get_bd_intf_pins iop_pmodb/pmodb_gpio]

# ------------------------------------------------------------------------------
# 10 — Address assignment
# ------------------------------------------------------------------------------
puts "INFO: === Step 10: Assigning addresses ==="

# --- PS (ps7_0/Data) view ---
# Our ECG processing block
assign_bd_address -offset 0x43C00000 -range 64K \
    -target_address_space [get_bd_addr_spaces $ps7/Data] \
    [get_bd_addr_segs $ecg_proc/S_AXI/reg0] -force
# IOP MicroBlaze BRAM (PYNQ loads pmod_iic.bin here) — MUST be 0x42000000
assign_bd_address -offset 0x42000000 -range 64K \
    -target_address_space [get_bd_addr_spaces $ps7/Data] \
    [get_bd_addr_segs iop_pmodb/mb_bram_ctrl/S_AXI/Mem0] -force

# --- MB->PS DRAM window (address_remap out maps to PS S_AXI_GP0 @ 0x0) ---
assign_bd_address -offset 0x00000000 -range 0x20000000 \
    -target_address_space [get_bd_addr_spaces $address_remap/M_AXI_out] \
    [get_bd_addr_segs $ps7/S_AXI_GP0/GP0_DDR_LOWOCM] -force

# --- MB (iop_pmodb/mb/Data) view — firmware-critical, MUST match exactly ---
assign_bd_address -offset 0x20000000 -range 0x20000000 \
    -target_address_space [get_bd_addr_spaces iop_pmodb/mb/Data] \
    [get_bd_addr_segs $address_remap/S_AXI_in/memory] -force
assign_bd_address -offset 0x40000000 -range 64K \
    -target_address_space [get_bd_addr_spaces iop_pmodb/mb/Data] \
    [get_bd_addr_segs iop_pmodb/gpio/S_AXI/Reg] -force
assign_bd_address -offset 0x40010000 -range 64K \
    -target_address_space [get_bd_addr_spaces iop_pmodb/mb/Data] \
    [get_bd_addr_segs iop_pmodb/intr/S_AXI/Reg] -force
assign_bd_address -offset 0x40800000 -range 64K \
    -target_address_space [get_bd_addr_spaces iop_pmodb/mb/Data] \
    [get_bd_addr_segs iop_pmodb/iic/S_AXI/Reg] -force
assign_bd_address -offset 0x41200000 -range 64K \
    -target_address_space [get_bd_addr_spaces iop_pmodb/mb/Data] \
    [get_bd_addr_segs iop_pmodb/intc/S_AXI/Reg] -force
assign_bd_address -offset 0x41C00000 -range 64K \
    -target_address_space [get_bd_addr_spaces iop_pmodb/mb/Data] \
    [get_bd_addr_segs iop_pmodb/timer/S_AXI/Reg] -force
assign_bd_address -offset 0x44A10000 -range 64K \
    -target_address_space [get_bd_addr_spaces iop_pmodb/mb/Data] \
    [get_bd_addr_segs iop_pmodb/spi/AXI_LITE/Reg] -force
assign_bd_address -offset 0x44A20000 -range 64K \
    -target_address_space [get_bd_addr_spaces iop_pmodb/mb/Data] \
    [get_bd_addr_segs iop_pmodb/io_switch/S_AXI/S_AXI_reg] -force
assign_bd_address -offset 0x00000000 -range 64K \
    -target_address_space [get_bd_addr_spaces iop_pmodb/mb/Data] \
    [get_bd_addr_segs iop_pmodb/lmb/lmb_bram_if_cntlr/SLMB1/Mem] -force
assign_bd_address -offset 0x00000000 -range 64K \
    -target_address_space [get_bd_addr_spaces iop_pmodb/mb/Instruction] \
    [get_bd_addr_segs iop_pmodb/lmb/lmb_bram_if_cntlr/SLMB/Mem] -force

# ------------------------------------------------------------------------------
# 11 — Validate and save block design
# ------------------------------------------------------------------------------
puts "INFO: === Step 11: Validating block design ==="
validate_bd_design
save_bd_design
puts "INFO: Block design validated and saved"

# ------------------------------------------------------------------------------
# 12 — Generate wrapper and set as top
# ------------------------------------------------------------------------------
puts "INFO: === Step 12: Generating HDL wrapper ==="
make_wrapper -files [get_files ecg_system.bd] -top
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
# 13 — Synthesis, implementation, bitstream
# ------------------------------------------------------------------------------
puts "INFO: === Step 13: Running synthesis (this takes several minutes) ==="
launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
    set status [get_property STATUS [get_runs synth_1]]
    error "ERROR: Synthesis failed — status: $status"
}
puts "INFO: Synthesis complete"

puts "INFO: === Step 13b: Running implementation + bitstream (~15-20 minutes) ==="
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

set bit_src [file join $project_dir ${project_name}.runs impl_1 ecg_system_wrapper.bit]
set hwh_src ""
foreach d {gen srcs} {
    set try [file join $project_dir \
        ${project_name}.${d} sources_1 bd ecg_system hw_handoff ecg_system.hwh]
    if {[file exists $try]} { set hwh_src $try; break }
}
set ps_dir [file join $repo_root ps]

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
puts "INFO: BUILD COMPLETE — MicroBlaze PMODB IOP overlay"
puts "INFO: Bitstream: ps/ecg_demo.bit"
puts "INFO: HWH file:  ps/ecg_demo.hwh"
puts "INFO: IOP hierarchy 'iop_pmodb' — bind with Pmod_IIC(ol.iop_pmodb,2,3,0x28)"
puts "INFO: ============================================================"
