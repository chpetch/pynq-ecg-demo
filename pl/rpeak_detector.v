// Module   : rpeak_detector
// Project  : PYNQ-Z2 ECG Demo
// Agent    : pynq_ecg_process
// Purpose  : Pan-Tompkins R-peak detector with refractory period and BPM output

// Algorithm spec source: handoffs/algorithm_spec.md
//   Detection condition : filtered_sample > detection_threshold
//   Default threshold   : 2983 (12-bit unsigned, from validation)
//   Refractory period   : 72 samples (200 ms at 360 Hz), hard-coded in RTL
//   BPM formula         : bpm = (360 * 60) / sample_interval = 21600 / interval
//   Interval counter    : 16-bit, saturates at 0xFFFF -> BPM = 0 (no-signal)
//   BPM computation     : LUT-based (16-bit divider via lookup table for RTL safety)

module rpeak_detector (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [11:0] ecg_sample,
    input  wire        sample_valid,
    input  wire [11:0] detection_threshold,  // from AXI register
    output reg         rpeak_detected,
    output reg  [7:0]  bpm_out
);

    // ---------------------------------------------------------------------------
    // Parameters — from handoffs/algorithm_spec.md (do not change)
    // ---------------------------------------------------------------------------
    localparam [6:0]  REFRACTORY_SAMPLES = 7'd72;  // 200 ms at 360 Hz
    localparam [15:0] INTERVAL_SATURATE  = 16'hFFFF;
    // BPM = 21600 / interval  (360 * 60)
    // Minimum measurable interval for 240 BPM: 21600/240 = 90 samples
    // Maximum BPM register is 8-bit unsigned (0-255)

    // ---------------------------------------------------------------------------
    // Registers
    // ---------------------------------------------------------------------------
    reg [15:0] interval_cnt;   // counts samples between R-peaks (16-bit)
    reg [15:0] last_interval;  // latched interval at each R-peak
    reg [6:0]  refractory_cnt; // counts down refractory period after each R-peak
    reg        in_refractory;  // asserted during refractory period
    reg        prev_above;     // sample was above threshold last valid cycle
                               // (edge detection: rising edge only)

    // ---------------------------------------------------------------------------
    // BPM lookup — combinational 16->8-bit divider approximation
    // bpm = 21600 / interval, clamped to [0, 255]
    // For intervals >= 21600/1 = 21600 (impossible in 16-bit for BPM<1), BPM=0
    // For intervals <= 21600/255 = 84 samples, BPM = 255 (max 8-bit)
    // ---------------------------------------------------------------------------
    // We implement a simple registered divider: divide 21600 by last_interval
    // using a 16-bit iterative divider to avoid synthesis latches.

    localparam [15:0] BPM_NUMERATOR = 16'd21600;   // 360 * 60

    // Constant-time 16-cycle shift-and-subtract divider: BPM = 21600 / interval.
    // div_quo doubles as the shifting dividend — the dividend's MSB shifts out into
    // the remainder while the quotient bit shifts in at the LSB; after 16 steps
    // div_quo holds the quotient. Runtime is exactly 16 cycles for any interval.
    reg  [15:0] div_rem;
    reg  [15:0] div_quo;
    reg  [15:0] div_divisor;
    reg  [3:0]  div_step;
    reg         div_busy;

    // Combinational shift-then-(compare/subtract) for one division step
    wire [15:0] rem_shifted = {div_rem[14:0], div_quo[15]};
    wire        rem_ge      = (rem_shifted >= div_divisor);
    wire [15:0] rem_next    = rem_ge ? (rem_shifted - div_divisor) : rem_shifted;
    wire [15:0] quo_next    = {div_quo[14:0], rem_ge};

    // ---------------------------------------------------------------------------
    // Main FSM
    // ---------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            interval_cnt   <= 16'd0;
            last_interval  <= 16'd0;
            refractory_cnt <= 7'd0;
            in_refractory  <= 1'b0;
            prev_above     <= 1'b0;
            rpeak_detected <= 1'b0;
            bpm_out        <= 8'd0;
            div_rem        <= 16'd0;
            div_quo        <= 16'd0;
            div_divisor    <= 16'd1;
            div_step       <= 4'd0;
            div_busy       <= 1'b0;
        end else begin
            rpeak_detected <= 1'b0;  // default de-assert

            // ------------------------------------------------------------------
            // Per-sample logic
            // ------------------------------------------------------------------
            if (sample_valid) begin
                // Interval counter: saturate at 0xFFFF
                if (interval_cnt != INTERVAL_SATURATE)
                    interval_cnt <= interval_cnt + 1'b1;

                // Refractory countdown
                if (in_refractory) begin
                    if (refractory_cnt == 7'd0)
                        in_refractory <= 1'b0;
                    else
                        refractory_cnt <= refractory_cnt - 1'b1;
                end

                // Edge detection: rising edge above threshold (not in refractory)
                if (!in_refractory) begin
                    if ((ecg_sample > detection_threshold) && !prev_above) begin
                        // R-peak confirmed
                        rpeak_detected <= 1'b1;
                        last_interval  <= interval_cnt;
                        interval_cnt   <= 16'd0;

                        // Enter refractory period
                        refractory_cnt <= REFRACTORY_SAMPLES - 1'b1;
                        in_refractory  <= 1'b1;

                        // Launch constant-time divider (16 cycles) if interval valid
                        if (interval_cnt != 16'd0 && interval_cnt != INTERVAL_SATURATE) begin
                            div_rem     <= 16'd0;
                            div_quo     <= BPM_NUMERATOR;  // dividend; becomes quotient
                            div_divisor <= interval_cnt;
                            div_step    <= 4'd0;
                            div_busy    <= 1'b1;
                        end else begin
                            bpm_out <= 8'd0;
                        end
                    end
                end

                prev_above <= (ecg_sample > detection_threshold);
            end

            // ------------------------------------------------------------------
            // Constant-time 16-cycle shift-and-subtract divider. Exactly 16 cycles
            // for any interval (deterministic), completing far within one 360 Hz
            // sample period. quo_next holds the final quotient on the last step.
            // ------------------------------------------------------------------
            if (div_busy) begin
                div_rem <= rem_next;
                div_quo <= quo_next;
                if (div_step == 4'd15) begin
                    div_busy <= 1'b0;
                    bpm_out  <= (quo_next > 16'd255) ? 8'd255 : quo_next[7:0];
                end else begin
                    div_step <= div_step + 1'b1;
                end
            end

            // Saturated counter means no signal — output BPM = 0
            if (interval_cnt == INTERVAL_SATURATE)
                bpm_out <= 8'd0;
        end
    end

endmodule
