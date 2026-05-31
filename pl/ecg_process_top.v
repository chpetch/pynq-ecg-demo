// Module   : ecg_process_top
// Project  : PYNQ-Z2 ECG Demo
// Agent    : pynq_ecg_process
// Purpose  : Top-level wrapper instantiating FIR filter, R-peak detector, and
//            AXI4-Lite control registers. ADC sampling moved to PS — PS reads
//            from a Xilinx AXI IIC IP (in the block design) and writes the
//            12-bit sample into ECG_RAW (0x28) which feeds the FIR.
//
// CLOCKING / CDC CONTRACT (do not break):
//   This module has two clock inputs, `clk` (signal-gen + processing pipeline)
//   and `s_axi_aclk` (AXI4-Lite slave). Control/status signals cross between the
//   AXI domain (u_axi_ctrl) and the pipeline domain (FIR / R-peak) WITHOUT CDC
//   synchronizers. This is SAFE **only because both clocks are driven from the
//   same source** — FCLK_CLK0 @ 100 MHz — in vivado/create_project.tcl
//   (clk and s_axi_aclk both connect to ps7/FCLK_CLK0), so the two "domains" are
//   one synchronous domain and Vivado STA closes timing on the direct paths.
//   ⚠ If `clk` and `s_axi_aclk` are ever sourced from DIFFERENT clocks (e.g. a
//   future build drives the pipeline from FCLK_CLK1 for timing), they become
//   asynchronous and these direct crossings will be metastable. In that case add
//   2-FF synchronizers for the stable config buses (bpm_ch_*, rr_fluct,
//   amp_fluct, detect_thresh) and proper PULSE synchronizers for single-cycle
//   strobes (adc_valid_out, rpeak_in) before changing the clock topology.

module ecg_process_top (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        sample_trigger,   // from ecg_signal_gen_top sample_valid_out

    // AXI4-Lite slave interface
    input  wire        s_axi_aclk,
    input  wire        s_axi_aresetn,

    // Write address channel
    input  wire [31:0] s_axi_awaddr,
    input  wire [2:0]  s_axi_awprot,
    input  wire        s_axi_awvalid,
    output wire        s_axi_awready,

    // Write data channel
    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output wire        s_axi_wready,

    // Write response channel
    output wire [1:0]  s_axi_bresp,
    output wire        s_axi_bvalid,
    input  wire        s_axi_bready,

    // Read address channel
    input  wire [31:0] s_axi_araddr,
    input  wire [2:0]  s_axi_arprot,
    input  wire        s_axi_arvalid,
    output wire        s_axi_arready,

    // Read data channel
    output wire [31:0] s_axi_rdata,
    output wire [1:0]  s_axi_rresp,
    output wire        s_axi_rvalid,
    input  wire        s_axi_rready,

    // DAC waveform sample from DDS (Ch A) for register 0x40
    input  wire [11:0] dac_sample_in,

    // Output wires to ecg_signal_gen_top (BPM + modulation parameters)
    output wire [7:0]  bpm_ch_a,
    output wire [7:0]  bpm_ch_b,
    output wire [7:0]  bpm_ch_c,
    output wire [7:0]  bpm_ch_d,
    output wire [7:0]  bpm_ch_e,
    output wire [7:0]  bpm_ch_f,
    output wire [7:0]  bpm_ch_g,
    output wire [7:0]  bpm_ch_h,
    output wire [7:0]  rr_fluct,
    output wire [7:0]  amp_fluct
);

    // ---------------------------------------------------------------------------
    // Internal signals
    // ---------------------------------------------------------------------------
    // adc_data / adc_valid now come from the AXI register file (PS-written
    // via the Xilinx AXI IIC IP) rather than the deleted i2c_adc_driver.
    wire [11:0] adc_data;
    wire        adc_valid;

    wire [11:0] fir_data_out;
    wire        fir_valid_out;

    wire        rpeak_detected;
    wire [7:0]  bpm_measured;

    wire [11:0] detect_thresh;

    // ---------------------------------------------------------------------------
    // fir_filter: 31-tap bandpass, Q1.15 coefficients from algorithm_spec.md
    // ---------------------------------------------------------------------------
    fir_filter u_fir (
        .clk           (clk),
        .rst_n         (rst_n),
        .data_in       (adc_data),
        .data_valid    (adc_valid),
        .data_out      (fir_data_out),
        .data_valid_out(fir_valid_out)
    );

    // ---------------------------------------------------------------------------
    // rpeak_detector: Pan-Tompkins threshold, 72-sample refractory, BPM output
    // ---------------------------------------------------------------------------
    rpeak_detector u_rpeak (
        .clk                (clk),
        .rst_n              (rst_n),
        .ecg_sample         (fir_data_out),
        .sample_valid       (fir_valid_out),
        .detection_threshold(detect_thresh),
        .rpeak_detected     (rpeak_detected),
        .bpm_out            (bpm_measured)
    );

    // ---------------------------------------------------------------------------
    // axi_ecg_ctrl: AXI4-Lite slave, full register map 0x00-0x3C
    // ---------------------------------------------------------------------------
    axi_ecg_ctrl u_axi_ctrl (
        .s_axi_aclk    (s_axi_aclk),
        .s_axi_aresetn (s_axi_aresetn),

        .s_axi_awaddr  (s_axi_awaddr),
        .s_axi_awprot  (s_axi_awprot),
        .s_axi_awvalid (s_axi_awvalid),
        .s_axi_awready (s_axi_awready),

        .s_axi_wdata   (s_axi_wdata),
        .s_axi_wstrb   (s_axi_wstrb),
        .s_axi_wvalid  (s_axi_wvalid),
        .s_axi_wready  (s_axi_wready),

        .s_axi_bresp   (s_axi_bresp),
        .s_axi_bvalid  (s_axi_bvalid),
        .s_axi_bready  (s_axi_bready),

        .s_axi_araddr  (s_axi_araddr),
        .s_axi_arprot  (s_axi_arprot),
        .s_axi_arvalid (s_axi_arvalid),
        .s_axi_arready (s_axi_arready),

        .s_axi_rdata   (s_axi_rdata),
        .s_axi_rresp   (s_axi_rresp),
        .s_axi_rvalid  (s_axi_rvalid),
        .s_axi_rready  (s_axi_rready),

        // Outputs to signal gen
        .bpm_ch_a      (bpm_ch_a),
        .bpm_ch_b      (bpm_ch_b),
        .bpm_ch_c      (bpm_ch_c),
        .bpm_ch_d      (bpm_ch_d),
        .bpm_ch_e      (bpm_ch_e),
        .bpm_ch_f      (bpm_ch_f),
        .bpm_ch_g      (bpm_ch_g),
        .bpm_ch_h      (bpm_ch_h),
        .rr_fluct      (rr_fluct),
        .amp_fluct     (amp_fluct),
        .detect_thresh (detect_thresh),

        // Inputs from processing pipeline
        .ecg_filt_in   (fir_data_out),
        .bpm_in        (bpm_measured),
        .rpeak_in      (rpeak_detected),

        // ECG_RAW is now PS-written via AXI; expose its value + write-pulse
        // back out so the FIR sees fresh samples whenever PS writes 0x28.
        .adc_data_out  (adc_data),
        .adc_valid_out (adc_valid),

        // DAC waveform sample from DDS
        .dac_sample_in (dac_sample_in)
    );

endmodule
