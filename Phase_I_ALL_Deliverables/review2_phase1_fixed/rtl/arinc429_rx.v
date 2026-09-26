`timescale 1ns/1ps

module arinc429_rx #(
    parameter integer CLK_FREQ_HZ = 50000000,
    parameter integer ARINC_BAUD  = 100000
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        arinc_rx,
    input  wire        rx_start,
    output reg [31:0]  rx_word,
    output reg         rx_valid,
    output reg         parity_error,
    output reg         rx_busy
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
    localparam integer HALF_CYCLES =
        (CYCLES_PER_BIT > 1) ? (CYCLES_PER_BIT / 2) : 1;
    localparam integer COUNT_WIDTH_RAW = clog2_int(CYCLES_PER_BIT + 1);
    localparam integer COUNT_WIDTH = (COUNT_WIDTH_RAW < 1) ? 1 : COUNT_WIDTH_RAW;

    localparam [1:0] ST_IDLE    = 2'd0,
                     ST_FIRST   = 2'd1,
                     ST_RECEIVE = 2'd2,
                     ST_DONE    = 2'd3;

    reg [1:0] state;
    reg [COUNT_WIDTH-1:0] clk_count;
    reg [5:0] bit_index;
    reg [31:0] rx_shift;
    reg rx_meta;
    reg rx_sync;

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
            rx_meta <= 1'b0;
            rx_sync <= 1'b0;
        end
        else begin
            rx_meta <= arinc_rx;
            rx_sync <= rx_meta;
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            state        <= ST_IDLE;
            clk_count    <= {COUNT_WIDTH{1'b0}};
            bit_index    <= 6'd0;
            rx_shift     <= 32'd0;
            rx_word      <= 32'd0;
            rx_valid     <= 1'b0;
            parity_error <= 1'b0;
            rx_busy      <= 1'b0;
        end
        else begin
            rx_valid <= 1'b0;

            case (state)
                ST_IDLE: begin
                    rx_busy   <= 1'b0;
                    clk_count <= {COUNT_WIDTH{1'b0}};
                    bit_index <= 6'd0;
                    rx_shift  <= 32'd0;

                    if (rx_start) begin
                        rx_word      <= 32'd0;
                        parity_error <= 1'b0;
                        rx_busy      <= 1'b1;
                        clk_count    <= {COUNT_WIDTH{1'b0}};
                        bit_index    <= 6'd0;
                        state        <= ST_FIRST;
                    end
                end

                ST_FIRST: begin
                    rx_busy <= 1'b1;
                    if (clk_count == HALF_CYCLES - 1) begin
                        rx_shift[0] <= rx_sync;
                        clk_count   <= {COUNT_WIDTH{1'b0}};
                        bit_index   <= 6'd1;
                        state       <= ST_RECEIVE;
                    end
                    else begin
                        clk_count <= clk_count + 1'b1;
                    end
                end

                ST_RECEIVE: begin
                    rx_busy <= 1'b1;
                    if (clk_count == CYCLES_PER_BIT - 1) begin
                        rx_shift[bit_index] <= rx_sync;
                        clk_count <= {COUNT_WIDTH{1'b0}};
                        if (bit_index == 6'd31)
                            state <= ST_DONE;
                        else
                            bit_index <= bit_index + 1'b1;
                    end
                    else begin
                        clk_count <= clk_count + 1'b1;
                    end
                end

                ST_DONE: begin
                    rx_word[7:0]    <= {rx_shift[0], rx_shift[1], rx_shift[2], rx_shift[3],
                                         rx_shift[4], rx_shift[5], rx_shift[6], rx_shift[7]};
                    rx_word[9:8]    <= rx_shift[9:8];
                    rx_word[28:10]  <= rx_shift[28:10];
                    rx_word[30:29]  <= rx_shift[30:29];
                    rx_word[31]    <= rx_shift[31];
                    parity_error   <= (^rx_shift != 1'b1);
                    rx_valid       <= 1'b1;
                    rx_busy        <= 1'b0;
                    state          <= ST_IDLE;
                end

                default: begin
                    state        <= ST_IDLE;
                    clk_count    <= {COUNT_WIDTH{1'b0}};
                    bit_index    <= 6'd0;
                    rx_shift     <= 32'd0;
                    rx_word      <= 32'd0;
                    rx_valid     <= 1'b0;
                    parity_error <= 1'b0;
                    rx_busy      <= 1'b0;
                end
            endcase
        end
    end
endmodule
