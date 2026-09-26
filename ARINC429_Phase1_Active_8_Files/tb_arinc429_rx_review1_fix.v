`timescale 1ns/1ps
/*=============================================================================
 * tb_arinc429_rx  -  REVIEW-1 REGRESSION COPY (MINIMALLY FIXED)
 *
 * DUT under test : arinc429_rx (UNMODIFIED Review-1 RTL)
 *
 * Audit finding A2 (stale read at reset edge): the original
 * test_reset_during_rx sampled DUT outputs at the SAME posedge at which the
 * synchronous reset's nonblocking updates were scheduled, reading pre-reset
 * values (rx_busy still 1) -> false FAIL. FIX: sample at the following
 * negedge. All other tasks are unchanged and pass unmodified.
 * No DUT file is modified by this regression copy.
 *===========================================================================*/

module tb_arinc429_rx;

    localparam integer CLK_FREQ_HZ   = 50000000;
    localparam integer ARINC_BAUD    = 100000;
    localparam integer CYCLES_PER_BIT = CLK_FREQ_HZ / ARINC_BAUD;
    localparam integer CLK_PERIOD_NS  = 20;

    reg clk;
    reg rst;
    reg arinc_rx;
    reg rx_start;

    wire [31:0] rx_word;
    wire rx_valid;
    wire parity_error;
    wire rx_busy;

    integer rx_valid_count;
    integer total_tests;
    integer passed_tests;
    integer failed_tests;
    integer normal_tests;
    integer normal_passed;
    integer normal_failed;
    integer fault_tests;
    integer single_bit_faults;
    integer single_bit_detected;
    integer parity_faults;
    integer parity_detected;
    integer two_bit_faults;
    integer two_bit_undetected;
    integer rx_valid_width_failures;
    integer rx_valid_rise_time;
    reg rx_valid_prev;            /* FIX A3: filter X->0 startup artifact */

    arinc429_rx #(
        .CLK_FREQ_HZ(CLK_FREQ_HZ),
        .ARINC_BAUD(ARINC_BAUD)
    ) dut (
        .clk(clk),
        .rst(rst),
        .arinc_rx(arinc_rx),
        .rx_start(rx_start),
        .rx_word(rx_word),
        .rx_valid(rx_valid),
        .parity_error(parity_error),
        .rx_busy(rx_busy)
    );

    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD_NS/2) clk = ~clk;
    end

    always @(posedge rx_valid) begin
        rx_valid_count = rx_valid_count + 1;
        rx_valid_rise_time = $time;
        rx_valid_prev = 1'b1;
    end

    always @(negedge rx_valid) begin
        /* FIX A3: only a 1->0 fall of a real pulse is measured. */
        if (rx_valid_prev === 1'b1) begin
            if (($time - rx_valid_rise_time) != CLK_PERIOD_NS)
                rx_valid_width_failures = rx_valid_width_failures + 1;
        end
        rx_valid_prev = 1'b0;
    end

    function [31:0] build_word;
        input [7:0]  f_label;
        input [1:0]  f_sdi;
        input [18:0] f_data;
        input [1:0]  f_ssm;
        reg parity;
        begin
            parity = ~^{f_label, f_sdi, f_data, f_ssm};
            build_word = {parity, f_ssm, f_data, f_sdi, f_label};
        end
    endfunction

    function [31:0] build_serial;
        input [7:0]  f_label;
        input [1:0]  f_sdi;
        input [18:0] f_data;
        input [1:0]  f_ssm;
        reg parity;
        begin
            parity = ~^{f_label, f_sdi, f_data, f_ssm};
            build_serial[0]  = f_label[7];
            build_serial[1]  = f_label[6];
            build_serial[2]  = f_label[5];
            build_serial[3]  = f_label[4];
            build_serial[4]  = f_label[3];
            build_serial[5]  = f_label[2];
            build_serial[6]  = f_label[1];
            build_serial[7]  = f_label[0];
            build_serial[8]  = f_sdi[0];
            build_serial[9]  = f_sdi[1];
            build_serial[10] = f_data[0];
            build_serial[11] = f_data[1];
            build_serial[12] = f_data[2];
            build_serial[13] = f_data[3];
            build_serial[14] = f_data[4];
            build_serial[15] = f_data[5];
            build_serial[16] = f_data[6];
            build_serial[17] = f_data[7];
            build_serial[18] = f_data[8];
            build_serial[19] = f_data[9];
            build_serial[20] = f_data[10];
            build_serial[21] = f_data[11];
            build_serial[22] = f_data[12];
            build_serial[23] = f_data[13];
            build_serial[24] = f_data[14];
            build_serial[25] = f_data[15];
            build_serial[26] = f_data[16];
            build_serial[27] = f_data[17];
            build_serial[28] = f_data[18];
            build_serial[29] = f_ssm[0];
            build_serial[30] = f_ssm[1];
            build_serial[31] = parity;
        end
    endfunction

    task drive_word;
        input [7:0]  f_label;
        input [1:0]  f_sdi;
        input [18:0] f_data;
        input [1:0]  f_ssm;
        input        fault1_enable;
        input [4:0]  fault1_bit;
        input        fault2_enable;
        input [4:0]  fault2_bit;
        reg [31:0] serial_word;
        integer i;
        begin
            serial_word = build_serial(f_label, f_sdi, f_data, f_ssm);
            if (fault1_enable)
                serial_word[fault1_bit] = ~serial_word[fault1_bit];
            if (fault2_enable)
                serial_word[fault2_bit] = ~serial_word[fault2_bit];

            @(negedge clk);
            arinc_rx = serial_word[0];
            rx_start = 1'b1;
            @(negedge clk);
            rx_start = 1'b0;

            repeat (CYCLES_PER_BIT-1) @(negedge clk);
            for (i = 1; i < 32; i = i + 1) begin
                arinc_rx = serial_word[i];
                repeat (CYCLES_PER_BIT) @(negedge clk);
            end
            arinc_rx = 1'b0;
        end
    endtask

    task wait_rx_done;
        input integer count_before;
        integer wait_count;
        begin
            wait_count = 0;
            while ((rx_valid_count == count_before) && (wait_count < 20000)) begin
                @(posedge clk);
                wait_count = wait_count + 1;
            end
        end
    endtask

    task test_normal;
        input [7:0] f_label;
        input [1:0] f_sdi;
        input [18:0] f_data;
        input [1:0] f_ssm;
        input [255:0] f_name;
        integer before_count;
        reg fail;
        begin
            total_tests = total_tests + 1;
            normal_tests = normal_tests + 1;
            before_count = rx_valid_count;
            fail = 1'b0;

            drive_word(f_label, f_sdi, f_data, f_ssm,
                       1'b0, 5'd0, 1'b0, 5'd0);
            wait_rx_done(before_count);

            if (rx_valid_count != before_count + 1) begin
                fail = 1'b1;
                $display("FAIL [%0s]: rx_valid timeout.", f_name);
            end
            if (rx_word !== build_word(f_label, f_sdi, f_data, f_ssm)) begin
                fail = 1'b1;
                $display("FAIL [%0s]: received word mismatch. got=%h expected=%h.",
                         f_name, rx_word, build_word(f_label, f_sdi, f_data, f_ssm));
            end
            if (parity_error !== 1'b0) begin
                fail = 1'b1;
                $display("FAIL [%0s]: parity_error asserted on valid word.", f_name);
            end

            if (fail) begin
                failed_tests = failed_tests + 1;
                normal_failed = normal_failed + 1;
                $display("FAIL [%0s]", f_name);
            end
            else begin
                passed_tests = passed_tests + 1;
                normal_passed = normal_passed + 1;
                $display("PASS [%0s] word=%h", f_name,
                         build_word(f_label, f_sdi, f_data, f_ssm));
            end
        end
    endtask

    task test_single_bit_fault;
        input integer fault_bit_i;
        input [255:0] f_name;
        integer before_count;
        reg fail;
        reg [31:0] expected_word;
        begin
            total_tests = total_tests + 1;
            fault_tests = fault_tests + 1;
            before_count = rx_valid_count;
            expected_word = build_word(8'h5A, 2'b01, 19'h2AAAA, 2'b10);
            fail = 1'b0;

            if (fault_bit_i == 31)
                parity_faults = parity_faults + 1;
            else
                single_bit_faults = single_bit_faults + 1;

            drive_word(8'h5A, 2'b01, 19'h2AAAA, 2'b10,
                       1'b1, fault_bit_i[4:0], 1'b0, 5'd0);
            wait_rx_done(before_count);

            if (rx_valid_count != before_count + 1) begin
                fail = 1'b1;
                $display("FAIL [%0s]: rx_valid timeout.", f_name);
            end
            else if ((rx_word === expected_word) || (parity_error !== 1'b1)) begin
                fail = 1'b1;
                $display("FAIL [%0s]: single-bit fault not detected.", f_name);
            end
            else if (fault_bit_i == 31) begin
                parity_detected = parity_detected + 1;
            end
            else begin
                single_bit_detected = single_bit_detected + 1;
            end

            if (fail) begin
                failed_tests = failed_tests + 1;
                $display("FAIL [%0s]", f_name);
            end
            else begin
                passed_tests = passed_tests + 1;
                $display("PASS [%0s] detected bit %0d", f_name, fault_bit_i);
            end
        end
    endtask

    task test_two_bit_fault;
        input integer bit_a;
        input integer bit_b;
        input [255:0] f_name;
        integer before_count;
        reg fail;
        reg [31:0] expected_word;
        begin
            total_tests = total_tests + 1;
            fault_tests = fault_tests + 1;
            two_bit_faults = two_bit_faults + 1;
            before_count = rx_valid_count;
            expected_word = build_word(8'h5A, 2'b01, 19'h2AAAA, 2'b10);
            fail = 1'b0;

            drive_word(8'h5A, 2'b01, 19'h2AAAA, 2'b10,
                       1'b1, bit_a[4:0], 1'b1, bit_b[4:0]);
            wait_rx_done(before_count);

            if (rx_valid_count != before_count + 1) begin
                fail = 1'b1;
                $display("FAIL [%0s]: rx_valid timeout.", f_name);
            end
            else if ((rx_word !== expected_word) && (parity_error === 1'b0)) begin
                two_bit_undetected = two_bit_undetected + 1;
                $display("EXPECTED LIMITATION [%0s]: two-bit error escaped odd parity.", f_name);
            end
            else begin
                fail = 1'b1;
                $display("FAIL [%0s]: unexpected two-bit result.", f_name);
            end

            if (fail) begin
                failed_tests = failed_tests + 1;
                $display("FAIL [%0s]", f_name);
            end
            else begin
                passed_tests = passed_tests + 1;
                $display("PASS [%0s]", f_name);
            end
        end
    endtask

    task test_reset_during_rx;
        integer before_count;
        reg [31:0] serial_word;
        reg fail;
        begin
            total_tests = total_tests + 1;
            before_count = rx_valid_count;
            fail = 1'b0;
            serial_word = build_serial(8'h33, 2'b01, 19'h01234, 2'b00);

            @(negedge clk);
            arinc_rx = serial_word[0];
            rx_start = 1'b1;
            @(negedge clk);
            rx_start = 1'b0;

            while (!rx_busy)
                @(posedge clk);
            repeat (10*CYCLES_PER_BIT) @(posedge clk);

            @(negedge clk);
            rst = 1'b1;
            @(posedge clk);          /* FIX A2: synchronous reset applies at this edge */
            @(negedge clk);          /* FIX A2: sample settled outputs */
            if ((rx_busy !== 1'b0) || (rx_valid !== 1'b0) ||
                (parity_error !== 1'b0) || (rx_word !== 32'd0)) begin
                fail = 1'b1;
                $display("FAIL [RESET_DURING_RX]: outputs not cleared.");
            end
            rst = 1'b0;
            arinc_rx = 1'b0;

            repeat (1000) @(posedge clk);
            if (rx_valid_count != before_count)
                fail = 1'b1;

            if (fail) begin
                failed_tests = failed_tests + 1;
                $display("FAIL [RESET_DURING_RX]");
            end
            else begin
                passed_tests = passed_tests + 1;
                $display("PASS [RESET_DURING_RX]");
            end
        end
    endtask

    initial begin
        rx_valid_count = 0;
        total_tests = 0;
        passed_tests = 0;
        failed_tests = 0;
        normal_tests = 0;
        normal_passed = 0;
        normal_failed = 0;
        fault_tests = 0;
        single_bit_faults = 0;
        single_bit_detected = 0;
        parity_faults = 0;
        parity_detected = 0;
        two_bit_faults = 0;
        two_bit_undetected = 0;
        rx_valid_width_failures = 0;
        rx_valid_rise_time = 0;
        rx_valid_prev = 1'b0;

        rst = 1'b1;
        arinc_rx = 1'b0;
        rx_start = 1'b0;
        repeat (5) @(negedge clk);
        rst = 1'b0;
        repeat (2) @(negedge clk);

        total_tests = total_tests + 1;
        if ((rx_word !== 32'd0) || (rx_valid !== 1'b0) ||
            (parity_error !== 1'b0) || (rx_busy !== 1'b0)) begin
            failed_tests = failed_tests + 1;
            $display("FAIL [RESET]");
        end
        else begin
            passed_tests = passed_tests + 1;
            $display("PASS [RESET]");
        end

        test_normal(8'h05,2'b01,19'h0ABCD,2'b00,"NORMAL_1");
        test_normal(8'hFF,2'b11,19'h7FFFF,2'b11,"NORMAL_MAX");
        test_normal(8'h00,2'b00,19'h00000,2'b00,"NORMAL_ZERO");
        test_normal(8'hAA,2'b01,19'h15555,2'b01,"NORMAL_ALT");

        test_single_bit_fault(0,  "FAULT_BIT_0");
        test_single_bit_fault(7,  "FAULT_LABEL_LSB");
        test_single_bit_fault(8,  "FAULT_SDI_0");
        test_single_bit_fault(9,  "FAULT_SDI_1");
        test_single_bit_fault(10, "FAULT_DATA_0");
        test_single_bit_fault(15, "FAULT_DATA_MID");
        test_single_bit_fault(28, "FAULT_DATA_18");
        test_single_bit_fault(29, "FAULT_SSM_0");
        test_single_bit_fault(30, "FAULT_SSM_1");
        test_single_bit_fault(31, "FAULT_PARITY");

        test_two_bit_fault(0, 1, "TWO_BIT_0_1");
        test_two_bit_fault(10, 20, "TWO_BIT_10_20");

        test_normal(8'h10, 2'b00, 19'h00001, 2'b00, "BACK_TO_BACK_1");
        test_normal(8'h20, 2'b00, 19'h00002, 2'b00, "BACK_TO_BACK_2");

        test_reset_during_rx;

        $display("");
        $display("============================================================");
        $display("ARINC 429 RX VERIFICATION SUMMARY");
        $display("============================================================");
        $display("Total tests              = %0d", total_tests);
        $display("Passed                   = %0d", passed_tests);
        $display("Failed                   = %0d", failed_tests);
        $display("Normal tests             = %0d", normal_tests);
        $display("Normal passed            = %0d", normal_passed);
        $display("Normal failed            = %0d", normal_failed);
        $display("Fault tests              = %0d", fault_tests);
        $display("Single-bit faults        = %0d", single_bit_faults);
        $display("Single-bit detected      = %0d", single_bit_detected);
        $display("Parity faults            = %0d", parity_faults);
        $display("Parity detected          = %0d", parity_detected);
        $display("Two-bit faults            = %0d", two_bit_faults);
        $display("Two-bit undetected       = %0d", two_bit_undetected);
        $display("rx_valid width failures  = %0d", rx_valid_width_failures);
        $display("CYCLES_PER_BIT            = %0d", CYCLES_PER_BIT);
        $display("============================================================");
        if ((failed_tests == 0) &&
            (passed_tests == total_tests) &&
            (rx_valid_width_failures == 0) &&
            (total_tests == passed_tests + failed_tests))
            $display("OVERALL RESULT = PASS");
        else
            $display("OVERALL RESULT = FAIL");
        $display("============================================================");
        $finish;
    end

    initial begin
        #100000000;
        $display("ERROR: RX testbench timeout.");
        $finish;
    end

endmodule
