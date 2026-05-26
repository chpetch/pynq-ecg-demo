// Module   : ecg_process_top
// Project  : PYNQ-Z2 ECG Demo
// Agent    : pynq_ecg_process
// Purpose  : Top-level wrapper instantiating I2C ADC driver, FIR filter,
//            R-peak detector, and AXI4-Lite control registers

module ecg_process_top (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        sample_trigger,   // from ecg_signal_gen_top sample_valid_out

    // ADC I2C pins (PMOD AD2, JB header)
    inout  wire        adc_sda,
    output wire        adc_scl,

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
    wire [11:0] adc_data;
    wire        adc_valid;

    wire [11:0] fir_data_out;
    wire        fir_valid_out;

    wire        rpeak_detected;
    wire [7:0]  bpm_measured;

    wire [11:0] detect_thresh;

    // ---------------------------------------------------------------------------
    // i2c_adc_driver: triggered by sample_trigger, reads 12-bit ADC via I2C
    // ---------------------------------------------------------------------------
    i2c_adc_driver u_i2c_adc (
        .clk       (clk),
        .rst_n     (rst_n),
        .start     (sample_trigger),
        .adc_sda   (adc_sda),
        .adc_scl   (adc_scl),
        .adc_data  (adc_data),
        .adc_valid (adc_valid)
    );

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
        .ecg_raw_in    (adc_data),
        .ecg_filt_in   (fir_data_out),
        .bpm_in        (bpm_measured),
        .rpeak_in      (rpeak_detected),

        // DAC waveform sample from DDS
        .dac_sample_in (dac_sample_in)
    );

endmodule
