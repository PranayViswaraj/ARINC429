`timescale 1ns/1ps
/*=============================================================================
 * tb_arinc429_controller - REVIEW-1 REGRESSION COPY (MINIMALLY FIXED)
 *
 * DUT under test : arinc429_controller (UNMODIFIED Review-1 RTL)
 *
 * Audit finding B1 (does not elaborate): the original file uses
 * "faults_detected" (fault_test, summary) but only declares
 * "faults_undetected". iverilog/XSim elaboration error:
 *   "Could not find variable faults_detected". FIX: declare and init it.
 *
 * Audit finding A2 (stale read at reset edge): reset_during_operation
 * sampled DUT outputs at the SAME posedge at which the synchronous reset's
 * nonblocking updates were scheduled. FIX: sample at the following negedge.
 * No DUT file is modified by this regression copy.
 *===========================================================================*/

module tb_arinc429_controller;

    localparam integer CLK_FREQ_HZ    = 50000000;
    localparam integer ARINC_BAUD     = 100000;
    localparam integer INTERWORD_BITS = 4;
    localparam integer CYCLES_PER_BIT = CLK_FREQ_HZ / ARINC_BAUD;
    localparam integer CLK_PERIOD_NS  = 20;

    reg clk;
    reg rst;
    reg tx_start;
    reg [7:0] label;
    reg [1:0] sdi;
    reg [18:0] data;
    reg [1:0] ssm;
    wire tx_busy;
    wire tx_done;

    reg rx_start;
    wire [31:0] rx_word;
    wire rx_valid;
    wire parity_error;
    wire rx_busy;

    wire arinc_tx;
    reg arinc_rx_ext;
    reg loopback_enable;

    integer tx_done_count;
    integer rx_valid_count;
    integer total_tests;
    integer passed_tests;
    integer failed_tests;
    integer fault_tests;
    integer single_bit_faults;
    integer single_bit_detected;
    integer parity_faults;
    integer parity_detected;
    integer faults_undetected;
    integer faults_detected;      /* FIX B1: was used but never declared in the original */
    integer two_bit_faults;
    integer two_bit_undetected;
    integer expected_limitations;
    integer tx_done_width_failures;
    integer rx_valid_width_failures;
    integer tx_done_rise_time;
    integer rx_valid_rise_time;
    reg tx_done_prev;             /* FIX A3: filter X->0 startup artifact */
    reg rx_valid_prev;

    arinc429_controller #(
        .CLK_FREQ_HZ(CLK_FREQ_HZ),
        .ARINC_BAUD(ARINC_BAUD),
        .INTERWORD_BITS(INTERWORD_BITS)
    ) dut (
        .clk(clk),
        .rst(rst),
        .tx_start(tx_start),
        .label(label),
        .sdi(sdi),
        .data(data),
        .ssm(ssm),
        .tx_busy(tx_busy),
        .tx_done(tx_done),
        .rx_start(rx_start),
        .rx_word(rx_word),
        .rx_valid(rx_valid),
        .parity_error(parity_error),
        .rx_busy(rx_busy),
        .arinc_tx(arinc_tx),
        .arinc_rx_ext(arinc_rx_ext),
        .loopback_enable(loopback_enable)
    );

    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD_NS/2) clk = ~clk;
    end

    always @(posedge tx_done) begin
        tx_done_count = tx_done_count + 1;
        tx_done_rise_time = $time;
        tx_done_prev = 1'b1;
    end

    always @(negedge tx_done) begin
        /* FIX A3: only a 1->0 fall of a real pulse is measured. */
        if (tx_done_prev === 1'b1) begin
            if (($time - tx_done_rise_time) != CLK_PERIOD_NS)
                tx_done_width_failures = tx_done_width_failures + 1;
        end
        tx_done_prev = 1'b0;
    end

    always @(posedge rx_valid) begin
        rx_valid_count = rx_valid_count + 1;
        rx_valid_rise_time = $time;
        rx_valid_prev = 1'b1;
    end

    always @(negedge rx_valid) begin
        if (rx_valid_prev === 1'b1) begin
            if (($time - rx_valid_rise_time) != CLK_PERIOD_NS)
                rx_valid_width_failures = rx_valid_width_failures + 1;
        end
        rx_valid_prev = 1'b0;
    end

    function [31:0] build_word;
        input [7:0] f_label;
        input [1:0] f_sdi;
        input [18:0] f_data;
        input [1:0] f_ssm;
        reg parity;
        begin
            parity = ~^{f_label, f_sdi, f_data, f_ssm};
            build_word = {parity, f_ssm, f_data, f_sdi, f_label};
        end
    endfunction

    function [31:0] build_serial;
        input [7:0] f_label;
        input [1:0] f_sdi;
        input [18:0] f_data;
        input [1:0] f_ssm;
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

    task wait_events;
        input integer tx_before;
        input integer rx_before;
        integer n;
        begin
            n = 0;
            while (((tx_done_count == tx_before) || (rx_valid_count == rx_before)) &&
                   (n < 25000)) begin
                @(posedge clk);
                n = n + 1;
            end
        end
    endtask

    task start_tx_word;
        input [7:0] f_label;
        input [1:0] f_sdi;
        input [18:0] f_data;
        input [1:0] f_ssm;
        begin
            @(negedge clk);
            label = f_label;
            sdi = f_sdi;
            data = f_data;
            ssm = f_ssm;
            tx_start = 1'b1;
            @(negedge clk);
            tx_start = 1'b0;
        end
    endtask

    task start_rx;
        begin
            @(negedge clk);
            rx_start = 1'b1;
            @(negedge clk);
            rx_start = 1'b0;
        end
    endtask

    task drive_external_word;
        input [7:0] f_label;
        input [1:0] f_sdi;
        input [18:0] f_data;
        input [1:0] f_ssm;
        input integer fault_a;
        input integer fault_b;
        reg [31:0] serial_word;
        integer i;
        begin
            serial_word = build_serial(f_label, f_sdi, f_data, f_ssm);
            if (fault_a >= 0) serial_word[fault_a] = ~serial_word[fault_a];
            if (fault_b >= 0) serial_word[fault_b] = ~serial_word[fault_b];

            @(negedge clk);
            arinc_rx_ext = serial_word[0];
            rx_start = 1'b1;
            @(negedge clk);
            rx_start = 1'b0;
            repeat (CYCLES_PER_BIT-1) @(negedge clk);
            for (i = 1; i < 32; i = i + 1) begin
                arinc_rx_ext = serial_word[i];
                repeat (CYCLES_PER_BIT) @(negedge clk);
            end
            arinc_rx_ext = 1'b0;
        end
    endtask

    task normal_loopback_test;
        input [7:0] f_label;
        input [1:0] f_sdi;
        input [18:0] f_data;
        input [1:0] f_ssm;
        input [255:0] name;
        integer tx_before;
        integer rx_before;
        integer n;
        reg fail;
        begin
            total_tests = total_tests + 1;
            fail = 1'b0;
            tx_before = tx_done_count;
            rx_before = rx_valid_count;
            loopback_enable = 1'b1;
            arinc_rx_ext = 1'b0;
            start_rx;
            start_tx_word(f_label, f_sdi, f_data, f_ssm);
            wait_events(tx_before, rx_before);

            n = 0;
            while ((tx_done_count == tx_before || rx_valid_count == rx_before) && (n < 10)) begin
                @(posedge clk);
                n = n + 1;
            end

            if (tx_done_count != tx_before+1) fail = 1'b1;
            if (rx_valid_count != rx_before+1) fail = 1'b1;
            if (rx_word !== build_word(f_label,f_sdi,f_data,f_ssm)) fail = 1'b1;
            if (parity_error !== 1'b0) fail = 1'b1;

            if (fail) begin
                failed_tests = failed_tests + 1;
                $display("FAIL [%0s]", name);
            end
            else begin
                passed_tests = passed_tests + 1;
                $display("PASS [%0s] word=%h", name, build_word(f_label,f_sdi,f_data,f_ssm));
            end
        end
    endtask

    task normal_external_test;
        input [7:0] f_label;
        input [1:0] f_sdi;
        input [18:0] f_data;
        input [1:0] f_ssm;
        input [255:0] name;
        integer rx_before;
        integer n;
        reg fail;
        begin
            total_tests = total_tests + 1;
            fail = 1'b0;
            rx_before = rx_valid_count;
            loopback_enable = 1'b0;
            drive_external_word(f_label,f_sdi,f_data,f_ssm,-1,-1);
            n = 0;
            while ((rx_valid_count == rx_before) && (n < 20000)) begin
                @(posedge clk);
                n = n + 1;
            end
            if (rx_valid_count != rx_before+1) fail = 1'b1;
            if (rx_word !== build_word(f_label,f_sdi,f_data,f_ssm)) fail = 1'b1;
            if (parity_error !== 1'b0) fail = 1'b1;
            if (fail) begin failed_tests=failed_tests+1; $display("FAIL [%0s]",name); end
            else begin passed_tests=passed_tests+1; $display("PASS [%0s]",name); end
        end
    endtask

    task fault_test;
        input integer fault_a;
        input integer fault_b;
        input [255:0] name;
        integer rx_before;
        integer n;
        reg [31:0] expected;
        reg fail;
        begin
            total_tests = total_tests + 1;
            fault_tests = fault_tests + 1;
            expected = build_word(8'h5A,2'b01,19'h2AAAA,2'b10);
            rx_before = rx_valid_count;
            fail = 1'b0;
            loopback_enable = 1'b0;
            if (fault_b < 0) begin
                if (fault_a == 31) parity_faults = parity_faults + 1;
                else single_bit_faults = single_bit_faults + 1;
            end
            else begin
                two_bit_faults = two_bit_faults + 1;
            end

            drive_external_word(8'h5A,2'b01,19'h2AAAA,2'b10,fault_a,fault_b);
            n = 0;
            while ((rx_valid_count == rx_before) && (n < 20000)) begin
                @(posedge clk);
                n = n + 1;
            end

            if (rx_valid_count != rx_before+1) begin
                fail = 1'b1;
                $display("FAIL [%0s]: rx_valid timeout.", name);
            end
            else if (fault_b < 0) begin
                if ((rx_word !== expected) && (parity_error === 1'b1)) begin
                    faults_detected = faults_detected + 1;
                    if (fault_a == 31) parity_detected = parity_detected + 1;
                    else single_bit_detected = single_bit_detected + 1;
                    $display("PASS [%0s]: single-bit fault detected.", name);
                end
                else begin
                    faults_undetected = faults_undetected + 1;
                    fail = 1'b1;
                    $display("FAIL [%0s]: single-bit fault not correctly detected.", name);
                end
            end
            else begin
                if ((rx_word !== expected) && (parity_error === 1'b0)) begin
                    faults_undetected = faults_undetected + 1;
                    two_bit_undetected = two_bit_undetected + 1;
                    expected_limitations = expected_limitations + 1;
                    $display("EXPECTED LIMITATION [%0s]: two-bit error escaped odd parity.", name);
                end
                else begin
                    fail = 1'b1;
                    $display("FAIL [%0s]: unexpected two-bit result.", name);
                end
            end

            if (fail) failed_tests = failed_tests + 1;
            else passed_tests = passed_tests + 1;
        end
    endtask

    task source_latch_test;
        integer rx_before;
        integer n;
        integer i;
        reg [31:0] serial_word;
        reg fail;
        begin
            total_tests = total_tests + 1;
            rx_before = rx_valid_count;
            fail = 1'b0;
            serial_word = build_serial(8'hD3,2'b10,19'h13579,2'b01);
            loopback_enable = 1'b0;

            @(negedge clk);
            arinc_rx_ext = serial_word[0];
            rx_start = 1'b1;
            @(negedge clk);
            rx_start = 1'b0;
            while (!rx_busy) @(posedge clk);

            repeat (CYCLES_PER_BIT-1) @(negedge clk);
            for (i=1; i<32; i=i+1) begin
                if (i == 10)
                    loopback_enable = 1'b1;
                arinc_rx_ext = serial_word[i];
                repeat (CYCLES_PER_BIT) @(negedge clk);
            end
            arinc_rx_ext = 1'b0;

            n = 0;
            while ((rx_valid_count == rx_before) && (n < 20000)) begin
                @(posedge clk);
                n = n + 1;
            end
            if (rx_valid_count != rx_before+1) fail = 1'b1;
            if (rx_word !== build_word(8'hD3,2'b10,19'h13579,2'b01)) fail = 1'b1;
            if (parity_error !== 1'b0) fail = 1'b1;

            if (fail) begin failed_tests=failed_tests+1; $display("FAIL [RX_SOURCE_LATCH]"); end
            else begin passed_tests=passed_tests+1; $display("PASS [RX_SOURCE_LATCH]"); end
        end
    endtask

    task busy_input_test;
        integer tx_before;
        integer rx_before;
        integer n;
        reg fail;
        begin
            total_tests = total_tests + 1;
            tx_before = tx_done_count;
            rx_before = rx_valid_count;
            fail = 1'b0;
            loopback_enable = 1'b1;
            start_rx;
            start_tx_word(8'hAA,2'b00,19'h00AAA,2'b00);
            while (!tx_busy) @(posedge clk);
            repeat (5*CYCLES_PER_BIT) @(posedge clk);
            @(negedge clk);
            label=8'h55; sdi=2'b11; data=19'h05555; ssm=2'b11;
            tx_start=1'b1;
            @(negedge clk);
            tx_start=1'b0;

            n=0;
            while (((tx_done_count==tx_before)||(rx_valid_count==rx_before)) && (n<25000)) begin
                @(posedge clk);
                n=n+1;
            end
            if (tx_done_count != tx_before+1) fail=1'b1;
            if (rx_valid_count != rx_before+1) fail=1'b1;
            if (rx_word !== build_word(8'hAA,2'b00,19'h00AAA,2'b00)) fail=1'b1;
            if (parity_error !== 1'b0) fail=1'b1;

            repeat (CYCLES_PER_BIT+20) @(posedge clk);
            if (tx_done_count != tx_before+1) fail=1'b1;
            if (rx_valid_count != rx_before+1) fail=1'b1;

            if (fail) begin failed_tests=failed_tests+1; $display("FAIL [BUSY_INPUT_LATCH]"); end
            else begin passed_tests=passed_tests+1; $display("PASS [BUSY_INPUT_LATCH]"); end
        end
    endtask

    task reset_during_operation;
        reg fail;
        begin
            total_tests = total_tests + 1;
            fail = 1'b0;
            loopback_enable = 1'b1;
            start_rx;
            start_tx_word(8'hCC,2'b10,19'h00CCC,2'b10);
            while (!tx_busy) @(posedge clk);
            repeat (10*CYCLES_PER_BIT) @(posedge clk);
            @(negedge clk);
            rst = 1'b1;
            @(posedge clk);          /* FIX A2: synchronous reset applies at this edge */
            @(negedge clk);          /* FIX A2: sample settled outputs */
            if ((tx_busy !== 1'b0) || (tx_done !== 1'b0) ||
                (rx_busy !== 1'b0) || (rx_valid !== 1'b0) ||
                (parity_error !== 1'b0) || (rx_word !== 32'd0)) fail=1'b1;
            rst = 1'b0;
            if (fail) begin failed_tests=failed_tests+1; $display("FAIL [RESET_DURING_OPERATION]"); end
            else begin passed_tests=passed_tests+1; $display("PASS [RESET_DURING_OPERATION]"); end
        end
    endtask

    initial begin
        tx_done_count=0;
        rx_valid_count=0;
        total_tests=0;
        passed_tests=0;
        failed_tests=0;
        fault_tests=0;
        single_bit_faults=0;
        single_bit_detected=0;
        parity_faults=0;
        parity_detected=0;
        faults_undetected=0;
        faults_detected=0;        /* FIX B1 */
        two_bit_faults=0;
        two_bit_undetected=0;
        expected_limitations=0;
        tx_done_width_failures=0;
        rx_valid_width_failures=0;
        tx_done_rise_time=0;
        rx_valid_rise_time=0;
        tx_done_prev=1'b0;
        rx_valid_prev=1'b0;

        rst=1'b1;
        tx_start=1'b0;
        rx_start=1'b0;
        label=8'h00;
        sdi=2'b00;
        data=19'h00000;
        ssm=2'b00;
        arinc_rx_ext=1'b0;
        loopback_enable=1'b1;

        repeat (5) @(negedge clk);
        rst=1'b0;
        repeat (2) @(negedge clk);

        total_tests=total_tests+1;
        if ((tx_busy!==1'b0)||(tx_done!==1'b0)||(rx_busy!==1'b0)||
            (rx_valid!==1'b0)||(parity_error!==1'b0)||(rx_word!==32'd0)) begin
            failed_tests=failed_tests+1;
            $display("FAIL [INITIAL_RESET]");
        end
        else begin
            passed_tests=passed_tests+1;
            $display("PASS [INITIAL_RESET]");
        end

        normal_loopback_test(8'h01,2'b00,19'h00001,2'b00,"LOOPBACK_1");
        normal_loopback_test(8'h02,2'b01,19'h00002,2'b01,"LOOPBACK_2");
        normal_loopback_test(8'hFF,2'b11,19'h7FFFF,2'b11,"LOOPBACK_MAX");
        normal_external_test(8'h50,2'b01,19'h01234,2'b00,"EXTERNAL_RX");

        fault_test(31,-1,"PARITY_FAULT");
        fault_test(15,-1,"DATA_FAULT");
        fault_test(3,-1,"LABEL_FAULT");
        fault_test(8,-1,"SDI_FAULT");
        fault_test(29,-1,"SSM_FAULT");
        fault_test(10,20,"TWO_BIT_FAULT");

        source_latch_test;
        busy_input_test;
        reset_during_operation;
        normal_loopback_test(8'h99,2'b00,19'h00999,2'b00,"POST_RESET_RECOVERY");

        $display("");
        $display("============================================================");
        $display("ARINC 429 CONTROLLER - REVIEW 1 VERIFICATION SUMMARY");
        $display("============================================================");
        $display("Total tests           = %0d", total_tests);
        $display("Passed                = %0d", passed_tests);
        $display("Failed                = %0d", failed_tests);
        $display("Fault tests           = %0d", fault_tests);
        $display("Single-bit faults     = %0d", single_bit_faults);
        $display("Single-bit detected   = %0d", single_bit_detected);
        $display("Parity-bit faults     = %0d", parity_faults);
        $display("Parity-bit detected   = %0d", parity_detected);
        $display("Two-bit faults        = %0d", two_bit_faults);
        $display("Two-bit undetected    = %0d", two_bit_undetected);
        $display("Faults detected       = %0d", faults_detected);
        $display("Faults undetected     = %0d", faults_undetected);
        $display("Expected limitations  = %0d", expected_limitations);
        $display("tx_done width errors  = %0d", tx_done_width_failures);
        $display("rx_valid width errors = %0d", rx_valid_width_failures);
        $display("CYCLES_PER_BIT        = %0d", CYCLES_PER_BIT);
        $display("DATA_CYCLES           = %0d", 32*CYCLES_PER_BIT);
        $display("GAP_CYCLES            = %0d", INTERWORD_BITS*CYCLES_PER_BIT);
        $display("TOTAL_CYCLES          = %0d", (32+INTERWORD_BITS)*CYCLES_PER_BIT);
        $display("============================================================");
        if ((failed_tests == 0) &&
            (passed_tests == total_tests) &&
            (tx_done_width_failures == 0) &&
            (rx_valid_width_failures == 0) &&
            (total_tests == passed_tests + failed_tests))
            $display("OVERALL RESULT = PASS");
        else
            $display("OVERALL RESULT = FAIL");
        $display("============================================================");
        $finish;
    end

    initial begin
        #200000000;
        $display("ERROR: Controller testbench timeout.");
        $finish;
    end

endmodule
