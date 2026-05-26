// Module   : axi_ecg_ctrl
// Project  : PYNQ-Z2 ECG Demo
// Agent    : pynq_ecg_process
// Purpose  : AXI4-Lite slave register block — full register map 0x00-0x40

// Register map (base address 0x43C00000 set in Vivado address editor):
//
//  0x00  BPM_CH_A        R/W  [7:0]   Ch A heart rate default 60 BPM   (0x3C)
//  0x04  RR_FLUCT        R/W  [7:0]   RR variation 0-255               (0x00)
//  0x08  AMP_FLUCT       R/W  [7:0]   Amplitude variation 0-255        (0x00)
//  0x0C  BPM_CH_B        R/W  [7:0]   Ch B default 40 BPM              (0x28)
//  0x10  BPM_CH_C        R/W  [7:0]   Ch C default 50 BPM              (0x32)
//  0x14  BPM_CH_D        R/W  [7:0]   Ch D default 70 BPM              (0x46)
//  0x18  BPM_CH_E        R/W  [7:0]   Ch E default 80 BPM              (0x50)
//  0x1C  BPM_CH_F        R/W  [7:0]   Ch F default 100 BPM             (0x64)
//  0x20  BPM_CH_G        R/W  [7:0]   Ch G default 120 BPM             (0x78)
//  0x24  BPM_CH_H        R/W  [7:0]   Ch H default 150 BPM             (0x96)
//  0x28  ECG_RAW         R    [11:0]  Latest raw ADC sample            (0x000)
//  0x2C  ECG_FILTERED    R    [11:0]  Latest filtered sample           (0x000)
//  0x30  BPM_OUT         R    [7:0]   Live BPM from R-peak detector    (0x00)
//  0x34  RPEAK_COUNT     R    [15:0]  Rolling R-peak event counter     (0x0000)
//  0x38  DETECT_THRESHOLD R/W [11:0]  R-peak detection threshold       (0x800)
//  0x3C  STATUS          R    [1:0]   [0]=signal_present [1]=lead_off  (0x00)
//  0x40  ECG_DAC         R    [11:0]  Latest Ch A DDS sample value     (0x000)
//
// Default threshold 0x800 (2048 decimal); runtime override via PS sets 2983 per spec.

module axi_ecg_ctrl #(
    parameter DATA_WIDTH = 32,
    parameter ADDR_WIDTH = 32
)(
    // AXI4-Lite slave interface
    input  wire                    s_axi_aclk,
    input  wire                    s_axi_aresetn,

    // Write address channel
    input  wire [ADDR_WIDTH-1:0]   s_axi_awaddr,
    input  wire [2:0]              s_axi_awprot,
    input  wire                    s_axi_awvalid,
    output reg                     s_axi_awready,

    // Write data channel
    input  wire [DATA_WIDTH-1:0]   s_axi_wdata,
    input  wire [DATA_WIDTH/8-1:0] s_axi_wstrb,
    input  wire                    s_axi_wvalid,
    output reg                     s_axi_wready,

    // Write response channel
    output reg  [1:0]              s_axi_bresp,
    output reg                     s_axi_bvalid,
    input  wire                    s_axi_bready,

    // Read address channel
    input  wire [ADDR_WIDTH-1:0]   s_axi_araddr,
    input  wire [2:0]              s_axi_arprot,
    input  wire                    s_axi_arvalid,
    output reg                     s_axi_arready,

    // Read data channel
    output reg  [DATA_WIDTH-1:0]   s_axi_rdata,
    output reg  [1:0]              s_axi_rresp,
    output reg                     s_axi_rvalid,
    input  wire                    s_axi_rready,

    // Output wires to PL modules (ecg_signal_gen_top)
    output wire [7:0]  bpm_ch_a,
    output wire [7:0]  bpm_ch_b,
    output wire [7:0]  bpm_ch_c,
    output wire [7:0]  bpm_ch_d,
    output wire [7:0]  bpm_ch_e,
    output wire [7:0]  bpm_ch_f,
    output wire [7:0]  bpm_ch_g,
    output wire [7:0]  bpm_ch_h,
    output wire [7:0]  rr_fluct,
    output wire [7:0]  amp_fluct,
    output wire [11:0] detect_thresh,

    // Input wires from PL modules (ecg_process pipeline)
    input  wire [11:0] ecg_raw_in,
    input  wire [11:0] ecg_filt_in,
    input  wire [7:0]  bpm_in,
    input  wire        rpeak_in,

    // Input wire from DDS — latest Ch A DAC sample
    input  wire [11:0] dac_sample_in
);

    // ---------------------------------------------------------------------------
    // Registers
    // ---------------------------------------------------------------------------
    reg [7:0]  reg_bpm_ch_a;
    reg [7:0]  reg_rr_fluct;
    reg [7:0]  reg_amp_fluct;
    reg [7:0]  reg_bpm_ch_b;
    reg [7:0]  reg_bpm_ch_c;
    reg [7:0]  reg_bpm_ch_d;
    reg [7:0]  reg_bpm_ch_e;
    reg [7:0]  reg_bpm_ch_f;
    reg [7:0]  reg_bpm_ch_g;
    reg [7:0]  reg_bpm_ch_h;
    reg [11:0] reg_detect_thresh;

    // Read-only shadow registers (updated from inputs)
    reg [11:0] reg_ecg_raw;
    reg [11:0] reg_ecg_filt;
    reg [11:0] ecg_dac_reg;
    reg [7:0]  reg_bpm_out;
    reg [15:0] reg_rpeak_count;
    reg [1:0]  reg_status;

    // Signal-present detection: sample > 0x010 in last 1000 cycles
    reg [9:0]  sig_window_cnt;
    reg        signal_present;

    // ---------------------------------------------------------------------------
    // Output assignments
    // ---------------------------------------------------------------------------
    assign bpm_ch_a    = reg_bpm_ch_a;
    assign bpm_ch_b    = reg_bpm_ch_b;
    assign bpm_ch_c    = reg_bpm_ch_c;
    assign bpm_ch_d    = reg_bpm_ch_d;
    assign bpm_ch_e    = reg_bpm_ch_e;
    assign bpm_ch_f    = reg_bpm_ch_f;
    assign bpm_ch_g    = reg_bpm_ch_g;
    assign bpm_ch_h    = reg_bpm_ch_h;
    assign rr_fluct    = reg_rr_fluct;
    assign amp_fluct   = reg_amp_fluct;
    assign detect_thresh = reg_detect_thresh;

    // ---------------------------------------------------------------------------
    // AXI write address / data capture
    // ---------------------------------------------------------------------------
    reg [ADDR_WIDTH-1:0] wr_addr_lat;
    reg [DATA_WIDTH-1:0] wr_data_lat;
    reg [DATA_WIDTH/8-1:0] wr_strb_lat;
    reg wr_addr_valid;
    reg wr_data_valid;

    // ---------------------------------------------------------------------------
    // Register writes and read-only shadow updates
    // ---------------------------------------------------------------------------
    always @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
        if (!s_axi_aresetn) begin
            // Writable registers — defaults from register_map.md
            reg_bpm_ch_a      <= 8'h3C;
            reg_rr_fluct      <= 8'h00;
            reg_amp_fluct     <= 8'h00;
            reg_bpm_ch_b      <= 8'h28;
            reg_bpm_ch_c      <= 8'h32;
            reg_bpm_ch_d      <= 8'h46;
            reg_bpm_ch_e      <= 8'h50;
            reg_bpm_ch_f      <= 8'h64;
            reg_bpm_ch_g      <= 8'h78;
            reg_bpm_ch_h      <= 8'h96;
            reg_detect_thresh <= 12'h800;

            // Read-only registers
            reg_ecg_raw    <= 12'd0;
            reg_ecg_filt   <= 12'd0;
            ecg_dac_reg    <= 12'd0;
            reg_bpm_out    <= 8'd0;
            reg_rpeak_count<= 16'd0;
            reg_status     <= 2'b00;

            // AXI handshake state
            s_axi_awready  <= 1'b0;
            s_axi_wready   <= 1'b0;
            s_axi_bresp    <= 2'b00;
            s_axi_bvalid   <= 1'b0;
            wr_addr_valid  <= 1'b0;
            wr_data_valid  <= 1'b0;
            wr_addr_lat    <= {ADDR_WIDTH{1'b0}};
            wr_data_lat    <= {DATA_WIDTH{1'b0}};
            wr_strb_lat    <= {DATA_WIDTH/8{1'b0}};

            sig_window_cnt <= 10'd0;
            signal_present <= 1'b0;
        end else begin
            // ------------------------------------------------------------------
            // Latch incoming write address
            // ------------------------------------------------------------------
            if (s_axi_awvalid && !wr_addr_valid) begin
                wr_addr_lat   <= s_axi_awaddr;
                wr_addr_valid <= 1'b1;
                s_axi_awready <= 1'b1;
            end else begin
                s_axi_awready <= 1'b0;
            end

            // ------------------------------------------------------------------
            // Latch incoming write data
            // ------------------------------------------------------------------
            if (s_axi_wvalid && !wr_data_valid) begin
                wr_data_lat   <= s_axi_wdata;
                wr_strb_lat   <= s_axi_wstrb;
                wr_data_valid <= 1'b1;
                s_axi_wready  <= 1'b1;
            end else begin
                s_axi_wready  <= 1'b0;
            end

            // ------------------------------------------------------------------
            // Execute write when both address and data are latched
            // ------------------------------------------------------------------
            if (wr_addr_valid && wr_data_valid) begin
                wr_addr_valid <= 1'b0;
                wr_data_valid <= 1'b0;

                // Byte-enable aware write (only byte 0 is relevant for [7:0] regs)
                case (wr_addr_lat[6:0])
                    7'h00: if (wr_strb_lat[0]) reg_bpm_ch_a      <= wr_data_lat[7:0];
                    7'h04: if (wr_strb_lat[0]) reg_rr_fluct       <= wr_data_lat[7:0];
                    7'h08: if (wr_strb_lat[0]) reg_amp_fluct      <= wr_data_lat[7:0];
                    7'h0C: if (wr_strb_lat[0]) reg_bpm_ch_b       <= wr_data_lat[7:0];
                    7'h10: if (wr_strb_lat[0]) reg_bpm_ch_c       <= wr_data_lat[7:0];
                    7'h14: if (wr_strb_lat[0]) reg_bpm_ch_d       <= wr_data_lat[7:0];
                    7'h18: if (wr_strb_lat[0]) reg_bpm_ch_e       <= wr_data_lat[7:0];
                    7'h1C: if (wr_strb_lat[0]) reg_bpm_ch_f       <= wr_data_lat[7:0];
                    7'h20: if (wr_strb_lat[0]) reg_bpm_ch_g       <= wr_data_lat[7:0];
                    7'h24: if (wr_strb_lat[0]) reg_bpm_ch_h       <= wr_data_lat[7:0];
                    // 0x28 ECG_RAW       — read-only, write ignored
                    // 0x2C ECG_FILTERED  — read-only, write ignored
                    // 0x30 BPM_OUT       — read-only, write ignored
                    // 0x34 RPEAK_COUNT   — read-only, write ignored
                    7'h38: begin
                        if (wr_strb_lat[0]) reg_detect_thresh[7:0]  <= wr_data_lat[7:0];
                        if (wr_strb_lat[1]) reg_detect_thresh[11:8] <= wr_data_lat[11:8];
                    end
                    // 0x3C STATUS        — read-only, write ignored
                    // 0x40 ECG_DAC       — read-only, write ignored
                    default: ; // no-op
                endcase

                // Issue write response
                s_axi_bresp  <= 2'b00;  // OKAY
                s_axi_bvalid <= 1'b1;
            end

            // Clear bvalid after handshake
            if (s_axi_bvalid && s_axi_bready)
                s_axi_bvalid <= 1'b0;

            // ------------------------------------------------------------------
            // Update read-only shadow registers from PL inputs
            // ------------------------------------------------------------------
            reg_ecg_raw  <= ecg_raw_in;
            reg_ecg_filt <= ecg_filt_in;
            ecg_dac_reg  <= dac_sample_in;
            reg_bpm_out  <= bpm_in;

            if (rpeak_in)
                reg_rpeak_count <= reg_rpeak_count + 1'b1;

            // Signal-present detection: any sample > 0x010 in last 1000 cycles
            sig_window_cnt <= sig_window_cnt + 1'b1;
            if (sig_window_cnt == 10'd999) begin
                sig_window_cnt <= 10'd0;
                signal_present <= 1'b0;
            end
            if (ecg_raw_in > 12'h010)
                signal_present <= 1'b1;

            reg_status <= {1'b0, signal_present};  // [1]=lead_off (unused), [0]=signal_present
        end
    end

    // ---------------------------------------------------------------------------
    // AXI read path — respond within 2 cycles
    // ---------------------------------------------------------------------------
    always @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
        if (!s_axi_aresetn) begin
            s_axi_arready <= 1'b0;
            s_axi_rvalid  <= 1'b0;
            s_axi_rdata   <= {DATA_WIDTH{1'b0}};
            s_axi_rresp   <= 2'b00;
        end else begin
            s_axi_arready <= 1'b0;

            if (s_axi_arvalid && !s_axi_rvalid) begin
                s_axi_arready <= 1'b1;
                s_axi_rresp   <= 2'b00;  // OKAY
                s_axi_rvalid  <= 1'b1;

                // Register read decode
                case (s_axi_araddr[6:0])
                    7'h00: s_axi_rdata <= {24'd0, reg_bpm_ch_a};
                    7'h04: s_axi_rdata <= {24'd0, reg_rr_fluct};
                    7'h08: s_axi_rdata <= {24'd0, reg_amp_fluct};
                    7'h0C: s_axi_rdata <= {24'd0, reg_bpm_ch_b};
                    7'h10: s_axi_rdata <= {24'd0, reg_bpm_ch_c};
                    7'h14: s_axi_rdata <= {24'd0, reg_bpm_ch_d};
                    7'h18: s_axi_rdata <= {24'd0, reg_bpm_ch_e};
                    7'h1C: s_axi_rdata <= {24'd0, reg_bpm_ch_f};
                    7'h20: s_axi_rdata <= {24'd0, reg_bpm_ch_g};
                    7'h24: s_axi_rdata <= {24'd0, reg_bpm_ch_h};
                    7'h28: s_axi_rdata <= {20'd0, reg_ecg_raw};
                    7'h2C: s_axi_rdata <= {20'd0, reg_ecg_filt};
                    7'h30: s_axi_rdata <= {24'd0, reg_bpm_out};
                    7'h34: s_axi_rdata <= {16'd0, reg_rpeak_count};
                    7'h38: s_axi_rdata <= {20'd0, reg_detect_thresh};
                    7'h3C: s_axi_rdata <= {30'd0, reg_status};
                    7'h40: s_axi_rdata <= {20'd0, ecg_dac_reg};
                    default: s_axi_rdata <= {DATA_WIDTH{1'b0}};
                endcase
            end

            // De-assert rvalid after handshake
            if (s_axi_rvalid && s_axi_rready)
                s_axi_rvalid <= 1'b0;
        end
    end

endmodule
