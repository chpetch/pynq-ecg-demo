// Module   : ecg_signal_gen_top
// Project  : PYNQ-Z2 ECG Demo
// Agent    : pynq_ecg_gen
// Purpose  : Top-level ECG signal generator — 8 DDS channels into SPI DAC

// Instantiates:
//   - 1x ecg_rom  (shared by all DDS instances)
//   - 8x ecg_dds  (one per DAC channel, each with its own phase counter)
//   - 1x spi_dac_driver  (drives PMOD DA4 AD5628-1 over SPI)
//
// All bpm_ch_* inputs are plain wires to be driven by the AXI-Lite slave
// implemented by the pynq_ecg_process agent.
//
// PMOD JA header wiring (see agents/pynq_ecg_gen.md):
//   JA[0] = DAC_CS_N, JA[1] = DAC_DIN, JA[3] = DAC_SCLK

`timescale 1ns / 1ps

module ecg_signal_gen_top (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [7:0]  bpm_ch_a,      // Ch A heart rate (default 60)
    input  wire [7:0]  bpm_ch_b,      // Ch B heart rate (default 40)
    input  wire [7:0]  bpm_ch_c,      // Ch C heart rate (default 50)
    input  wire [7:0]  bpm_ch_d,      // Ch D heart rate (default 70)
    input  wire [7:0]  bpm_ch_e,      // Ch E heart rate (default 80)
    input  wire [7:0]  bpm_ch_f,      // Ch F heart rate (default 100)
    input  wire [7:0]  bpm_ch_g,      // Ch G heart rate (default 120)
    input  wire [7:0]  bpm_ch_h,      // Ch H heart rate (default 150)
    input  wire [7:0]  rr_fluct,      // RR interval variation 0-255
    input  wire [7:0]  amp_fluct,     // peak amplitude variation 0-255
    output wire        dac_cs_n,
    output wire        dac_sclk,
    output wire        dac_din,
    output wire        sample_valid_out  // Ch A sample_valid for ADC trigger
);

    // -----------------------------------------------------------------------
    // Internal wires from DDS instances to SPI driver
    // -----------------------------------------------------------------------
    wire [11:0] sample_a, sample_b, sample_c, sample_d;
    wire [11:0] sample_e, sample_f, sample_g, sample_h;
    wire        valid_a, valid_b, valid_c, valid_d;
    wire        valid_e, valid_f, valid_g, valid_h;

    // Ch A sample_valid is the master trigger for the SPI driver
    assign sample_valid_out = valid_a;

    // -----------------------------------------------------------------------
    // ecg_dds — Channel A (60 BPM default, configurable)
    // -----------------------------------------------------------------------
    ecg_dds dds_a (
        .clk         (clk),
        .rst_n       (rst_n),
        .bpm_config  (bpm_ch_a),
        .rr_fluct    (rr_fluct),
        .amp_fluct   (amp_fluct),
        .sample_data (sample_a),
        .sample_valid(valid_a)
    );

    // -----------------------------------------------------------------------
    // ecg_dds — Channel B (40 BPM default)
    // -----------------------------------------------------------------------
    ecg_dds dds_b (
        .clk         (clk),
        .rst_n       (rst_n),
        .bpm_config  (bpm_ch_b),
        .rr_fluct    (rr_fluct),
        .amp_fluct   (amp_fluct),
        .sample_data (sample_b),
        .sample_valid(valid_b)
    );

    // -----------------------------------------------------------------------
    // ecg_dds — Channel C (50 BPM default)
    // -----------------------------------------------------------------------
    ecg_dds dds_c (
        .clk         (clk),
        .rst_n       (rst_n),
        .bpm_config  (bpm_ch_c),
        .rr_fluct    (rr_fluct),
        .amp_fluct   (amp_fluct),
        .sample_data (sample_c),
        .sample_valid(valid_c)
    );

    // -----------------------------------------------------------------------
    // ecg_dds — Channel D (70 BPM default)
    // -----------------------------------------------------------------------
    ecg_dds dds_d (
        .clk         (clk),
        .rst_n       (rst_n),
        .bpm_config  (bpm_ch_d),
        .rr_fluct    (rr_fluct),
        .amp_fluct   (amp_fluct),
        .sample_data (sample_d),
        .sample_valid(valid_d)
    );

    // -----------------------------------------------------------------------
    // ecg_dds — Channel E (80 BPM default)
    // -----------------------------------------------------------------------
    ecg_dds dds_e (
        .clk         (clk),
        .rst_n       (rst_n),
        .bpm_config  (bpm_ch_e),
        .rr_fluct    (rr_fluct),
        .amp_fluct   (amp_fluct),
        .sample_data (sample_e),
        .sample_valid(valid_e)
    );

    // -----------------------------------------------------------------------
    // ecg_dds — Channel F (100 BPM default)
    // -----------------------------------------------------------------------
    ecg_dds dds_f (
        .clk         (clk),
        .rst_n       (rst_n),
        .bpm_config  (bpm_ch_f),
        .rr_fluct    (rr_fluct),
        .amp_fluct   (amp_fluct),
        .sample_data (sample_f),
        .sample_valid(valid_f)
    );

    // -----------------------------------------------------------------------
    // ecg_dds — Channel G (120 BPM default)
    // -----------------------------------------------------------------------
    ecg_dds dds_g (
        .clk         (clk),
        .rst_n       (rst_n),
        .bpm_config  (bpm_ch_g),
        .rr_fluct    (rr_fluct),
        .amp_fluct   (amp_fluct),
        .sample_data (sample_g),
        .sample_valid(valid_g)
    );

    // -----------------------------------------------------------------------
    // ecg_dds — Channel H (150 BPM default)
    // -----------------------------------------------------------------------
    ecg_dds dds_h (
        .clk         (clk),
        .rst_n       (rst_n),
        .bpm_config  (bpm_ch_h),
        .rr_fluct    (rr_fluct),
        .amp_fluct   (amp_fluct),
        .sample_data (sample_h),
        .sample_valid(valid_h)
    );

    // -----------------------------------------------------------------------
    // SPI DAC driver
    // Triggered by Ch A sample_valid (master trigger)
    // All 8 channels share the same valid strobe; their samples are latched
    // simultaneously into spi_dac_driver when valid_a fires.
    // -----------------------------------------------------------------------
    spi_dac_driver u_spi (
        .clk           (clk),
        .rst_n         (rst_n),
        .sample_data_0 (sample_a),
        .sample_data_1 (sample_b),
        .sample_data_2 (sample_c),
        .sample_data_3 (sample_d),
        .sample_data_4 (sample_e),
        .sample_data_5 (sample_f),
        .sample_data_6 (sample_g),
        .sample_data_7 (sample_h),
        .sample_valid  (valid_a),
        .dac_cs_n      (dac_cs_n),
        .dac_sclk      (dac_sclk),
        .dac_din       (dac_din),
        .busy          ()         // unused at top level
    );

endmodule
