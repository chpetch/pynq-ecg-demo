// Module   : i2c_adc_driver
// Project  : PYNQ-Z2 ECG Demo
// Agent    : pynq_ecg_process
// Purpose  : I2C master for PMOD AD2 (AD7991-0), 400 kHz, reads 12-bit ADC sample

module i2c_adc_driver (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,       // pulse from ecg_dds sample_valid
    inout  wire        adc_sda,
    output wire        adc_scl,
    output reg  [11:0] adc_data,
    output reg         adc_valid    // pulses HIGH 1 cycle when data ready
);

    // ---------------------------------------------------------------------------
    // Parameters
    // ---------------------------------------------------------------------------
    // 100 MHz / 400 kHz = 250 counts per SCL period
    // Half-period = 125 counts
    localparam CLK_DIV    = 8'd124;   // counts to half-period (0-based, so 125 ticks)
    localparam I2C_ADDR   = 7'h28;    // AD7991-0 with ADDR pin low
    localparam CFG_BYTE   = 8'h10;    // Enable channel 0 only

    // ---------------------------------------------------------------------------
    // State machine encoding
    // ---------------------------------------------------------------------------
    localparam IDLE         = 5'd0;
    localparam START_SDA_LO = 5'd1;
    localparam START_SCL_LO = 5'd2;
    localparam WR_ADDR_BIT  = 5'd3;
    localparam WR_ADDR_ACK  = 5'd4;
    localparam WR_CFG_BIT   = 5'd5;
    localparam WR_CFG_ACK   = 5'd6;
    localparam REP_START_H  = 5'd7;
    localparam REP_START_SDA_HI = 5'd8;
    localparam REP_START_SCL_HI = 5'd9;
    localparam REP_START_SDA_LO = 5'd10;
    localparam REP_START_SCL_LO2= 5'd11;
    localparam RD_ADDR_BIT  = 5'd12;
    localparam RD_ADDR_ACK  = 5'd13;
    localparam RD_BYTE1_BIT = 5'd14;
    localparam RD_BYTE1_ACK = 5'd15;
    localparam RD_BYTE2_BIT = 5'd16;
    localparam RD_NACK      = 5'd17;
    localparam STOP_SCL_HI  = 5'd18;
    localparam STOP_SDA_HI  = 5'd19;
    localparam DONE         = 5'd20;

    // ---------------------------------------------------------------------------
    // Registers
    // ---------------------------------------------------------------------------
    reg [4:0]  state;
    reg [7:0]  clk_cnt;      // SCL half-period counter
    reg [2:0]  bit_cnt;      // bit index within a byte (7 downto 0)
    reg [7:0]  shift_reg;    // shift register for TX/RX
    reg [7:0]  byte1;        // first received byte
    reg        scl_r;        // SCL output register
    reg        sda_out;      // SDA drive value
    reg        sda_oe;       // SDA output enable (1=drive, 0=tristate)
    reg        phase;        // 0 = first half of SCL, 1 = second half

    // ---------------------------------------------------------------------------
    // Combinational outputs
    // ---------------------------------------------------------------------------
    assign adc_scl = scl_r;
    assign adc_sda = sda_oe ? sda_out : 1'bz;

    // Convenience: SDA input
    wire sda_in = adc_sda;

    // ---------------------------------------------------------------------------
    // Half-period tick
    // ---------------------------------------------------------------------------
    wire half_tick = (clk_cnt == CLK_DIV);

    // ---------------------------------------------------------------------------
    // FSM
    // ---------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= IDLE;
            clk_cnt  <= 8'd0;
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
            adc_valid <= 1'b0;  // default de-assert

            case (state)

                // ---------------------------------------------------------------
                IDLE: begin
                    scl_r   <= 1'b1;
                    sda_out <= 1'b1;
                    sda_oe  <= 1'b1;
                    clk_cnt <= 8'd0;
                    bit_cnt <= 3'd7;
                    if (start) begin
                        state <= START_SDA_LO;
                    end
                end

                // ---------------------------------------------------------------
                // START condition: SDA falls while SCL is HIGH
                // ---------------------------------------------------------------
                START_SDA_LO: begin
                    // SCL stays HIGH, pull SDA low
                    sda_out <= 1'b0;
                    sda_oe  <= 1'b1;
                    if (half_tick) begin
                        clk_cnt <= 8'd0;
                        state   <= START_SCL_LO;
                    end else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end

                START_SCL_LO: begin
                    scl_r <= 1'b0;
                    if (half_tick) begin
                        clk_cnt  <= 8'd0;
                        shift_reg<= {I2C_ADDR, 1'b0};  // WRITE bit
                        bit_cnt  <= 3'd7;
                        state    <= WR_ADDR_BIT;
                    end else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end

                // ---------------------------------------------------------------
                // Write address byte (7-bit addr + W bit)
                // ---------------------------------------------------------------
                WR_ADDR_BIT: begin
                    if (!phase) begin
                        // Set SDA, SCL low half
                        sda_out <= shift_reg[7];
                        sda_oe  <= 1'b1;
                        scl_r   <= 1'b0;
                        if (half_tick) begin
                            clk_cnt <= 8'd0;
                            scl_r   <= 1'b1;
                            phase   <= 1'b1;
                        end else begin
                            clk_cnt <= clk_cnt + 1'b1;
                        end
                    end else begin
                        // SCL high half — data stable
                        if (half_tick) begin
                            clk_cnt  <= 8'd0;
                            scl_r    <= 1'b0;
                            phase    <= 1'b0;
                            shift_reg<= {shift_reg[6:0], 1'b0};
                            if (bit_cnt == 3'd0) begin
                                state   <= WR_ADDR_ACK;
                            end else begin
                                bit_cnt <= bit_cnt - 1'b1;
                            end
                        end else begin
                            clk_cnt <= clk_cnt + 1'b1;
                        end
                    end
                end

                // Receive ACK from slave
                WR_ADDR_ACK: begin
                    sda_oe <= 1'b0;  // tristate SDA
                    if (!phase) begin
                        scl_r <= 1'b1;
                        if (half_tick) begin
                            clk_cnt <= 8'd0;
                            phase   <= 1'b1;
                        end else begin
                            clk_cnt <= clk_cnt + 1'b1;
                        end
                    end else begin
                        // Sample SDA (ACK = low, ignore and proceed)
                        if (half_tick) begin
                            clk_cnt  <= 8'd0;
                            scl_r    <= 1'b0;
                            phase    <= 1'b0;
                            shift_reg<= CFG_BYTE;
                            bit_cnt  <= 3'd7;
                            state    <= WR_CFG_BIT;
                        end else begin
                            clk_cnt <= clk_cnt + 1'b1;
                        end
                    end
                end

                // ---------------------------------------------------------------
                // Write config byte (0x10)
                // ---------------------------------------------------------------
                WR_CFG_BIT: begin
                    if (!phase) begin
                        sda_out <= shift_reg[7];
                        sda_oe  <= 1'b1;
                        scl_r   <= 1'b0;
                        if (half_tick) begin
                            clk_cnt <= 8'd0;
                            scl_r   <= 1'b1;
                            phase   <= 1'b1;
                        end else begin
                            clk_cnt <= clk_cnt + 1'b1;
                        end
                    end else begin
                        if (half_tick) begin
                            clk_cnt  <= 8'd0;
                            scl_r    <= 1'b0;
                            phase    <= 1'b0;
                            shift_reg<= {shift_reg[6:0], 1'b0};
                            if (bit_cnt == 3'd0) begin
                                state   <= WR_CFG_ACK;
                            end else begin
                                bit_cnt <= bit_cnt - 1'b1;
                            end
                        end else begin
                            clk_cnt <= clk_cnt + 1'b1;
                        end
                    end
                end

                WR_CFG_ACK: begin
                    sda_oe <= 1'b0;
                    if (!phase) begin
                        scl_r <= 1'b1;
                        if (half_tick) begin
                            clk_cnt <= 8'd0;
                            phase   <= 1'b1;
                        end else begin
                            clk_cnt <= clk_cnt + 1'b1;
                        end
                    end else begin
                        if (half_tick) begin
                            clk_cnt <= 8'd0;
                            scl_r   <= 1'b0;
                            phase   <= 1'b0;
                            state   <= REP_START_H;
                        end else begin
                            clk_cnt <= clk_cnt + 1'b1;
                        end
                    end
                end

                // ---------------------------------------------------------------
                // REPEATED START: SCL goes high, then SDA goes high, then SDA falls
                // ---------------------------------------------------------------
                REP_START_H: begin
                    // SCL still low, raise SDA first
                    sda_out <= 1'b1;
                    sda_oe  <= 1'b1;
                    if (half_tick) begin
                        clk_cnt <= 8'd0;
                        state   <= REP_START_SDA_HI;
                    end else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end

                REP_START_SDA_HI: begin
                    // Raise SCL
                    scl_r <= 1'b1;
                    if (half_tick) begin
                        clk_cnt <= 8'd0;
                        state   <= REP_START_SCL_HI;
                    end else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end

                REP_START_SCL_HI: begin
                    // Pull SDA low while SCL is high = repeated START
                    sda_out <= 1'b0;
                    if (half_tick) begin
                        clk_cnt <= 8'd0;
                        state   <= REP_START_SDA_LO;
                    end else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end

                REP_START_SDA_LO: begin
                    // Pull SCL low
                    scl_r <= 1'b0;
                    if (half_tick) begin
                        clk_cnt  <= 8'd0;
                        shift_reg<= {I2C_ADDR, 1'b1};  // READ bit
                        bit_cnt  <= 3'd7;
                        state    <= RD_ADDR_BIT;
                    end else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end

                // ---------------------------------------------------------------
                // Write address byte with READ bit
                // ---------------------------------------------------------------
                RD_ADDR_BIT: begin
                    if (!phase) begin
                        sda_out <= shift_reg[7];
                        sda_oe  <= 1'b1;
                        scl_r   <= 1'b0;
                        if (half_tick) begin
                            clk_cnt <= 8'd0;
                            scl_r   <= 1'b1;
                            phase   <= 1'b1;
                        end else begin
                            clk_cnt <= clk_cnt + 1'b1;
                        end
                    end else begin
                        if (half_tick) begin
                            clk_cnt  <= 8'd0;
                            scl_r    <= 1'b0;
                            phase    <= 1'b0;
                            shift_reg<= {shift_reg[6:0], 1'b0};
                            if (bit_cnt == 3'd0) begin
                                state   <= RD_ADDR_ACK;
                            end else begin
                                bit_cnt <= bit_cnt - 1'b1;
                            end
                        end else begin
                            clk_cnt <= clk_cnt + 1'b1;
                        end
                    end
                end

                RD_ADDR_ACK: begin
                    sda_oe <= 1'b0;
                    if (!phase) begin
                        scl_r <= 1'b1;
                        if (half_tick) begin
                            clk_cnt <= 8'd0;
                            phase   <= 1'b1;
                        end else begin
                            clk_cnt <= clk_cnt + 1'b1;
                        end
                    end else begin
                        if (half_tick) begin
                            clk_cnt <= 8'd0;
                            scl_r   <= 1'b0;
                            phase   <= 1'b0;
                            bit_cnt <= 3'd7;
                            state   <= RD_BYTE1_BIT;
                        end else begin
                            clk_cnt <= clk_cnt + 1'b1;
                        end
                    end
                end

                // ---------------------------------------------------------------
                // Read byte 1: [7:4] = channel tag (ignore), [3:0] = data[11:8]
                // ---------------------------------------------------------------
                RD_BYTE1_BIT: begin
                    sda_oe <= 1'b0;
                    if (!phase) begin
                        scl_r <= 1'b1;
                        if (half_tick) begin
                            clk_cnt  <= 8'd0;
                            phase    <= 1'b1;
                            shift_reg<= {shift_reg[6:0], sda_in};
                        end else begin
                            clk_cnt <= clk_cnt + 1'b1;
                        end
                    end else begin
                        if (half_tick) begin
                            clk_cnt <= 8'd0;
                            scl_r   <= 1'b0;
                            phase   <= 1'b0;
                            if (bit_cnt == 3'd0) begin
                                byte1   <= shift_reg;
                                // Send ACK
                                sda_out <= 1'b0;
                                sda_oe  <= 1'b1;
                                bit_cnt <= 3'd7;
                                state   <= RD_BYTE1_ACK;
                            end else begin
                                bit_cnt <= bit_cnt - 1'b1;
                            end
                        end else begin
                            clk_cnt <= clk_cnt + 1'b1;
                        end
                    end
                end

                RD_BYTE1_ACK: begin
                    sda_out <= 1'b0;
                    sda_oe  <= 1'b1;
                    if (!phase) begin
                        scl_r <= 1'b1;
                        if (half_tick) begin
                            clk_cnt <= 8'd0;
                            phase   <= 1'b1;
                        end else begin
                            clk_cnt <= clk_cnt + 1'b1;
                        end
                    end else begin
                        if (half_tick) begin
                            clk_cnt  <= 8'd0;
                            scl_r    <= 1'b0;
                            sda_oe   <= 1'b0;
                            phase    <= 1'b0;
                            shift_reg<= 8'd0;
                            state    <= RD_BYTE2_BIT;
                        end else begin
                            clk_cnt <= clk_cnt + 1'b1;
                        end
                    end
                end

                // ---------------------------------------------------------------
                // Read byte 2: [7:0] = data[7:0]
                // ---------------------------------------------------------------
                RD_BYTE2_BIT: begin
                    sda_oe <= 1'b0;
                    if (!phase) begin
                        scl_r <= 1'b1;
                        if (half_tick) begin
                            clk_cnt  <= 8'd0;
                            phase    <= 1'b1;
                            shift_reg<= {shift_reg[6:0], sda_in};
                        end else begin
                            clk_cnt <= clk_cnt + 1'b1;
                        end
                    end else begin
                        if (half_tick) begin
                            clk_cnt <= 8'd0;
                            scl_r   <= 1'b0;
                            phase   <= 1'b0;
                            if (bit_cnt == 3'd0) begin
                                // Assemble 12-bit result: byte1[3:0] = upper, shift_reg = lower
                                adc_data <= {byte1[3:0], shift_reg};
                                state    <= RD_NACK;
                            end else begin
                                bit_cnt <= bit_cnt - 1'b1;
                            end
                        end else begin
                            clk_cnt <= clk_cnt + 1'b1;
                        end
                    end
                end

                // ---------------------------------------------------------------
                // Send NACK (SDA high during ACK clock)
                // ---------------------------------------------------------------
                RD_NACK: begin
                    sda_out <= 1'b1;
                    sda_oe  <= 1'b1;
                    if (!phase) begin
                        scl_r <= 1'b1;
                        if (half_tick) begin
                            clk_cnt <= 8'd0;
                            phase   <= 1'b1;
                        end else begin
                            clk_cnt <= clk_cnt + 1'b1;
                        end
                    end else begin
                        if (half_tick) begin
                            clk_cnt <= 8'd0;
                            scl_r   <= 1'b0;
                            phase   <= 1'b0;
                            state   <= STOP_SCL_HI;
                        end else begin
                            clk_cnt <= clk_cnt + 1'b1;
                        end
                    end
                end

                // ---------------------------------------------------------------
                // STOP condition: SDA rises while SCL is HIGH
                // ---------------------------------------------------------------
                STOP_SCL_HI: begin
                    sda_out <= 1'b0;
                    sda_oe  <= 1'b1;
                    scl_r   <= 1'b1;
                    if (half_tick) begin
                        clk_cnt <= 8'd0;
                        state   <= STOP_SDA_HI;
                    end else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end

                STOP_SDA_HI: begin
                    sda_out <= 1'b1;
                    if (half_tick) begin
                        clk_cnt   <= 8'd0;
                        adc_valid <= 1'b1;
                        state     <= DONE;
                    end else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
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
