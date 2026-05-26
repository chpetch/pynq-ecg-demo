// Module   : fir_filter
// Project  : PYNQ-Z2 ECG Demo
// Agent    : pynq_ecg_process
// Purpose  : 31-tap FIR bandpass filter, Q1.15 coefficients from handoffs/algorithm_spec.md

// Coefficients source : handoffs/algorithm_spec.md, validated by algo/validate_algorithm.py
// Filter spec         : 31 taps, 0.5-40.0 Hz bandpass, Hamming window, 360 Hz sample rate
// Latency             : 15 clock cycles (linear phase delay = (31-1)/2) — per algorithm_spec.md
// Data path           : 12-bit unsigned input -> 32-bit signed accumulator
//                       Output = accumulator >> 15, bits [11:0] — per algorithm_spec.md

module fir_filter (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [11:0] data_in,
    input  wire        data_valid,
    output reg  [11:0] data_out,
    output reg         data_valid_out
);

    // ---------------------------------------------------------------------------
    // Coefficient table — Q1.15 signed integers from algorithm_spec.md exactly
    // Negative values expressed as 2's complement 16-bit signed literals.
    // h[0]..h[30], symmetric linear-phase FIR
    // ---------------------------------------------------------------------------
    //  h[ 0] =    -56   -> -56  = 16'hFFC8
    //  h[ 1] =    -31   -> -31  = 16'hFFE1
    //  h[ 2] =     22
    //  h[ 3] =    112
    //  h[ 4] =    197
    //  h[ 5] =    180
    //  h[ 6] =    -36   -> -36  = 16'hFFDC
    //  h[ 7] =   -459   -> -459 = 16'hFE35
    //  h[ 8] =   -921   -> -921 = 16'hFC67
    //  h[ 9] =  -1094   ->-1094 = 16'hFBBA
    //  h[10] =   -622   -> -622 = 16'hFD92
    //  h[11] =    682
    //  h[12] =   2676
    //  h[13] =   4867
    //  h[14] =   6577
    //  h[15] =   7224
    //  h[16] =   6577
    //  h[17] =   4867
    //  h[18] =   2676
    //  h[19] =    682
    //  h[20] =   -622
    //  h[21] =  -1094
    //  h[22] =   -921
    //  h[23] =   -459
    //  h[24] =    -36
    //  h[25] =    180
    //  h[26] =    197
    //  h[27] =    112
    //  h[28] =     22
    //  h[29] =    -31
    //  h[30] =    -56

    localparam signed [15:0] H00 = -16'sd56;
    localparam signed [15:0] H01 = -16'sd31;
    localparam signed [15:0] H02 =  16'sd22;
    localparam signed [15:0] H03 =  16'sd112;
    localparam signed [15:0] H04 =  16'sd197;
    localparam signed [15:0] H05 =  16'sd180;
    localparam signed [15:0] H06 = -16'sd36;
    localparam signed [15:0] H07 = -16'sd459;
    localparam signed [15:0] H08 = -16'sd921;
    localparam signed [15:0] H09 = -16'sd1094;
    localparam signed [15:0] H10 = -16'sd622;
    localparam signed [15:0] H11 =  16'sd682;
    localparam signed [15:0] H12 =  16'sd2676;
    localparam signed [15:0] H13 =  16'sd4867;
    localparam signed [15:0] H14 =  16'sd6577;
    localparam signed [15:0] H15 =  16'sd7224;
    localparam signed [15:0] H16 =  16'sd6577;
    localparam signed [15:0] H17 =  16'sd4867;
    localparam signed [15:0] H18 =  16'sd2676;
    localparam signed [15:0] H19 =  16'sd682;
    localparam signed [15:0] H20 = -16'sd622;
    localparam signed [15:0] H21 = -16'sd1094;
    localparam signed [15:0] H22 = -16'sd921;
    localparam signed [15:0] H23 = -16'sd459;
    localparam signed [15:0] H24 = -16'sd36;
    localparam signed [15:0] H25 =  16'sd180;
    localparam signed [15:0] H26 =  16'sd197;
    localparam signed [15:0] H27 =  16'sd112;
    localparam signed [15:0] H28 =  16'sd22;
    localparam signed [15:0] H29 = -16'sd31;
    localparam signed [15:0] H30 = -16'sd56;

    // ---------------------------------------------------------------------------
    // Shift register (sample delay line) — 31 entries, 12-bit unsigned
    // ---------------------------------------------------------------------------
    reg [11:0] delay [0:30];
    integer i;

    // ---------------------------------------------------------------------------
    // Multiply-accumulate: 32-bit signed accumulator
    // Product: 12-bit unsigned sample sign-extended to 32 bits,
    //          multiplied by 16-bit signed Q1.15 coefficient
    // ---------------------------------------------------------------------------
    reg signed [31:0] acc;

    // valid pipeline: shift by 1 to match the registered output stage
    reg valid_pipe;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < 31; i = i + 1)
                delay[i] <= 12'd0;
            acc            <= 32'sd0;
            data_out       <= 12'd0;
            data_valid_out <= 1'b0;
            valid_pipe     <= 1'b0;
        end else begin
            valid_pipe     <= data_valid;
            data_valid_out <= valid_pipe;

            if (data_valid) begin
                // Shift the delay line
                delay[0] <= data_in;
                for (i = 1; i < 31; i = i + 1)
                    delay[i] <= delay[i-1];

                // Multiply-accumulate: sum all 31 taps
                // $signed({1'b0, x}) zero-extends 12-bit unsigned to signed 13-bit,
                // then Verilog sign-extends operands to the full 32-bit accumulator width.
                acc <=
                    ($signed({1'b0, data_in})    * H00) +
                    ($signed({1'b0, delay[ 0]})  * H01) +
                    ($signed({1'b0, delay[ 1]})  * H02) +
                    ($signed({1'b0, delay[ 2]})  * H03) +
                    ($signed({1'b0, delay[ 3]})  * H04) +
                    ($signed({1'b0, delay[ 4]})  * H05) +
                    ($signed({1'b0, delay[ 5]})  * H06) +
                    ($signed({1'b0, delay[ 6]})  * H07) +
                    ($signed({1'b0, delay[ 7]})  * H08) +
                    ($signed({1'b0, delay[ 8]})  * H09) +
                    ($signed({1'b0, delay[ 9]})  * H10) +
                    ($signed({1'b0, delay[10]})  * H11) +
                    ($signed({1'b0, delay[11]})  * H12) +
                    ($signed({1'b0, delay[12]})  * H13) +
                    ($signed({1'b0, delay[13]})  * H14) +
                    ($signed({1'b0, delay[14]})  * H15) +
                    ($signed({1'b0, delay[15]})  * H16) +
                    ($signed({1'b0, delay[16]})  * H17) +
                    ($signed({1'b0, delay[17]})  * H18) +
                    ($signed({1'b0, delay[18]})  * H19) +
                    ($signed({1'b0, delay[19]})  * H20) +
                    ($signed({1'b0, delay[20]})  * H21) +
                    ($signed({1'b0, delay[21]})  * H22) +
                    ($signed({1'b0, delay[22]})  * H23) +
                    ($signed({1'b0, delay[23]})  * H24) +
                    ($signed({1'b0, delay[24]})  * H25) +
                    ($signed({1'b0, delay[25]})  * H26) +
                    ($signed({1'b0, delay[26]})  * H27) +
                    ($signed({1'b0, delay[27]})  * H28) +
                    ($signed({1'b0, delay[28]})  * H29) +
                    ($signed({1'b0, delay[29]})  * H30);

                // Truncation: accumulator >> 15, keep bits [11:0] — per algorithm_spec.md
                // acc[26:15] = (acc >> 15)[11:0]
                data_out <= acc[26:15];
            end
        end
    end

endmodule
