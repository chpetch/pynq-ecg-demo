// Module   : ecg_dds
// Project  : PYNQ-Z2 ECG Demo
// Agent    : pynq_ecg_gen
// Purpose  : DDS stepping through ECG ROM with HRV and amplitude fluctuation

`timescale 1ns / 1ps

module ecg_dds (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [7:0]  bpm_config,
    input  wire [7:0]  rr_fluct,
    input  wire [7:0]  amp_fluct,
    output reg  [11:0] sample_data,
    output reg         sample_valid
);

    // -----------------------------------------------------------------------
    // Constants
    // -----------------------------------------------------------------------
    localparam CLK_FREQ        = 100_000_000;  // 100 MHz
    localparam ROM_DEPTH       = 360;          // samples per cardiac cycle
    localparam ADDR_MAX        = 9'd359;

    // -----------------------------------------------------------------------
    // LFSR 1 — RR interval fluctuation (polynomial x^8+x^6+x^5+x^4+1)
    // Taps at bits 7,5,4,3 (1-indexed from MSB = bit 7 of 8-bit)
    // Feedback = bit7 ^ bit5 ^ bit4 ^ bit3
    // -----------------------------------------------------------------------
    reg [7:0] lfsr1;
    wire lfsr1_feedback = lfsr1[7] ^ lfsr1[5] ^ lfsr1[4] ^ lfsr1[3];

    // -----------------------------------------------------------------------
    // LFSR 2 — Amplitude fluctuation (independent, same polynomial)
    // Seeded with a different non-zero value
    // -----------------------------------------------------------------------
    reg [7:0] lfsr2;
    wire lfsr2_feedback = lfsr2[7] ^ lfsr2[5] ^ lfsr2[4] ^ lfsr2[3];

    // -----------------------------------------------------------------------
    // Phase counter and reload value computation
    // base_reload = 100_000_000 / (bpm_config * 6) - 1
    // We compute this with a 32-bit divider pipeline.
    //
    // Since bpm_config can range 30-240 and CLK_FREQ=100M:
    //   max base_reload (bpm=30):  100M / 180 - 1 = 555554
    //   min base_reload (bpm=240): 100M / 1440 - 1 = 69443
    // Needs 20 bits.
    //
    // Division is expensive in hardware; we use a registered quotient
    // computed once when bpm_config changes, using a multi-cycle divider.
    // For synthesis simplicity we use a precalculated approach with a
    // runtime-capable sequential divider.
    // -----------------------------------------------------------------------

    // Divider: compute 100_000_000 / (bpm_config * 6)
    // We do this with a simple restoring-division state machine.
    // Dividend = 32'd100_000_000, Divisor = {24'd0, bpm_config} * 6

    localparam DIV_BITS  = 32;
    localparam DIVIDEND  = 32'd100_000_000;

    reg [31:0] base_reload;        // registered result
    reg [31:0] div_remainder;
    reg [31:0] div_quotient;
    reg [5:0]  div_bit;            // counts 0..31
    reg        div_busy;
    reg [31:0] divisor_reg;
    reg [7:0]  bpm_prev;           // to detect bpm_config changes

    // actual_reload incorporates rr_fluct HRV
    // actual_reload = base_reload + ((lfsr1 * rr_fluct) >> 8) - (rr_fluct >> 1)
    // Clamp to minimum of 1
    reg [31:0] actual_reload;

    // Phase counter
    reg [31:0] phase_cnt;
    reg [8:0]  rom_addr;

    // ROM interface
    wire [11:0] rom_data;

    // Amplitude scaling pipeline
    // scaled_sample = rom_data * (256 + ((lfsr2*amp_fluct)>>8) - (amp_fluct>>1)) >> 8
    // multiplier intermediate: 12-bit * 9-bit = 21-bit, then >>8 -> 13-bit, clip to 12
    reg [20:0] amp_scale_product;  // rom_data[11:0] * scale[8:0]
    reg [8:0]  amp_scale;          // 256 + delta - offset, clamped to 9-bit (max 511)
    reg [15:0] lfsr_amp_term;      // (lfsr2 * amp_fluct) -> 16-bit before >>8

    // One-cycle pipeline registers for amplitude computation
    reg [11:0] rom_data_d1;
    reg        addr_valid_d1;      // rom data valid one cycle after addr presented

    // -----------------------------------------------------------------------
    // ecg_rom instantiation
    // -----------------------------------------------------------------------
    ecg_rom u_rom (
        .clk  (clk),
        .addr (rom_addr),
        .data (rom_data)
    );

    // -----------------------------------------------------------------------
    // Division state machine — recompute base_reload on bpm_config change
    // -----------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            base_reload   <= 32'd138888;  // 100M / (60*6) - 1 = 277777, /2 default
            div_busy      <= 1'b0;
            div_bit       <= 6'd0;
            div_remainder <= 32'd0;
            div_quotient  <= 32'd0;
            divisor_reg   <= 32'd0;
            bpm_prev      <= 8'd0;
            // Correct reset value: 100M/(60*6)-1 = 277777
            base_reload   <= 32'd277777;
        end else begin
            if (bpm_config != bpm_prev && !div_busy) begin
                // Start division
                bpm_prev      <= bpm_config;
                divisor_reg   <= {24'd0, bpm_config} * 32'd6;
                div_remainder <= DIVIDEND;
                div_quotient  <= 32'd0;
                div_bit       <= 6'd31;
                div_busy      <= 1'b1;
            end else if (div_busy) begin
                // Non-restoring step: check if remainder >= shifted divisor
                // Simple restoring long division
                if (div_remainder >= (divisor_reg << div_bit)) begin
                    div_remainder <= div_remainder - (divisor_reg << div_bit);
                    div_quotient  <= div_quotient | (32'd1 << div_bit);
                end
                if (div_bit == 6'd0) begin
                    div_busy    <= 1'b0;
                    // quotient is 100M/(bpm*6); reload = quotient - 1
                    base_reload <= (div_quotient > 32'd0) ? div_quotient - 32'd1
                                                          : 32'd0;
                end else begin
                    div_bit <= div_bit - 6'd1;
                end
            end
        end
    end

    // -----------------------------------------------------------------------
    // actual_reload computation (combinational, updated each cycle)
    // -----------------------------------------------------------------------
    always @(*) begin
        // (lfsr1 * rr_fluct) is 16-bit, >>8 gives 8-bit delta
        // subtract (rr_fluct >> 1) to centre the fluctuation
        // signed arithmetic: use 32-bit
        reg [15:0] fluct_product;
        reg [31:0] fluct_delta;
        reg [31:0] fluct_offset;
        fluct_product = {8'd0, lfsr1} * {8'd0, rr_fluct};       // 16-bit
        fluct_delta   = {24'd0, fluct_product[15:8]};            // >>8
        fluct_offset  = {25'd0, rr_fluct[7:1]};                  // rr_fluct>>1
        // actual_reload = base_reload + fluct_delta - fluct_offset
        // Prevent underflow: clamp to 1
        if (base_reload + fluct_delta >= fluct_offset + 32'd1)
            actual_reload = base_reload + fluct_delta - fluct_offset;
        else
            actual_reload = 32'd1;
    end

    // -----------------------------------------------------------------------
    // Phase counter — advances ROM address
    // -----------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase_cnt    <= 32'd0;
            rom_addr     <= 9'd0;
            addr_valid_d1 <= 1'b0;
            lfsr1        <= 8'hA5;   // non-zero seed
            lfsr2        <= 8'h5A;   // different non-zero seed
        end else begin
            addr_valid_d1 <= 1'b0;

            if (phase_cnt == actual_reload) begin
                phase_cnt     <= 32'd0;
                addr_valid_d1 <= 1'b1;

                if (rom_addr == ADDR_MAX) begin
                    rom_addr <= 9'd0;
                    // Advance both LFSRs once per cardiac cycle
                    lfsr1    <= {lfsr1[6:0], lfsr1_feedback};
                    lfsr2    <= {lfsr2[6:0], lfsr2_feedback};
                end else begin
                    rom_addr <= rom_addr + 9'd1;
                end
            end else begin
                phase_cnt <= phase_cnt + 32'd1;
            end
        end
    end

    // -----------------------------------------------------------------------
    // Amplitude scaling — 1-cycle pipeline after rom_data is valid
    // ROM has 1-cycle latency, so rom_data is valid the cycle after addr_valid_d1
    // -----------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sample_data  <= 12'd0;
            sample_valid <= 1'b0;
        end else begin
            sample_valid <= 1'b0;

            if (addr_valid_d1) begin
                // rom_data is registered output valid this cycle
                // Compute amplitude scale factor
                // scale = 256 + ((lfsr2*amp_fluct)>>8) - (amp_fluct>>1)
                // Use 16-bit intermediates
                begin
                    reg [15:0] amp_product;
                    reg [8:0]  amp_delta;
                    reg [8:0]  amp_offset;
                    reg [9:0]  scale_sum;
                    reg [8:0]  scale_clamped;
                    reg [20:0] scaled_full;
                    reg [12:0] scaled_shifted;

                    amp_product   = {8'd0, lfsr2} * {8'd0, amp_fluct};
                    amp_delta     = {1'b0, amp_product[15:8]};  // 9-bit
                    amp_offset    = {2'd0, amp_fluct[7:1]};      // 9-bit
                    // scale = 256 + delta - offset; may underflow -> clamp to 1
                    scale_sum     = {1'b0, 9'd256} + {1'b0, amp_delta};
                    if (scale_sum >= {1'b0, amp_offset})
                        scale_clamped = scale_sum[8:0] - amp_offset;
                    else
                        scale_clamped = 9'd1;

                    // scaled = rom_data * scale >> 8
                    scaled_full   = {9'd0, rom_data} * {9'd0, scale_clamped};
                    scaled_shifted = scaled_full[20:8];  // >>8

                    // Clip to 12 bits
                    if (scaled_shifted > 13'd4095)
                        sample_data <= 12'd4095;
                    else
                        sample_data <= scaled_shifted[11:0];

                    sample_valid <= 1'b1;
                end
            end
        end
    end

endmodule
