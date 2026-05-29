// Module   : i2c_test_top
// Project  : PYNQ-Z2 ECG Demo  (I2C bring-up / scope harness)
// Purpose  : Minimal PL-only top that contains ONLY i2c_adc_driver, plus a VIO
//            to drive `start` / read back adc_data over JTAG and an ILA (inserted
//            post-synthesis via mark_debug, see vivado/create_i2c_test.tcl) to
//            scope the SDA/SCL bus. No AXI, no FIR, no PYNQ — JTAG only.
//
// Clock    : Zynq PS7 FCLK_CLK0 = 100 MHz (exact, matches CLK_DIV=499 → 100 kHz SCL).
// Reset    : proc_sys_reset peripheral_aresetn (active low).
//
// PMOD AD2 wiring (reproduces last-known failing config — see milestone_log):
//   adc_scl -> JB[2] = V10 (PMOD AD2 Pin 1)
//   adc_sda -> JB[3] = W10 (PMOD AD2 Pin 2)
//   Tie AD2 CH0 to VCC (or leave floating) for the read-back sanity value.

module i2c_test_top (
    // --- Zynq PS7 hard-IP external interface (clock/reset source only) ---
    inout  [14:0] DDR_addr,
    inout  [2:0]  DDR_ba,
    inout         DDR_cas_n,
    inout         DDR_ck_n,
    inout         DDR_ck_p,
    inout         DDR_cke,
    inout         DDR_cs_n,
    inout  [3:0]  DDR_dm,
    inout  [31:0] DDR_dq,
    inout  [3:0]  DDR_dqs_n,
    inout  [3:0]  DDR_dqs_p,
    inout         DDR_odt,
    inout         DDR_ras_n,
    inout         DDR_reset_n,
    inout         DDR_we_n,
    inout         FIXED_IO_ddr_vrn,
    inout         FIXED_IO_ddr_vrp,
    inout  [53:0] FIXED_IO_mio,
    inout         FIXED_IO_ps_clk,
    inout         FIXED_IO_ps_porb,
    inout         FIXED_IO_ps_srstb,

    // --- PMOD AD2 I2C (JB header) ---
    inout         adc_scl,    // JB[2] = V10 (open-drain)
    inout         adc_sda,    // JB[3] = W10

    // --- optional eyeball: led[1]=adc_valid pulse, led[0]=any data bit set ---
    output [1:0]  led
);

    // -------------------------------------------------------------------------
    // Block design: Zynq PS7 + proc_sys_reset.  Provides clock + reset only.
    // Wrapper port names are fixed by vivado/create_i2c_test.tcl:
    //   FCLK_CLK0           -> clk   (100 MHz)
    //   peripheral_aresetn  -> resetn (active low, [0:0])
    // -------------------------------------------------------------------------
    wire        clk;
    wire [0:0]  periph_aresetn;
    wire        resetn = periph_aresetn[0];

    i2c_test_bd_wrapper u_bd (
        .DDR_addr           (DDR_addr),
        .DDR_ba             (DDR_ba),
        .DDR_cas_n          (DDR_cas_n),
        .DDR_ck_n           (DDR_ck_n),
        .DDR_ck_p           (DDR_ck_p),
        .DDR_cke            (DDR_cke),
        .DDR_cs_n           (DDR_cs_n),
        .DDR_dm             (DDR_dm),
        .DDR_dq             (DDR_dq),
        .DDR_dqs_n          (DDR_dqs_n),
        .DDR_dqs_p          (DDR_dqs_p),
        .DDR_odt            (DDR_odt),
        .DDR_ras_n          (DDR_ras_n),
        .DDR_reset_n        (DDR_reset_n),
        .DDR_we_n           (DDR_we_n),
        .FIXED_IO_ddr_vrn   (FIXED_IO_ddr_vrn),
        .FIXED_IO_ddr_vrp   (FIXED_IO_ddr_vrp),
        .FIXED_IO_mio       (FIXED_IO_mio),
        .FIXED_IO_ps_clk    (FIXED_IO_ps_clk),
        .FIXED_IO_ps_porb   (FIXED_IO_ps_porb),
        .FIXED_IO_ps_srstb  (FIXED_IO_ps_srstb),
        .FCLK_CLK0          (clk),
        .peripheral_aresetn (periph_aresetn)
    );

    // -------------------------------------------------------------------------
    // VIO: probe_out0 = start (JTAG-driven), probe_in0 = adc_data, probe_in1 = adc_valid
    // IP `vio_0` is created by the TCL (1x 1-bit out, 12-bit + 1-bit in).
    // -------------------------------------------------------------------------
    wire                              start_vio;
    (* mark_debug = "true" *) wire [11:0] adc_data;
    (* mark_debug = "true" *) wire        adc_valid;

    vio_0 u_vio (
        .clk        (clk),
        .probe_in0  (adc_data),
        .probe_in1  (adc_valid),
        .probe_out0 (start_vio)
    );

    // Rising-edge detect: each VIO 0->1 press fires exactly one I2C transaction,
    // giving a clean single ILA capture. (Hold high = one shot per press, not free-run.)
    reg start_vio_d;
    always @(posedge clk) begin
        if (!resetn) start_vio_d <= 1'b0;
        else         start_vio_d <= start_vio;
    end
    wire start_pulse = start_vio & ~start_vio_d;

    // -------------------------------------------------------------------------
    // The unit under test — unchanged behaviour, mark_debug nets feed the ILA.
    // -------------------------------------------------------------------------
    i2c_adc_driver u_i2c (
        .clk       (clk),
        .rst_n     (resetn),
        .start     (start_pulse),
        .adc_sda   (adc_sda),
        .adc_scl   (adc_scl),
        .adc_data  (adc_data),
        .adc_valid (adc_valid)
    );

    assign led = {adc_valid, |adc_data};

endmodule
