module fir 
#(  parameter pADDR_WIDTH = 12,
    parameter pDATA_WIDTH = 32,
    parameter Tape_Num    = 11
)
(
    // AXI-Lite
    // write
    output  reg                      awready,
    output  reg                      wready,
    input   wire                     awvalid,
    input   wire [(pADDR_WIDTH-1):0] awaddr,
    input   wire                     wvalid,
    input   wire [(pDATA_WIDTH-1):0] wdata,
    // write
    output  reg                      arready,
    input   wire                     rready,
    input   wire                     arvalid,
    input   wire [(pADDR_WIDTH-1):0] araddr,
    output  reg                      rvalid,
    output  reg  [(pDATA_WIDTH-1):0] rdata, 

    // AXI-Stream   
    // Input data
    input   wire                     ss_tvalid, 
    input   wire [(pDATA_WIDTH-1):0] ss_tdata, 
    input   wire                     ss_tlast, 
    output  reg                      ss_tready, 
    // Output data
    input   wire                     sm_tready, 
    output  reg                      sm_tvalid, 
    output  reg  [(pDATA_WIDTH-1):0] sm_tdata, 
    output  reg                      sm_tlast, 
    
    // bram for tap RAM
    output  reg  [3:0]               tap_WE,
    output  reg                      tap_EN,
    output  reg  [(pDATA_WIDTH-1):0] tap_Di,
    output  reg  [(pADDR_WIDTH-1):0] tap_A,
    input   wire [(pDATA_WIDTH-1):0] tap_Do,

    // bram for data RAM
    output  reg  [3:0]               data_WE,
    output  reg                      data_EN,
    output  reg  [(pDATA_WIDTH-1):0] data_Di,
    output  reg  [(pADDR_WIDTH-1):0] data_A,
    input   wire [(pDATA_WIDTH-1):0] data_Do,

    input   wire                     axis_clk,
    input   wire                     axis_rst_n
);

// block level signal
reg ap_start, n_ap_start;
reg ap_idle, n_ap_idle;
reg ap_done, n_ap_done;
reg [31:0] data_length;

// axi-lite read
localparam  AXI_READ_IDLE = 0,
            AXI_READ_ADDR = 1,
            AXI_READ_WAIT = 2,
            AXI_READ_DATA = 3;

// axi-lite write
localparam  AXI_WRITE_IDLE = 0,
            AXI_WRITE_ADDR = 1,
            AXI_WRITE_DATA = 2;

// Stream-In
reg n_ss_tready;
// Stream-Out
reg last_flg;

// AXI
reg [2:0] axi_read_state, n_axi_read_state;
reg [2:0] axi_write_state, n_axi_write_state;

// tapRAM
reg [11:0] tap_access_addr;
reg [31:0] real_Do;
reg [11:0] tapWriteAddr;
reg [11:0] tapReadAddr;

// dataRAM
reg [3:0] dataRam_rst_cnt;
reg [11:0] dataWriteAddr, n_dataWriteAdddr;
reg [11:0] dataReadAddr, n_dataReadAddr;

// FIR fsm
localparam  FIR_IDLE = 12,
            DATA_RST = 15,
            FIR_WAIT = 14,
            FIR_SSIN = 13,
            FIR_STOR = 11,
            FIR_S0 = 0,
            FIR_S1 = 1,
            FIR_S2 = 2,
            FIR_S3 = 3,
            FIR_S4 = 4,
            FIR_S5 = 5,
            FIR_S6 = 6,
            FIR_S7 = 7,
            FIR_S8 = 8,
            FIR_S9 = 9,
            FIR_SA = 10,
            FIR_OUT = 16;

reg [4:0] fir_state, n_fir_state;
reg signed [31:0] Yn, Xn, Hn; // Output, Data, Tap


// ======================= AXI-Lite: Read ======================================
always @(*) begin
    case (axi_read_state)
        AXI_READ_IDLE:  n_axi_read_state = (arvalid == 1) ? AXI_READ_ADDR : AXI_READ_IDLE;
        AXI_READ_ADDR:  n_axi_read_state = AXI_READ_WAIT;
        AXI_READ_WAIT:  n_axi_read_state = AXI_READ_DATA;
        AXI_READ_DATA:  n_axi_read_state = (rvalid == 1) ? AXI_READ_IDLE : AXI_READ_DATA;
        default: n_axi_read_state = AXI_READ_IDLE;
    endcase
end


always @(posedge axis_clk or negedge axis_rst_n) begin
    if (!axis_rst_n) begin
        axi_read_state  <= AXI_READ_IDLE;
        arready <= 0;
        rvalid  <= 0;
    end else begin
        axi_read_state  <= n_axi_read_state;
        arready <= (n_axi_read_state == AXI_READ_ADDR) ? 1 : 0;
        rvalid  <= (n_axi_read_state == AXI_READ_DATA) ? 1 : 0;
    end
end

always @(*) begin
    case (tapReadAddr)
        'h00: rdata = {ap_idle, ap_done, ap_start};     // block level signals
        'h10: rdata = data_length;                      // data length
        default: rdata = tap_Do;
    endcase
end

// ======================= AXI-Lite: Write ======================================
always @(*) begin
    case (axi_write_state)
        AXI_WRITE_IDLE: n_axi_write_state = (awvalid == 1) ? AXI_WRITE_ADDR : AXI_WRITE_IDLE;
        AXI_WRITE_ADDR: n_axi_write_state = AXI_WRITE_DATA;
        AXI_WRITE_DATA: n_axi_write_state = (wvalid == 1) ? AXI_WRITE_IDLE : AXI_WRITE_DATA;
        default: n_axi_write_state = AXI_WRITE_IDLE;
    endcase
end

always @(posedge axis_clk or negedge axis_rst_n) begin
    if (!axis_rst_n) begin
        axi_write_state  <= AXI_WRITE_IDLE;
        awready <= 0;
        wready  <= 0;
    end else begin
        axi_write_state  <= n_axi_write_state;
        awready <= (n_axi_write_state == AXI_WRITE_ADDR) ? 1 : 0;
        wready  <= (n_axi_write_state == AXI_WRITE_DATA) ? 1 : 0;
    end
end

always @(posedge axis_clk or negedge axis_rst_n) begin
    if (!axis_rst_n) begin
        tapWriteAddr <= 0;
        tapReadAddr  <= 0;
    end
    else begin
        tapWriteAddr <= (awvalid == 1 && awready == 1) ? awaddr : tapWriteAddr;
        tapReadAddr  <= (arvalid == 1 && arready == 1) ? araddr : tapReadAddr;
    end
end


// ======================= Stream-In ============================================
always @(*) begin
    if (fir_state == FIR_SSIN)  ss_tready = 1;
    else                        ss_tready = 0;
end

always @(posedge axis_clk or negedge axis_rst_n) begin
    if (!axis_rst_n)    last_flg <= 0;
    else begin
        if      (fir_state == FIR_IDLE) last_flg <= 0;
        else if (fir_state == FIR_SSIN) last_flg <= ss_tlast;
        else                            last_flg <= last_flg;
    end
end

// ======================= Stream-Out ===========================================
always @(*) begin
    if (fir_state == FIR_OUT) begin
        sm_tvalid = 1;
        sm_tdata = Yn;
        sm_tlast = last_flg;
    end
    else begin
        sm_tvalid = 0;
        sm_tdata = 0;
        sm_tlast = 0;
    end
end


// ======================= Block level Signals ===================================
// ap_start
always @(*) begin
    if      (tapWriteAddr == 'h00 && wready == 1 && wvalid == 1 && wdata == 1)  n_ap_start = wdata;     // Host program ap_start = 1
    else if (fir_state == FIR_SSIN)                                             n_ap_start = 0;         // Reset to 0, when 1st AXI-Stream handshake
    else                                                                        n_ap_start = ap_start;
end

// ap_idle
always @(*) begin
    if      (tapWriteAddr == 'h00 && wready == 1 && wvalid == 1 && wdata == 1)  n_ap_idle = 0;      // Host program ap_start = 1
    else if (fir_state == FIR_OUT && last_flg == 1)                             n_ap_idle = 1;      // Reset to 1, when last data had axi-streamed out
    else                                                                        n_ap_idle = ap_idle;   
end

// ap_done
always @(*) begin
    if      (fir_state == FIR_OUT && last_flg == 1) n_ap_done = 1;
    else if (fir_state == FIR_SSIN)                 n_ap_done = 0;
    else                                            n_ap_done = ap_done;
end


always @(posedge axis_clk or negedge axis_rst_n) begin
    if (!axis_rst_n) begin
        ap_start    <= 0;
        ap_idle     <= 1;
        ap_done     <= 0;
        data_length <= 0;
    end else begin
        data_length <= (tapWriteAddr == 'h10 && wready == 1 && wvalid == 1) ? wdata : data_length;
        ap_start    <= n_ap_start;
        ap_idle     <= n_ap_idle;
        ap_done     <= n_ap_done;
    end
end


// ======================= tapRAM ================================================
// tap_A
always @(*) begin
    if      (wready == 1 && wvalid == 1)                        tap_access_addr = tapWriteAddr;
    else if (axi_read_state == AXI_READ_WAIT && ap_idle == 1)   tap_access_addr = tapReadAddr;
    else                                                        tap_access_addr = (n_fir_state << 2) + 'h20; // this could be done more pretty

    tap_A = ('h20 <= tap_access_addr && tap_access_addr <= 'h48) ? tap_access_addr - 'h20 : 0;
end

// tap_EN
always @(*) begin
    tap_EN = (  
        (wready == 1 && wvalid == 1) ||                     // when axi-write handshake
        (rready == 1 && rvalid == 1) ||                     // when axi-read  handshake
        (FIR_S0 <= n_fir_state && n_fir_state <= FIR_SA)    // when computing FIR, read the coeffs
    ) ? 1 : 0;
end

// tap_WE, tap_Di
always @(*) begin
    if (wready == 1 && wvalid == 1 && tapWriteAddr != 'h00 && tapWriteAddr != 'h10) begin   // when axi-write handshake, and address between 'h20 ~ 'h48
        tap_WE = 4'b1111;
        tap_Di = wdata;
    end
    else begin
        tap_WE = 0; 
        tap_Di = 0;
    end
end


// ======================= dataRAM ================================================
// Write pointer (dataWriteAddr)
always @(*) begin
    // Update Write pointer when Stream-In
    if (fir_state == FIR_SSIN) begin
        if (dataWriteAddr == 10)    n_dataWriteAdddr = 0;
        else                        n_dataWriteAdddr = dataWriteAddr + 1;
    end
    else begin
        n_dataWriteAdddr = dataWriteAddr;
    end
end

// Read pointer (dataReadAddr)
always @(*) begin
    if (fir_state == FIR_SSIN) begin
        n_dataReadAddr = (dataWriteAddr == 10) ? 0 : dataWriteAddr + 1;
    end
    else if (FIR_S0 <= fir_state && fir_state <= FIR_SA) begin
        n_dataReadAddr = (dataReadAddr == 10) ? 0 : dataReadAddr + 1;
    end
    else begin
        n_dataReadAddr = dataReadAddr;
    end
end
 
// Used for mimicing shiftRAM but not actually shift it
always @(posedge axis_clk or negedge axis_rst_n) begin
    if (!axis_rst_n) begin
        dataRam_rst_cnt <= 0;
        dataWriteAddr   <= 0;
        dataReadAddr    <= 1;
    end
    else begin 
        dataRam_rst_cnt <= (n_fir_state != fir_state) ? 0 : dataRam_rst_cnt + 1;
        dataWriteAddr   <= n_dataWriteAdddr;
        dataReadAddr    <= n_dataReadAddr;
    end
end

// data_WE, data_A, data_Di, data_EN
always @(*) begin
    // default
    data_WE = 0;
    data_A = 0;
    data_Di = 0;
    data_EN = 1;

    if (FIR_S0 <= n_fir_state && n_fir_state <= FIR_SA) begin
        data_EN = 1;
        data_A = (n_dataReadAddr << 2);   // This shifter (<< 2) could be share other where else
    end
    else if (fir_state == DATA_RST) begin // reset all data in dataRAM
        data_EN = 1;
        data_A = (dataRam_rst_cnt << 2);
        data_WE = 4'b1111;
        data_Di = 32'd0;
    end
    else if (fir_state == FIR_SSIN) begin // Write data into dataRAM
        data_EN = 1;
        data_A = (dataWriteAddr << 2);
        data_WE = 4'b1111;
        data_Di = ss_tdata;
    end
end


// ======================= FIR Engine ============================================
// FIR fsm
always @(*) begin
    // calculation of next FIR state is the critical path, could be easily solved by using counter 
    // to reduce mux size and the fewer usage of combs as other logic's control signals
    case (fir_state)
        FIR_IDLE:   n_fir_state = (wready == 1 && wvalid == 1 && wdata == 1) ?  DATA_RST : FIR_IDLE;
        DATA_RST:   n_fir_state = (dataRam_rst_cnt == 10) ? FIR_WAIT : DATA_RST;                        // dataRam reset state
        FIR_WAIT:   n_fir_state = (ss_tvalid == 1) ? FIR_SSIN : FIR_WAIT;                               // wait for Stream-In data
        FIR_SSIN:   n_fir_state = (ss_tready == 1) ? FIR_STOR : FIR_SSIN;                               // write the Stream-In data to dataRAM
        FIR_STOR:   n_fir_state = FIR_S0;                                                               // wait 1 cycle to let data store into dataRAM
        FIR_S0:     n_fir_state = FIR_S1;                                                               // 11 states for calculating FIR (n == 11)
        FIR_S1:     n_fir_state = FIR_S2;
        FIR_S2:     n_fir_state = FIR_S3;
        FIR_S3:     n_fir_state = FIR_S4;
        FIR_S4:     n_fir_state = FIR_S5;
        FIR_S5:     n_fir_state = FIR_S6;
        FIR_S6:     n_fir_state = FIR_S7;
        FIR_S7:     n_fir_state = FIR_S8;
        FIR_S8:     n_fir_state = FIR_S9;
        FIR_S9:     n_fir_state = FIR_SA;
        FIR_SA:     n_fir_state = FIR_OUT;
        FIR_OUT: begin
            if      (last_flg == 1)     n_fir_state = FIR_IDLE; // reset
            else if (sm_tready == 1)    n_fir_state = FIR_WAIT; // wait for next Stream-In data
            else                        n_fir_state = FIR_OUT;  // wait for handshake
        end
        default: n_fir_state = fir_state;
    endcase
end

always @(posedge axis_clk or negedge axis_rst_n) begin
    if (!axis_rst_n)    fir_state   <= FIR_IDLE;
    else                fir_state   <= n_fir_state;
end


// Get the Xn, Hn from dataRAM & tapRAM
always @(*) begin
    Xn = data_Do;
    Hn = tap_Do;
end

// Accumulator and Multiplier (1 adder & 1 multiplier for FIR)
always @(posedge axis_clk or negedge axis_rst_n) begin
    if (!axis_rst_n)    Yn <= 0;
    else begin
        if      (fir_state == FIR_SSIN)                             Yn <= 0;                // reset accumulator
        else if (FIR_S0 <= n_fir_state && n_fir_state <= FIR_SA)    Yn <= Yn + (Xn * Hn);   // accumulate Xn * Hn, could do it pipelined version instead
        else                                                        Yn <= Yn;
    end
end

endmodule