`timescale 1ns/1ps
/*=============================================================================
 * tb_arinc429_tx  -  REVIEW-1 REGRESSION COPY (MINIMALLY FIXED)
 *
 * DUT under test : arinc429_tx (UNMODIFIED Review-1 RTL)
 *
 * Audit finding A1 (structural sampling-window bug, deterministic on any
 * IEEE-1364 simulator, confirmed by simulation under Icarus Verilog 12):
 *   The original verify_word/test_busy_and_latch waited for tx_busy with
 *   "while (!tx_busy) @(posedge clk);" AFTER de-asserting tx_start. Because
 *   tx_busy rises (NBA) at the posedge BETWEEN the tx_start set/clear
 *   negedges, that loop exited without consuming any wait, so every
 *   500-negedge sampling window started one negedge too late and its 500th
 *   check read the NEXT serial bit. Consequences: false bit errors, gap
 *   measured 39980 ns instead of 40000 ns, and in test_busy_and_latch the
 *   accumulated 32-negedge drift made "@(posedge tx_done)" MISS the single
 *   tx_done pulse -> infinite hang -> global watchdog.
 *   FIX: anchor windows to the protocol edge - tx_start is high for exactly
 *   one posedge; that posedge latches the word and drives bit 0. Each bit is
 *   then sampled on the 500 negedges following its load posedge.
 *
 * Audit finding A2 (stale read at reset edge):
 *   test_reset_during_tx sampled DUT outputs at the SAME posedge at which
 *   the synchronous reset's nonblocking updates were scheduled, reading
 *   pre-reset values. FIX: sample at the following negedge.
 *
 * No DUT file is modified by this regression copy.
 *===========================================================================*/

module tb_arinc429_tx;

    localparam integer CLK_FREQ_HZ    = 50000000;
    localparam integer ARINC_BAUD     = 100000;
    localparam integer INTERWORD_BITS = 4;
    localparam integer CYCLES_PER_BIT = CLK_FREQ_HZ / ARINC_BAUD;
    localparam integer DATA_BITS      = 32;
    localparam integer DATA_CYCLES    = DATA_BITS * CYCLES_PER_BIT;
    localparam integer GAP_CYCLES     = INTERWORD_BITS * CYCLES_PER_BIT;
    localparam integer TOTAL_CYCLES   = DATA_CYCLES + GAP_CYCLES;
    localparam integer CLK_PERIOD_NS  = 20;

    reg clk;
    reg rst;
    reg tx_start;
    reg [7:0] label;
    reg [1:0] sdi;
    reg [18:0] data;
    reg [1:0] ssm;

    wire tx_data;
    wire tx_busy;
    wire tx_done;

    integer tx_done_count;
    integer total_tests;
    integer passed_tests;
    integer failed_tests;
    integer bits_checked;
    integer bit_errors;
    integer timing_failures;
    integer gap_failures;
    integer tx_done_width_failures;
    integer tx_done_rise_time;
    integer tx_busy_rise_time;
    integer gap_start_time;
    reg tx_done_prev;             /* FIX A3: filter X->0 startup artifact */

    arinc429_tx #(
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
        .tx_data(tx_data),
        .tx_busy(tx_busy),
        .tx_done(tx_done)
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

    always @(posedge tx_busy) begin
        tx_busy_rise_time = $time;
    end

    always @(negedge tx_done) begin
        /* FIX A3: only a 1->0 fall of a real pulse is measured. The X->0
         * transition when reset first clears tx_done is not a pulse edge. */
        if (tx_done_prev === 1'b1) begin
            if (($time - tx_done_rise_time) != CLK_PERIOD_NS)
                tx_done_width_failures = tx_done_width_failures + 1;
        end
        tx_done_prev = 1'b0;
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

    task verify_word;
        input [7:0] f_label;
        input [1:0] f_sdi;
        input [18:0] f_data;
        input [1:0] f_ssm;
        input [255:0] f_name;
        reg [31:0] expected_serial;
        reg fail;
        integer i;
        integer done_before;
        integer wait_count;
        integer gap_duration;
        integer transaction_duration;
        begin
            total_tests = total_tests + 1;
            expected_serial = build_serial(f_label, f_sdi, f_data, f_ssm);
            fail = 1'b0;
            done_before = tx_done_count;

            @(negedge clk);
            label = f_label;
            sdi   = f_sdi;
            data  = f_data;
            ssm   = f_ssm;
            tx_start = 1'b1;
            @(posedge clk);           /* FIX A1: this posedge latches the word and drives bit 0 */

            /* FIX A1: bit k occupies exactly the 500 negedges that follow the
             * posedge which loads bit k. tx_start is cleared at the first
             * bit-0 NEGEDGE (never at a posedge -> no assignment race with
             * the DUT clock edge). tx_busy is checked on every negedge. */

            /* Each bit is checked at every negedge for the full 500-clock interval. */
            for (i = 0; i < DATA_BITS; i = i + 1) begin
                repeat (CYCLES_PER_BIT) begin
                    @(negedge clk);
                    if (i == 0)
                        tx_start = 1'b0;
                    bits_checked = bits_checked + 1;
                    if (tx_busy !== 1'b1) begin
                        timing_failures = timing_failures + 1;
                        $display("FAIL [%0s]: tx_busy dropped during bit %0d.", f_name, i);
                        fail = 1'b1;
                    end
                    if (tx_data !== expected_serial[i]) begin
                        bit_errors = bit_errors + 1;
                        $display("FAIL [%0s]: bit %0d expected %b got %b.",
                                 f_name, i, expected_serial[i], tx_data);
                        fail = 1'b1;
                    end
                end
            end

            /* The next rising edge is the first clock of the interword gap. */
            @(posedge clk);
            gap_start_time = $time;
            /* FIX A2 discipline: state checks sample settled values at negedges. */
            @(negedge clk);
            if ((tx_data !== 1'b0) || (tx_busy !== 1'b1)) begin
                gap_failures = gap_failures + 1;
                $display("FAIL [%0s]: gap did not start with tx_data=0 and tx_busy=1.", f_name);
                fail = 1'b1;
            end

            /* Verify the complete gap is continuously held at zero and busy. */
            repeat (GAP_CYCLES - 1) begin
                @(negedge clk);
                if ((tx_data !== 1'b0) || (tx_busy !== 1'b1)) begin
                    gap_failures = gap_failures + 1;
                    $display("FAIL [%0s]: invalid gap state at time %0t ns.", f_name, $time);
                    fail = 1'b1;
                end
            end

            /* tx_done is expected exactly at the end of the gap. */
            wait_count = 0;
            while ((tx_done_count == done_before) && (wait_count < 1000)) begin
                @(posedge clk);
                wait_count = wait_count + 1;
            end

            if (tx_done_count != done_before + 1) begin
                $display("FAIL [%0s]: expected exactly one tx_done, got %0d.",
                         f_name, tx_done_count - done_before);
                fail = 1'b1;
            end

            @(negedge clk);           /* FIX A2: sample settled tx_busy */
            if (tx_busy !== 1'b0) begin
                $display("FAIL [%0s]: tx_busy did not clear at completion.", f_name);
                fail = 1'b1;
            end

            gap_duration = tx_done_rise_time - gap_start_time;
            transaction_duration = tx_done_rise_time - tx_busy_rise_time;

            if (gap_duration != (GAP_CYCLES * CLK_PERIOD_NS)) begin
                gap_failures = gap_failures + 1;
                $display("FAIL [%0s]: gap duration expected %0d ns, got %0d ns.",
                         f_name, GAP_CYCLES * CLK_PERIOD_NS, gap_duration);
                fail = 1'b1;
            end

            if (transaction_duration != (TOTAL_CYCLES * CLK_PERIOD_NS)) begin
                timing_failures = timing_failures + 1;
                $display("FAIL [%0s]: transaction duration expected %0d ns, got %0d ns.",
                         f_name, TOTAL_CYCLES * CLK_PERIOD_NS, transaction_duration);
                fail = 1'b1;
            end

            if (fail) begin
                failed_tests = failed_tests + 1;
                $display("FAIL [%0s]", f_name);
            end
            else begin
                passed_tests = passed_tests + 1;
                $display("PASS [%0s] word=%h", f_name,
                         build_word(f_label, f_sdi, f_data, f_ssm));
            end
        end
    endtask

    task test_busy_and_latch;
        reg [31:0] expected_serial;
        integer i;
        integer done_before;
        integer wait_count;
        reg fail;
        reg attempt_done;
        begin
            total_tests = total_tests + 1;
            fail = 1'b0;
            attempt_done = 1'b0;
            done_before = tx_done_count;
            expected_serial = build_serial(8'h12, 2'b10, 19'h12345, 2'b01);

            @(negedge clk);
            label = 8'h12;
            sdi   = 2'b10;
            data  = 19'h12345;
            ssm   = 2'b01;
            tx_start = 1'b1;
            @(posedge clk);           /* FIX A1: anchor - word latched, bit 0 driven */

            /* FIX A1: windows anchored to the load posedge; tx_start cleared
             * at the first bit-0 negedge; the rejected second tx_start
             * attempt is applied inside bit 5 without consuming negedges. */
            for (i = 0; i < DATA_BITS; i = i + 1) begin
                repeat (CYCLES_PER_BIT) begin
                    @(negedge clk);
                    if (i == 0)
                        tx_start = 1'b0;
                    if (i == 5) begin
                        if (!attempt_done) begin
                            label = 8'h99;
                            sdi   = 2'b11;
                            data  = 19'h7FFFF;
                            ssm   = 2'b11;
                            tx_start = 1'b1;
                            attempt_done = 1'b1;
                        end
                        else begin
                            tx_start = 1'b0;
                        end
                    end
                    if (tx_data !== expected_serial[i]) begin
                        fail = 1'b1;
                        $display("FAIL [BUSY_LATCH]: bit %0d changed unexpectedly.", i);
                    end
                end
            end
            tx_start = 1'b0;

            /* FIX A1: bounded poll for the single tx_done pulse (the original
             * unguarded @(posedge tx_done) missed the pulse and hung). */
            wait_count = 0;
            while ((tx_done_count == done_before) && (wait_count < 4000)) begin
                @(posedge clk);
                wait_count = wait_count + 1;
            end

            if (tx_done_count != done_before + 1) begin
                fail = 1'b1;
                $display("FAIL [BUSY_LATCH]: second tx_start was accepted.");
            end

            if (fail) begin
                failed_tests = failed_tests + 1;
                $display("FAIL [BUSY_LATCH]");
            end
            else begin
                passed_tests = passed_tests + 1;
                $display("PASS [BUSY_LATCH]");
            end
        end
    endtask

    task test_reset_during_tx;
        reg fail;
        begin
            total_tests = total_tests + 1;
            fail = 1'b0;

            @(negedge clk);
            label = 8'h77;
            sdi   = 2'b01;
            data  = 19'h00ABC;
            ssm   = 2'b01;
            tx_start = 1'b1;
            @(posedge clk);           /* FIX A1: anchor */
            @(negedge clk);
            tx_start = 1'b0;          /* cleared at negedge: no assignment race */
            repeat (10*CYCLES_PER_BIT) @(posedge clk);

            @(negedge clk);
            rst = 1'b1;
            @(posedge clk);           /* FIX A2: synchronous reset applies at this edge */
            @(negedge clk);           /* FIX A2: sample settled outputs */
            if ((tx_busy !== 1'b0) || (tx_done !== 1'b0) || (tx_data !== 1'b0)) begin
                fail = 1'b1;
                $display("FAIL [RESET_DURING_TX]: outputs not reset.");
            end
            rst = 1'b0;

            if (fail) begin
                failed_tests = failed_tests + 1;
                $display("FAIL [RESET_DURING_TX]");
            end
            else begin
                passed_tests = passed_tests + 1;
                $display("PASS [RESET_DURING_TX]");
            end
        end
    endtask

    initial begin
        tx_done_count = 0;
        total_tests = 0;
        passed_tests = 0;
        failed_tests = 0;
        bits_checked = 0;
        bit_errors = 0;
        timing_failures = 0;
        gap_failures = 0;
        tx_done_width_failures = 0;
        tx_done_rise_time = 0;
        tx_busy_rise_time = 0;
        gap_start_time = 0;
        tx_done_prev = 1'b0;

        rst = 1'b1;
        tx_start = 1'b0;
        label = 8'h00;
        sdi = 2'b00;
        data = 19'h00000;
        ssm = 2'b00;

        repeat (5) @(negedge clk);
        rst = 1'b0;
        repeat (2) @(negedge clk);

        total_tests = total_tests + 1;
        if ((tx_busy!==1'b0)||(tx_done!==1'b0)||(tx_data!==1'b0)) begin
            failed_tests = failed_tests + 1;
            $display("FAIL [RESET]");
        end
        else begin
            passed_tests = passed_tests + 1;
            $display("PASS [RESET]");
        end

        verify_word(8'h05,2'b01,19'h0ABCD,2'b00,"NORMAL");
        verify_word(8'hA5,2'b10,19'h12345,2'b11,"MIXED");
        verify_word(8'h00,2'b00,19'h00000,2'b00,"ALL_ZERO");
        verify_word(8'hFF,2'b11,19'h7FFFF,2'b11,"ALL_ONE");
        verify_word(8'hAA,2'b01,19'h15555,2'b01,"ALTERNATING");

        test_busy_and_latch;
        test_reset_during_tx;
        verify_word(8'h88,2'b10,19'h01234,2'b00,"POST_RESET_RECOVERY");

        $display("");
        $display("============================================================");
        $display("ARINC 429 TX VERIFICATION SUMMARY");
        $display("============================================================");
        $display("Total tests              = %0d", total_tests);
        $display("Passed                   = %0d", passed_tests);
        $display("Failed                   = %0d", failed_tests);
        $display("Bits sampled             = %0d", bits_checked);
        $display("Bit errors               = %0d", bit_errors);
        $display("Timing failures          = %0d", timing_failures);
        $display("Gap failures             = %0d", gap_failures);
        $display("tx_done width failures   = %0d", tx_done_width_failures);
        $display("CYCLES_PER_BIT           = %0d", CYCLES_PER_BIT);
        $display("DATA_CYCLES              = %0d", DATA_CYCLES);
        $display("GAP_CYCLES               = %0d", GAP_CYCLES);
        $display("TOTAL_CYCLES             = %0d", TOTAL_CYCLES);
        $display("============================================================");
        if ((failed_tests == 0) &&
            (passed_tests == total_tests) &&
            (timing_failures == 0) &&
            (gap_failures == 0) &&
            (bit_errors == 0) &&
            (tx_done_width_failures == 0) &&
            (bits_checked == 6 * DATA_BITS * CYCLES_PER_BIT))
            $display("OVERALL RESULT = PASS");
        else
            $display("OVERALL RESULT = FAIL");
        $display("============================================================");
        $finish;
    end

    initial begin
        #100000000;
        $display("ERROR: TX testbench timeout.");
        $finish;
    end

endmodule
