`timescale 1ns/1ps

module arinc429_controller #(
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
    output wire        tx_busy,
    output wire        tx_done,
    input  wire        rx_start,
    output wire [31:0] rx_word,
    output wire        rx_valid,
    output wire        parity_error,
    output wire        rx_busy,
    output wire        arinc_tx,
    input  wire        arinc_rx_ext,
    input  wire        loopback_enable
);

    wire arinc_tx_internal;
    wire arinc_rx_selected;
    reg  rx_source_latched;
    reg  rx_source_active;

    assign arinc_rx_selected =
        rx_source_active ?
            (rx_source_latched ? arinc_tx_internal : arinc_rx_ext) :
            (loopback_enable ? arinc_tx_internal : arinc_rx_ext);

    always @(posedge clk) begin
        if (rst) begin
            rx_source_latched <= 1'b0;
            rx_source_active  <= 1'b0;
        end
        else begin
            if (rx_start && !rx_source_active) begin
                rx_source_latched <= loopback_enable;
                rx_source_active  <= 1'b1;
            end
            if (rx_valid)
                rx_source_active <= 1'b0;
        end
    end

    arinc429_tx #(
        .CLK_FREQ_HZ(CLK_FREQ_HZ),
        .ARINC_BAUD(ARINC_BAUD),
        .INTERWORD_BITS(INTERWORD_BITS)
    ) u_tx (
        .clk(clk),
        .rst(rst),
        .tx_start(tx_start),
        .label(label),
        .sdi(sdi),
        .data(data),
        .ssm(ssm),
        .tx_data(arinc_tx_internal),
        .tx_busy(tx_busy),
        .tx_done(tx_done)
    );

    arinc429_rx #(
        .CLK_FREQ_HZ(CLK_FREQ_HZ),
        .ARINC_BAUD(ARINC_BAUD)
    ) u_rx (
        .clk(clk),
        .rst(rst),
        .arinc_rx(arinc_rx_selected),
        .rx_start(rx_start),
        .rx_word(rx_word),
        .rx_valid(rx_valid),
        .parity_error(parity_error),
        .rx_busy(rx_busy)
    );

    assign arinc_tx = arinc_tx_internal;
endmodule
