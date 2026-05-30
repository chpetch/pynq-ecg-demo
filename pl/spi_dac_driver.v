// Module   : spi_dac_driver
// Project  : PYNQ-Z2 ECG Demo
// Agent    : pynq_ecg_gen
// Purpose  : SPI master for PMOD DA4 (AD5628-1), writes all 8 channels
//
// AD5628-1 SPI requirements (matches the proven ps/pmod_test.py path):
//   - SPI Mode 2: CPOL=1, CPHA=0 — SCLK idles HIGH, data captured on FALLING edge
//   - 32-bit word per write: [31:28]=DC, [27:24]=CMD, [23:20]=ADDR(=channel),
//     [19:8]=DATA(12-bit), [7:0]=DC.   (NOT 24-bit — the chip needs 32 clocks.)
//   - SYNC (CS_N) is pulsed HIGH after EACH 32-bit word to latch it (one word
//     per SYNC frame; CS does NOT stay low across multiple channels).
//   - The AD5628-1 internal 2.5 V reference is DISABLED at power-up. It MUST be
//     enabled once (CMD 1000, feature bit0=1 => word 0x08000001) before any
//     channel write, or every VOUT stays at 0 V.
//
// SPI clock = 100 MHz / 4 = 25 MHz (toggle every 2 system clocks)

`timescale 1ns / 1ps

module spi_dac_driver (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [11:0] sample_data_0,  // Ch A (loopback -> AD2 CH0)
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
    localparam [3:0]  CMD_WRITE_UPDATE = 4'b0011;  // write-and-update DAC channel
    localparam        BITS_PER_FRAME   = 32;
    localparam        CLK_DIV          = 2;        // toggle SCLK every 2 clks => 25 MHz
    localparam        SYNC_HIGH_CYCLES = 8;        // SYNC-high dwell between words (~80 ns)

    // AD5628 internal-reference setup: CMD 1000, feature bit0 = 1 => enable.
    localparam [31:0] REF_ENABLE_WORD  = 32'h0800_0001;

    // -----------------------------------------------------------------------
    // State machine
    // -----------------------------------------------------------------------
    localparam ST_IDLE    = 3'd0;
    localparam ST_LOAD    = 3'd1;   // SYNC low, load next 32-bit word
    localparam ST_SHIFT   = 3'd2;   // clock out 32 bits
    localparam ST_SYNC_HI = 3'd3;   // SYNC high to latch the word, dwell
    localparam ST_NEXT    = 3'd4;   // advance to next channel / finish

    reg [2:0]  state;
    reg [1:0]  clk_div_cnt;
    reg [4:0]  bit_cnt;        // 0..31
    reg [2:0]  ch_cnt;         // 0..7
    reg [31:0] shift_reg;
    reg        sclk_phase;     // current SCLK level (1 = idle high)
    reg [2:0]  sync_cnt;       // SYNC-high dwell counter
    reg        ref_done;       // internal-reference enable already sent
    reg        sending_ref;    // current frame is the ref-enable word

    reg [11:0] ch_latch [0:7];

    assign busy = (state != ST_IDLE);

    // -----------------------------------------------------------------------
    // Build the 32-bit AD5628 write-and-update word for a channel
    // -----------------------------------------------------------------------
    function [31:0] build_word;
        input [2:0]  channel;
        input [11:0] data;
        begin
            // [31:28]=0 [27:24]=cmd [23:20]={0,channel} [19:8]=data [7:0]=0
            build_word = {4'b0000, CMD_WRITE_UPDATE, 1'b0, channel, data, 8'b0000_0000};
        end
    endfunction

    // Word for the current frame: ref-enable, else the current channel
    wire [31:0] next_word = sending_ref ? REF_ENABLE_WORD
                                        : build_word(ch_cnt, ch_latch[ch_cnt]);

    // -----------------------------------------------------------------------
    // Main state machine
    // -----------------------------------------------------------------------
    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= ST_IDLE;
            dac_cs_n    <= 1'b1;
            dac_sclk    <= 1'b1;   // CPOL=1: idle HIGH
            dac_din     <= 1'b0;
            clk_div_cnt <= 2'd0;
            bit_cnt     <= 5'd0;
            ch_cnt      <= 3'd0;
            shift_reg   <= 32'd0;
            sclk_phase  <= 1'b1;
            sync_cnt    <= 3'd0;
            ref_done    <= 1'b0;
            sending_ref <= 1'b0;
            for (i = 0; i < 8; i = i + 1)
                ch_latch[i] <= 12'd0;
        end else begin
            case (state)

                // -------------------------------------------------------------
                ST_IDLE: begin
                    dac_cs_n    <= 1'b1;
                    dac_sclk    <= 1'b1;
                    dac_din     <= 1'b0;
                    clk_div_cnt <= 2'd0;
                    sclk_phase  <= 1'b1;
                    sync_cnt    <= 3'd0;

                    if (sample_valid) begin
                        ch_latch[0] <= sample_data_0;
                        ch_latch[1] <= sample_data_1;
                        ch_latch[2] <= sample_data_2;
                        ch_latch[3] <= sample_data_3;
                        ch_latch[4] <= sample_data_4;
                        ch_latch[5] <= sample_data_5;
                        ch_latch[6] <= sample_data_6;
                        ch_latch[7] <= sample_data_7;
                        // The very first transfer also enables the internal reference
                        // (one leading 0x08000001 frame), then the 8 channel writes.
                        sending_ref <= ~ref_done;
                        ch_cnt      <= 3'd0;
                        state       <= ST_LOAD;
                    end
                end

                // -------------------------------------------------------------
                // SYNC low, present MSB of the 32-bit word before first falling edge
                // -------------------------------------------------------------
                ST_LOAD: begin
                    dac_cs_n    <= 1'b0;            // SYNC low
                    shift_reg   <= next_word;
                    dac_din     <= next_word[31];   // MSB first
                    bit_cnt     <= 5'd0;
                    clk_div_cnt <= 2'd0;
                    sclk_phase  <= 1'b1;
                    dac_sclk    <= 1'b1;
                    state       <= ST_SHIFT;
                end

                // -------------------------------------------------------------
                // Clock out 32 bits, Mode 2 (CPOL=1, CPHA=0):
                //   data presented while SCLK HIGH, AD5628 samples on FALLING edge
                // -------------------------------------------------------------
                ST_SHIFT: begin
                    if (clk_div_cnt == CLK_DIV - 1) begin
                        clk_div_cnt <= 2'd0;
                        sclk_phase  <= ~sclk_phase;
                        dac_sclk    <= ~sclk_phase;
                        if (sclk_phase == 1'b1) begin
                            // Falling edge — AD5628 captures current DIN (no action)
                        end else begin
                            // Rising edge — advance to the next bit
                            if (bit_cnt == 5'd31) begin
                                state <= ST_SYNC_HI;   // all 32 bits clocked
                            end else begin
                                bit_cnt <= bit_cnt + 5'd1;
                                dac_din <= shift_reg[31 - (bit_cnt + 5'd1)];
                            end
                        end
                    end else begin
                        clk_div_cnt <= clk_div_cnt + 2'd1;
                    end
                end

                // -------------------------------------------------------------
                // SYNC high latches the 32-bit word; dwell for tSYNC-high
                // -------------------------------------------------------------
                ST_SYNC_HI: begin
                    dac_cs_n <= 1'b1;   // SYNC high -> the addressed DAC updates
                    dac_sclk <= 1'b1;
                    dac_din  <= 1'b0;
                    if (sync_cnt == SYNC_HIGH_CYCLES - 1) begin
                        sync_cnt <= 3'd0;
                        state    <= ST_NEXT;
                    end else begin
                        sync_cnt <= sync_cnt + 3'd1;
                    end
                end

                // -------------------------------------------------------------
                ST_NEXT: begin
                    if (sending_ref) begin
                        ref_done    <= 1'b1;   // reference enabled; channels next
                        sending_ref <= 1'b0;
                        state       <= ST_LOAD;  // continue into ch A..H this transfer
                    end else if (ch_cnt == 3'd7) begin
                        state <= ST_IDLE;      // all 8 channels written
                    end else begin
                        ch_cnt <= ch_cnt + 3'd1;
                        state  <= ST_LOAD;     // next channel (new SYNC frame)
                    end
                end

                default: state <= ST_IDLE;

            endcase
        end
    end

endmodule
