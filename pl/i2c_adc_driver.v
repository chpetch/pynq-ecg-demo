// Module   : i2c_adc_driver
// Project  : PYNQ-Z2 ECG Demo
// Agent    : pynq_ecg_process
// Purpose  : I2C master for PMOD AD2 (AD7991-0), 100 kHz, reads 12-bit ADC sample
//
// Protocol : WRITE config(0x10) with STOP, then separate START + READ 2 bytes.
//            Uses STOP+START (not repeated-start) to match pmod_test.py behaviour.
//
// Bug fixes (this revision):
//  1. WR_ADDR_ACK / WR_CFG_ACK: phase=0 now keeps SCL LOW (tLOW = 1.25 us).
//     Previously scl_r was raised immediately, giving tLOW = 10 ns which
//     prevented the AD7991 from setting up its ACK on SDA.
//  2. Replaced repeated-START chain with proper STOP + START between write
//     and read transactions (STOP_W, STOP_W_SDA, INTER, START2_SDA, START2_SCL).
//  3. STOP_SCL_HI now uses phase logic for correct tLOW before final STOP.

module i2c_adc_driver (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    inout  wire        adc_sda,
    inout  wire        adc_scl,   // open-drain: driven low, released (pull-up) for high
    output reg  [11:0] adc_data,
    output reg         adc_valid
);

    // 100 MHz / 100 kHz = 1000 counts per SCL period; half = 500 → CLK_DIV = 499
    // Slower than 400 kHz to match what Pmod_IIC uses on the proven path —
    // gives the bus more rise-time headroom against board pull-up + cable capacitance.
    localparam CLK_DIV  = 10'd499;
    localparam I2C_ADDR = 7'h28;
    localparam CFG_BYTE = 8'h10;

    localparam IDLE         = 5'd0;
    localparam START_SDA_LO = 5'd1;
    localparam START_SCL_LO = 5'd2;
    localparam WR_ADDR_BIT  = 5'd3;
    localparam WR_ADDR_ACK  = 5'd4;
    localparam WR_CFG_BIT   = 5'd5;
    localparam WR_CFG_ACK   = 5'd6;
    // --- STOP after write, then new START ---
    localparam STOP_W       = 5'd7;   // SCL low→high, SDA stays low
    localparam STOP_W_SDA   = 5'd8;   // SDA rises while SCL high (STOP)
    localparam INTER        = 5'd9;   // bus-free pause (tBUF >= 1.3 us)
    localparam START2_SDA   = 5'd10;  // SDA falls while SCL high (new START)
    localparam START2_SCL   = 5'd11;  // SCL falls, prepare read address
    // --- read phase ---
    localparam RD_ADDR_BIT  = 5'd12;
    localparam RD_ADDR_ACK  = 5'd13;
    localparam RD_BYTE1_BIT = 5'd14;
    localparam RD_BYTE1_ACK = 5'd15;
    localparam RD_BYTE2_BIT = 5'd16;
    localparam RD_NACK      = 5'd17;
    localparam STOP_SCL_HI  = 5'd18;
    localparam STOP_SDA_HI  = 5'd19;
    localparam DONE         = 5'd20;

    // (* mark_debug *) attributes below expose these nets to the ILA inserted by
    // vivado/create_i2c_test.tcl. They are synthesis pragmas only — no behavioral
    // or interface change. Remove if/when the I2C bring-up debug is finished.
    (* mark_debug = "true" *) reg [4:0]  state;
                              reg [9:0]  clk_cnt;
    (* mark_debug = "true" *) reg [2:0]  bit_cnt;
    (* mark_debug = "true" *) reg [7:0]  shift_reg;
    (* mark_debug = "true" *) reg [7:0]  byte1;
    (* mark_debug = "true" *) reg        scl_r;
    (* mark_debug = "true" *) reg        sda_out;
    (* mark_debug = "true" *) reg        sda_oe;
                              reg        phase;

    // ---- Open-drain bus drivers (match the working MicroBlaze IIC path) ----
    // SCL: release (pull-up → high) when scl_r=1, actively drive 0 when scl_r=0.
    // scl_in reads the real pad level so the ILA can confirm SCL toggles cleanly.
    (* mark_debug = "true" *) wire scl_in;
    IOBUF scl_iobuf (
        .IO (adc_scl),
        .O  (scl_in),
        .I  (1'b0),
        .T  (scl_r)          // T=1 release on high, T=0 drive low
    );

    // SDA: drive 0 only when actively transmitting a 0; release otherwise (when
    // sending a 1, or reading) so the slave can pull it low for ACK / data.
    (* mark_debug = "true" *) wire sda_in;
    wire sda_drive_low = sda_oe & ~sda_out;
    IOBUF sda_iobuf (
        .IO (adc_sda),
        .O  (sda_in),
        .I  (1'b0),
        .T  (~sda_drive_low) // T=0 drive low only when sda_drive_low, else release
    );

    wire half_tick = (clk_cnt == CLK_DIV);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= IDLE;
            clk_cnt  <=  10'd0;
            bit_cnt  <= 3'd7;
            shift_reg<= 8'd0;
            byte1    <= 8'd0;
            scl_r    <= 1'b1;
            sda_out  <= 1'b1;
            sda_oe   <= 1'b0;
            phase    <= 1'b0;
            adc_data <= 12'd0;
            adc_valid<= 1'b0;
        end else begin
            adc_valid <= 1'b0;

            case (state)

                IDLE: begin
                    scl_r   <= 1'b1;
                    sda_out <= 1'b1;
                    sda_oe  <= 1'b1;
                    clk_cnt <= 10'd0;
                    bit_cnt <= 3'd7;
                    if (start)
                        state <= START_SDA_LO;
                end

                // START: SDA falls while SCL high
                START_SDA_LO: begin
                    sda_out <= 1'b0;
                    sda_oe  <= 1'b1;
                    if (half_tick) begin
                        clk_cnt <= 10'd0;
                        state   <= START_SCL_LO;
                    end else
                        clk_cnt <= clk_cnt + 1'b1;
                end

                START_SCL_LO: begin
                    scl_r <= 1'b0;
                    if (half_tick) begin
                        clk_cnt  <=  10'd0;
                        shift_reg<= {I2C_ADDR, 1'b0};
                        bit_cnt  <= 3'd7;
                        state    <= WR_ADDR_BIT;
                    end else
                        clk_cnt <= clk_cnt + 1'b1;
                end

                // Write address + W
                WR_ADDR_BIT: begin
                    if (!phase) begin
                        sda_out <= shift_reg[7];
                        sda_oe  <= 1'b1;
                        scl_r   <= 1'b0;
                        if (half_tick) begin
                            clk_cnt <= 10'd0;
                            scl_r   <= 1'b1;
                            phase   <= 1'b1;
                        end else
                            clk_cnt <= clk_cnt + 1'b1;
                    end else begin
                        if (half_tick) begin
                            clk_cnt  <=  10'd0;
                            scl_r    <= 1'b0;
                            phase    <= 1'b0;
                            shift_reg<= {shift_reg[6:0], 1'b0};
                            if (bit_cnt == 3'd0)
                                state   <= WR_ADDR_ACK;
                            else
                                bit_cnt <= bit_cnt - 1'b1;
                        end else
                            clk_cnt <= clk_cnt + 1'b1;
                    end
                end

                // FIX: phase=0 keeps SCL LOW for tLOW = 1.25 us
                WR_ADDR_ACK: begin
                    sda_oe <= 1'b0;
                    if (!phase) begin
                        scl_r <= 1'b0;          // keep SCL low
                        if (half_tick) begin
                            clk_cnt <= 10'd0;
                            scl_r   <= 1'b1;    // raise SCL at end of low half
                            phase   <= 1'b1;
                        end else
                            clk_cnt <= clk_cnt + 1'b1;
                    end else begin
                        if (half_tick) begin
                            clk_cnt  <=  10'd0;
                            scl_r    <= 1'b0;
                            phase    <= 1'b0;
                            shift_reg<= CFG_BYTE;
                            bit_cnt  <= 3'd7;
                            state    <= WR_CFG_BIT;
                        end else
                            clk_cnt <= clk_cnt + 1'b1;
                    end
                end

                // Write config byte 0x10
                WR_CFG_BIT: begin
                    if (!phase) begin
                        sda_out <= shift_reg[7];
                        sda_oe  <= 1'b1;
                        scl_r   <= 1'b0;
                        if (half_tick) begin
                            clk_cnt <= 10'd0;
                            scl_r   <= 1'b1;
                            phase   <= 1'b1;
                        end else
                            clk_cnt <= clk_cnt + 1'b1;
                    end else begin
                        if (half_tick) begin
                            clk_cnt  <=  10'd0;
                            scl_r    <= 1'b0;
                            phase    <= 1'b0;
                            shift_reg<= {shift_reg[6:0], 1'b0};
                            if (bit_cnt == 3'd0)
                                state   <= WR_CFG_ACK;
                            else
                                bit_cnt <= bit_cnt - 1'b1;
                        end else
                            clk_cnt <= clk_cnt + 1'b1;
                    end
                end

                // FIX: phase=0 keeps SCL LOW; next state is STOP_W (not repeated-start)
                WR_CFG_ACK: begin
                    sda_oe <= 1'b0;
                    if (!phase) begin
                        scl_r <= 1'b0;          // keep SCL low
                        if (half_tick) begin
                            clk_cnt <= 10'd0;
                            scl_r   <= 1'b1;
                            phase   <= 1'b1;
                        end else
                            clk_cnt <= clk_cnt + 1'b1;
                    end else begin
                        if (half_tick) begin
                            clk_cnt <= 10'd0;
                            scl_r   <= 1'b0;
                            phase   <= 1'b0;
                            state   <= STOP_W;
                        end else
                            clk_cnt <= clk_cnt + 1'b1;
                    end
                end

                // STOP after write: SCL low→high with SDA low
                STOP_W: begin
                    sda_out <= 1'b0;
                    sda_oe  <= 1'b1;
                    if (!phase) begin
                        scl_r <= 1'b0;
                        if (half_tick) begin
                            clk_cnt <= 10'd0;
                            scl_r   <= 1'b1;
                            phase   <= 1'b1;
                        end else
                            clk_cnt <= clk_cnt + 1'b1;
                    end else begin
                        if (half_tick) begin
                            clk_cnt <= 10'd0;
                            phase   <= 1'b0;
                            state   <= STOP_W_SDA;
                        end else
                            clk_cnt <= clk_cnt + 1'b1;
                    end
                end

                // STOP: SDA rises while SCL stays high
                STOP_W_SDA: begin
                    sda_out <= 1'b1;
                    sda_oe  <= 1'b1;
                    if (half_tick) begin
                        clk_cnt <= 10'd0;
                        state   <= INTER;
                    end else
                        clk_cnt <= clk_cnt + 1'b1;
                end

                // Bus free time: both high, wait >= tBUF (1.3 us).
                // Two half-periods = 2.5 us to be safe.
                INTER: begin
                    sda_out <= 1'b1;
                    sda_oe  <= 1'b1;
                    scl_r   <= 1'b1;
                    if (clk_cnt == 10'd999) begin
                        clk_cnt <= 10'd0;
                        state   <= START2_SDA;
                    end else
                        clk_cnt <= clk_cnt + 1'b1;
                end

                // New START for read: SDA falls while SCL high
                START2_SDA: begin
                    scl_r   <= 1'b1;
                    sda_out <= 1'b0;
                    sda_oe  <= 1'b1;
                    if (half_tick) begin
                        clk_cnt <= 10'd0;
                        state   <= START2_SCL;
                    end else
                        clk_cnt <= clk_cnt + 1'b1;
                end

                // SCL falls after new START
                START2_SCL: begin
                    scl_r <= 1'b0;
                    if (half_tick) begin
                        clk_cnt  <=  10'd0;
                        shift_reg<= {I2C_ADDR, 1'b1};  // READ bit
                        bit_cnt  <= 3'd7;
                        state    <= RD_ADDR_BIT;
                    end else
                        clk_cnt <= clk_cnt + 1'b1;
                end

                // Write address + R
                RD_ADDR_BIT: begin
                    if (!phase) begin
                        sda_out <= shift_reg[7];
                        sda_oe  <= 1'b1;
                        scl_r   <= 1'b0;
                        if (half_tick) begin
                            clk_cnt <= 10'd0;
                            scl_r   <= 1'b1;
                            phase   <= 1'b1;
                        end else
                            clk_cnt <= clk_cnt + 1'b1;
                    end else begin
                        if (half_tick) begin
                            clk_cnt  <=  10'd0;
                            scl_r    <= 1'b0;
                            phase    <= 1'b0;
                            shift_reg<= {shift_reg[6:0], 1'b0};
                            if (bit_cnt == 3'd0)
                                state   <= RD_ADDR_ACK;
                            else
                                bit_cnt <= bit_cnt - 1'b1;
                        end else
                            clk_cnt <= clk_cnt + 1'b1;
                    end
                end

                RD_ADDR_ACK: begin
                    sda_oe <= 1'b0;
                    if (!phase) begin
                        scl_r <= 1'b0;
                        if (half_tick) begin
                            clk_cnt <= 10'd0;
                            scl_r   <= 1'b1;
                            phase   <= 1'b1;
                        end else
                            clk_cnt <= clk_cnt + 1'b1;
                    end else begin
                        if (half_tick) begin
                            clk_cnt <= 10'd0;
                            scl_r   <= 1'b0;
                            phase   <= 1'b0;
                            bit_cnt <= 3'd7;
                            state   <= RD_BYTE1_BIT;
                        end else
                            clk_cnt <= clk_cnt + 1'b1;
                    end
                end

                // Read byte 1: [7:4]=channel tag, [3:0]=data[11:8]
                RD_BYTE1_BIT: begin
                    sda_oe <= 1'b0;
                    if (!phase) begin
                        scl_r <= 1'b0;
                        if (half_tick) begin
                            clk_cnt <= 10'd0;
                            scl_r   <= 1'b1;
                            phase   <= 1'b1;
                        end else
                            clk_cnt <= clk_cnt + 1'b1;
                    end else begin
                        if (half_tick) begin
                            clk_cnt <= 10'd0;
                            scl_r   <= 1'b0;
                            phase   <= 1'b0;
                            if (bit_cnt == 3'd0) begin
                                byte1   <= {shift_reg[6:0], sda_in};
                                sda_out <= 1'b0;
                                sda_oe  <= 1'b1;
                                bit_cnt <= 3'd7;
                                state   <= RD_BYTE1_ACK;
                            end else begin
                                shift_reg <= {shift_reg[6:0], sda_in};
                                bit_cnt   <= bit_cnt - 1'b1;
                            end
                        end else
                            clk_cnt <= clk_cnt + 1'b1;
                    end
                end

                // Master ACK after byte 1 (SDA=0)
                RD_BYTE1_ACK: begin
                    sda_out <= 1'b0;
                    sda_oe  <= 1'b1;
                    if (!phase) begin
                        scl_r <= 1'b0;
                        if (half_tick) begin
                            clk_cnt <= 10'd0;
                            scl_r   <= 1'b1;
                            phase   <= 1'b1;
                        end else
                            clk_cnt <= clk_cnt + 1'b1;
                    end else begin
                        if (half_tick) begin
                            clk_cnt  <=  10'd0;
                            scl_r    <= 1'b0;
                            sda_oe   <= 1'b0;
                            phase    <= 1'b0;
                            shift_reg<= 8'd0;
                            state    <= RD_BYTE2_BIT;
                        end else
                            clk_cnt <= clk_cnt + 1'b1;
                    end
                end

                // Read byte 2: data[7:0]
                RD_BYTE2_BIT: begin
                    sda_oe <= 1'b0;
                    if (!phase) begin
                        scl_r <= 1'b0;
                        if (half_tick) begin
                            clk_cnt <= 10'd0;
                            scl_r   <= 1'b1;
                            phase   <= 1'b1;
                        end else
                            clk_cnt <= clk_cnt + 1'b1;
                    end else begin
                        if (half_tick) begin
                            clk_cnt <= 10'd0;
                            scl_r   <= 1'b0;
                            phase   <= 1'b0;
                            if (bit_cnt == 3'd0) begin
                                adc_data <= {byte1[3:0], {shift_reg[6:0], sda_in}};
                                state    <= RD_NACK;
                            end else begin
                                shift_reg <= {shift_reg[6:0], sda_in};
                                bit_cnt   <= bit_cnt - 1'b1;
                            end
                        end else
                            clk_cnt <= clk_cnt + 1'b1;
                    end
                end

                // Master NACK after byte 2 (SDA=1)
                RD_NACK: begin
                    sda_out <= 1'b1;
                    sda_oe  <= 1'b1;
                    if (!phase) begin
                        scl_r <= 1'b0;
                        if (half_tick) begin
                            clk_cnt <= 10'd0;
                            scl_r   <= 1'b1;
                            phase   <= 1'b1;
                        end else
                            clk_cnt <= clk_cnt + 1'b1;
                    end else begin
                        if (half_tick) begin
                            clk_cnt <= 10'd0;
                            scl_r   <= 1'b0;
                            phase   <= 1'b0;
                            state   <= STOP_SCL_HI;
                        end else
                            clk_cnt <= clk_cnt + 1'b1;
                    end
                end

                // STOP: SCL low→high, SDA stays low (FIX: proper tLOW via phase)
                STOP_SCL_HI: begin
                    sda_out <= 1'b0;
                    sda_oe  <= 1'b1;
                    if (!phase) begin
                        scl_r <= 1'b0;
                        if (half_tick) begin
                            clk_cnt <= 10'd0;
                            scl_r   <= 1'b1;
                            phase   <= 1'b1;
                        end else
                            clk_cnt <= clk_cnt + 1'b1;
                    end else begin
                        if (half_tick) begin
                            clk_cnt <= 10'd0;
                            phase   <= 1'b0;
                            state   <= STOP_SDA_HI;
                        end else
                            clk_cnt <= clk_cnt + 1'b1;
                    end
                end

                // STOP: SDA rises while SCL stays high
                STOP_SDA_HI: begin
                    sda_out <= 1'b1;
                    if (half_tick) begin
                        clk_cnt   <=  10'd0;
                        adc_valid <= 1'b1;
                        state     <= DONE;
                    end else
                        clk_cnt <= clk_cnt + 1'b1;
                end

                DONE: begin
                    sda_oe  <= 1'b0;
                    scl_r   <= 1'b1;
                    state   <= IDLE;
                end

                default: state <= IDLE;

            endcase
        end
    end

endmodule
