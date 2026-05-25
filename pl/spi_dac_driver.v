// Module   : spi_dac_driver
// Project  : PYNQ-Z2 ECG Demo
// Agent    : pynq_ecg_gen
// Purpose  : SPI master for PMOD DA4 (AD5628-1), writes all 8 channels

// AD5628-1 SPI requirements:
//   - SPI Mode 2: CPOL=1, CPHA=0 — SCLK idles HIGH, data captured on falling edge
//   - 24-bit word per channel: [23:20]=CMD(0011), [19:16]=ADDR, [15:4]=DATA, [3:0]=DC
//   - CS_N stays LOW across all 8 consecutive 24-bit frames
//
// SPI clock = 100 MHz / 4 = 25 MHz (toggle every 2 system clocks)

`timescale 1ns / 1ps

module spi_dac_driver (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [11:0] sample_data_0,  // Ch A (loopback)
    input  wire [11:0] sample_data_1,  // Ch B
    input  wire [11:0] sample_data_2,  // Ch C
    input  wire [11:0] sample_data_3,  // Ch D
    input  wire [11:0] sample_data_4,  // Ch E
    input  wire [11:0] sample_data_5,  // Ch F
    input  wire [11:0] sample_data_6,  // Ch G
    input  wire [11:0] sample_data_7,  // Ch H
    input  wire        sample_valid,
    output reg         dac_cs_n,
    output reg         dac_sclk,
    output reg         dac_din,
    output wire        busy
);

    // -----------------------------------------------------------------------
    // Constants
    // -----------------------------------------------------------------------
    localparam CMD_WRITE_UPDATE = 4'b0011;  // AD5628 "write and update" command
    localparam BITS_PER_FRAME   = 24;
    localparam NUM_CHANNELS     = 8;
    localparam TOTAL_BITS       = BITS_PER_FRAME * NUM_CHANNELS;  // 192

    // SPI clock divider: toggle every 2 clocks => 25 MHz
    localparam CLK_DIV          = 2;

    // -----------------------------------------------------------------------
    // State machine
    // -----------------------------------------------------------------------
    localparam ST_IDLE     = 2'd0;
    localparam ST_LOAD     = 2'd1;   // load next channel word into shift register
    localparam ST_SHIFT    = 2'd2;   // clock out 24 bits
    localparam ST_DONE     = 2'd3;   // deassert CS_N

    reg [1:0]  state;
    reg [1:0]  clk_div_cnt;    // 0..1, toggles SCLK
    reg [4:0]  bit_cnt;        // 0..23, bit position within current frame
    reg [2:0]  ch_cnt;         // 0..7, current DAC channel
    reg [23:0] shift_reg;      // current 24-bit word being shifted out
    reg        sclk_phase;     // current SCLK state (1=idle)

    // Latch all 8 channels when sample_valid is detected
    reg [11:0] ch_latch [0:7];

    assign busy = (state != ST_IDLE);

    // Combinational word for current ch_cnt/ch_latch — avoids bit-select on function call
    wire [23:0] load_word;
    assign load_word = build_word(ch_cnt, ch_latch[ch_cnt]);

    // -----------------------------------------------------------------------
    // Build the 24-bit word for a given channel and data
    // -----------------------------------------------------------------------
    function [23:0] build_word;
        input [2:0]  channel;
        input [11:0] data;
        begin
            build_word = {CMD_WRITE_UPDATE, channel[2:0], 1'b0, data, 4'b0000};
        end
    endfunction

    // -----------------------------------------------------------------------
    // Main state machine
    // -----------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= ST_IDLE;
            dac_cs_n    <= 1'b1;
            dac_sclk    <= 1'b1;   // CPOL=1: idle HIGH
            dac_din     <= 1'b0;
            clk_div_cnt <= 2'd0;
            bit_cnt     <= 5'd0;
            ch_cnt      <= 3'd0;
            shift_reg   <= 24'd0;
            sclk_phase  <= 1'b1;
            // Initialise latches
            ch_latch[0] <= 12'd0;
            ch_latch[1] <= 12'd0;
            ch_latch[2] <= 12'd0;
            ch_latch[3] <= 12'd0;
            ch_latch[4] <= 12'd0;
            ch_latch[5] <= 12'd0;
            ch_latch[6] <= 12'd0;
            ch_latch[7] <= 12'd0;
        end else begin
            case (state)

                // -------------------------------------------------------------
                ST_IDLE: begin
                    dac_cs_n    <= 1'b1;
                    dac_sclk    <= 1'b1;   // keep SCLK high when idle
                    dac_din     <= 1'b0;
                    clk_div_cnt <= 2'd0;
                    sclk_phase  <= 1'b1;

                    if (sample_valid) begin
                        // Latch all channel data
                        ch_latch[0] <= sample_data_0;
                        ch_latch[1] <= sample_data_1;
                        ch_latch[2] <= sample_data_2;
                        ch_latch[3] <= sample_data_3;
                        ch_latch[4] <= sample_data_4;
                        ch_latch[5] <= sample_data_5;
                        ch_latch[6] <= sample_data_6;
                        ch_latch[7] <= sample_data_7;
                        ch_cnt      <= 3'd0;
                        state       <= ST_LOAD;
                    end
                end

                // -------------------------------------------------------------
                // Load first/next channel word into shift register and assert CS_N
                // -------------------------------------------------------------
                ST_LOAD: begin
                    dac_cs_n    <= 1'b0;                    // assert CS_N
                    shift_reg   <= load_word;
                    bit_cnt     <= 5'd0;
                    clk_div_cnt <= 2'd0;
                    sclk_phase  <= 1'b1;                    // SCLK starts HIGH
                    dac_sclk    <= 1'b1;
                    // Present MSB on DIN before first falling edge
                    dac_din     <= load_word[23];
                    state       <= ST_SHIFT;
                end

                // -------------------------------------------------------------
                // Clock out 24 bits: Mode 2 (CPOL=1, CPHA=0)
                //   Data is presented on DIN when SCLK is HIGH,
                //   AD5628 samples on the FALLING edge.
                //   Sequence per bit:
                //     1) SCLK falls  (clk_div_cnt wraps from 1 to 0, sclk_phase goes 0)
                //     2) SCLK rises  (clk_div_cnt wraps, sclk_phase goes 1)
                //        → advance bit, present next DIN bit
                // -------------------------------------------------------------
                ST_SHIFT: begin
                    if (clk_div_cnt == CLK_DIV - 1) begin
                        clk_div_cnt <= 2'd0;
                        sclk_phase  <= ~sclk_phase;
                        dac_sclk    <= ~sclk_phase;  // will be new value

                        if (sclk_phase == 1'b1) begin
                            // Falling edge — AD5628 captures current DIN
                            // (no action needed here; DIN was set on previous rising)
                        end else begin
                            // Rising edge — advance to next bit
                            if (bit_cnt == 5'd23) begin
                                // Frame complete
                                if (ch_cnt == 3'd7) begin
                                    // All 8 channels done
                                    state <= ST_DONE;
                                end else begin
                                    ch_cnt <= ch_cnt + 3'd1;
                                    state  <= ST_LOAD;
                                end
                            end else begin
                                bit_cnt <= bit_cnt + 5'd1;
                                // Present next bit: MSB first
                                dac_din <= shift_reg[23 - (bit_cnt + 5'd1)];
                            end
                        end
                    end else begin
                        clk_div_cnt <= clk_div_cnt + 2'd1;
                    end
                end

                // -------------------------------------------------------------
                ST_DONE: begin
                    dac_cs_n <= 1'b1;    // deassert CS_N
                    dac_sclk <= 1'b1;    // return SCLK to idle-HIGH
                    dac_din  <= 1'b0;
                    state    <= ST_IDLE;
                end

                default: state <= ST_IDLE;

            endcase
        end
    end

endmodule
