`timescale 1ns/1ps

module arinc429_tx #(
    parameter integer CLK_FREQ_HZ    = 50000000,
    parameter integer ARINC_BAUD     = 100000,
    parameter integer INTERWORD_BITS = 4
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        tx_start,
    input  wire [7:0]  label,
    input  wire [1:0]  sdi,
    input  wire [18:0] data,
    input  wire [1:0]  ssm,
    output reg         tx_data,
    output reg         tx_busy,
    output reg         tx_done
);

    function integer clog2_int;
        input integer value;
        integer i;
        begin
            clog2_int = 0;
            i = 1;
            while (i < value) begin
                i = i << 1;
                clog2_int = clog2_int + 1;
            end
        end
    endfunction

    localparam integer CYCLES_PER_BIT =
        (ARINC_BAUD > 0) ? (CLK_FREQ_HZ / ARINC_BAUD) : 0;
    localparam integer GAP_CYCLES =
        (INTERWORD_BITS > 0) ? (INTERWORD_BITS * CYCLES_PER_BIT) : 0;
    localparam integer COUNT_WIDTH_RAW = clog2_int(GAP_CYCLES + 1);
    localparam integer COUNT_WIDTH = (COUNT_WIDTH_RAW < 1) ? 1 : COUNT_WIDTH_RAW;

    localparam [1:0] ST_IDLE = 2'd0,
                     ST_TX   = 2'd1,
                     ST_GAP  = 2'd2;

    reg [1:0] state;
    reg [COUNT_WIDTH-1:0] clk_count;
    reg [5:0] bit_index;
    reg [31:0] tx_word;
    reg [31:0] serial_word;
    wire parity_bit;

    assign parity_bit = ~^{label, sdi, data, ssm};

    /* Explicit ARINC 429 digital serial order. */
    always @(*) begin
        serial_word[0]  = label[7];
        serial_word[1]  = label[6];
        serial_word[2]  = label[5];
        serial_word[3]  = label[4];
        serial_word[4]  = label[3];
        serial_word[5]  = label[2];
        serial_word[6]  = label[1];
        serial_word[7]  = label[0];
        serial_word[8]  = sdi[0];
        serial_word[9]  = sdi[1];
        serial_word[10] = data[0];
        serial_word[11] = data[1];
        serial_word[12] = data[2];
        serial_word[13] = data[3];
        serial_word[14] = data[4];
        serial_word[15] = data[5];
        serial_word[16] = data[6];
        serial_word[17] = data[7];
        serial_word[18] = data[8];
        serial_word[19] = data[9];
        serial_word[20] = data[10];
        serial_word[21] = data[11];
        serial_word[22] = data[12];
        serial_word[23] = data[13];
        serial_word[24] = data[14];
        serial_word[25] = data[15];
        serial_word[26] = data[16];
        serial_word[27] = data[17];
        serial_word[28] = data[18];
        serial_word[29] = ssm[0];
        serial_word[30] = ssm[1];
        serial_word[31] = parity_bit;
    end

`ifndef SYNTHESIS
    initial begin
        if (CLK_FREQ_HZ <= 0) begin
            $display("ERROR: CLK_FREQ_HZ must be greater than zero.");
            $finish;
        end
        if (ARINC_BAUD <= 0) begin
            $display("ERROR: ARINC_BAUD must be greater than zero.");
            $finish;
        end
        if (INTERWORD_BITS < 1) begin
            $display("ERROR: INTERWORD_BITS must be at least 1.");
            $finish;
        end
        if ((CLK_FREQ_HZ % ARINC_BAUD) != 0) begin
            $display("ERROR: CLK_FREQ_HZ must be divisible by ARINC_BAUD.");
            $finish;
        end
        if (CYCLES_PER_BIT < 4) begin
            $display("ERROR: CYCLES_PER_BIT is too small.");
            $finish;
        end
    end
`endif

    always @(posedge clk) begin
        if (rst) begin
            state     <= ST_IDLE;
            clk_count <= {COUNT_WIDTH{1'b0}};
            bit_index <= 6'd0;
            tx_word   <= 32'd0;
            tx_data   <= 1'b0;
            tx_busy   <= 1'b0;
            tx_done   <= 1'b0;
        end
        else begin
            tx_done <= 1'b0;

            case (state)
                ST_IDLE: begin
                    tx_data   <= 1'b0;
                    tx_busy   <= 1'b0;
                    clk_count <= {COUNT_WIDTH{1'b0}};
                    bit_index <= 6'd0;

                    if (tx_start) begin
                        tx_word   <= serial_word;
                        tx_data   <= serial_word[0];
                        tx_busy   <= 1'b1;
                        clk_count <= {COUNT_WIDTH{1'b0}};
                        bit_index <= 6'd0;
                        state     <= ST_TX;
                    end
                end

                ST_TX: begin
                    tx_busy <= 1'b1;
                    if (clk_count == CYCLES_PER_BIT - 1) begin
                        clk_count <= {COUNT_WIDTH{1'b0}};
                        if (bit_index == 6'd31) begin
                            bit_index <= 6'd0;
                            tx_data   <= 1'b0;
                            state     <= ST_GAP;
                        end
                        else begin
                            bit_index <= bit_index + 1'b1;
                            tx_data   <= tx_word[bit_index + 1'b1];
                        end
                    end
                    else begin
                        clk_count <= clk_count + 1'b1;
                    end
                end

                ST_GAP: begin
                    tx_data <= 1'b0;
                    tx_busy <= 1'b1;
                    if (clk_count == GAP_CYCLES - 1) begin
                        clk_count <= {COUNT_WIDTH{1'b0}};
                        tx_busy   <= 1'b0;
                        tx_done   <= 1'b1;
                        state     <= ST_IDLE;
                    end
                    else begin
                        clk_count <= clk_count + 1'b1;
                    end
                end

                default: begin
                    state     <= ST_IDLE;
                    clk_count <= {COUNT_WIDTH{1'b0}};
                    bit_index <= 6'd0;
                    tx_data   <= 1'b0;
                    tx_busy   <= 1'b0;
                    tx_done   <= 1'b0;
                end
            endcase
        end
    end
endmodule
