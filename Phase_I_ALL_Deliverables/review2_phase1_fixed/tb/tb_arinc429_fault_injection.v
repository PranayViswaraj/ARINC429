`timescale 1ns/1ps
/*==============================================================================
 * FILE   : tb_arinc429_fault_injection.v   (REVIEW-2 CORRECTED, rev B)
 * STATUS : TESTBENCH ONLY (Phase-1 / Review-2 verification layer)
 *
 * PURPOSE
 * =======
 * Randomized, reproducible, self-checking fault injection and communication
 * error analysis for the Review-1 ARINC 429 controller. The three DUT files
 * (arinc429_tx.v, arinc429_rx.v, arinc429_controller.v) are used UNMODIFIED.
 *
 * REVIEW-2 CORRECTIONS APPLIED (each maps to an audit defect ID):
 *   FI-01  reset scenarios now corrupt the wire with the same time-domain
 *          per-bit mechanism as the engine (1-bit `1'b1<<k` bug removed)
 *   FI-02  repeated-error reset variant proves T1 completed AND starts T2
 *          only after tx_busy==0 (a genuinely separate transaction)
 *   FI-03  dead conditions removed; timeout subtype 2 verifies
 *          rx_valid_count==rx_before across the threshold wait window
 *   FI-04  timeout taxonomy completed: (0) truncated word, (1) armed RX on
 *          silent bus [false reception documented], (2) no communication
 *          with rx_before/rx_after check, (3) armed RX, no TX at all
 *   FI-05  expected-limitation counters increment ONLY after the expected
 *          condition is verified; failures go to explicit *_unresolved
 *          buckets that appear in the consistency equations
 *   FI-06  repeated-error blocks emit a WINDOW dataset row class 6
 *   FI-07  high-error-rate windows emit a WINDOW dataset row class 8
 *          (or class 0 + condition flag when below threshold)
 *   FI-08  CSV separates total_transactions / valid_transactions /
 *          errors_observed / faults_injected / fault_tests
 *   FI-09  fault_class and health_label are independent columns;
 *          health_label uses only {0..8, 98}
 *   FI-10  row_type + transaction_id + window_id + event_id +
 *          ref_transaction_id: reset rows never reuse a transaction id
 *   FI-11  repeated-error wording: "REPEATED ERROR PATTERN OBSERVED
 *          (analysis classification)" + per-block DUT-detected member count
 *   FI-12  high-error-rate wording: "HIGH ERROR RATE CLASSIFIED (window-
 *          level analysis)" - never "DUT detected"
 *   FI-13  FIFO cases verified with per-case event deltas
 *   FI-14  invalid-label rows record original/injected label + support flag
 *   FI-15  bus-idle records duration>=threshold condition; a directed gap
 *          control proves a normal 2000-cycle gap is NOT an idle error
 *   FI-16  directed windows: 0%, low, below-boundary, at-boundary, above
 *   FI-17  rand_range guarded; window/planned/depth/thresholds clamped;
 *          full plusarg override set (+SEED +MODE +TESTS +PROB +WINDOW
 *          +THRESH +TIMEOUT +IDLE +FDEPTH +REPMIN +REPMAX)
 *   FI-18  HEALTH_UNRELIABLE=98 rows on framework failure; parity anomaly
 *          bucket; post-reset recovery transaction in every reset case
 *   FI-19  every CSV row audited at write time (master-prompt FIX 40 +
 *          FINAL CSV AUDIT): sample_id monotonic and unique, row_type /
 *          fault_class / fault_position / error_rate / window-counter /
 *          health_label / verification_status range checks; any violation
 *          increments dataset_integrity_failures, which gates the final
 *          OVERALL RESULT (no silent malformed rows can yield a PASS)
 *
 * ARCHITECTURE (DUT stays golden):
 *   TX (inside controller) --> arinc_tx pin --> arinc429_fault_injector
 *                            --> arinc_rx_ext pin --> RX (inside controller)
 *   loopback_enable is tied to 0 for every fault test, so the RX source mux
 *   always selects the externally injected (possibly corrupted) stream.
 *   With injection disabled the injector is a wire: normal Review-1 behavior.
 *
 * FAULT / ERROR CLASSES (analysis dataset labels, PROJECT-DEFINED - none of
 * the thresholds below are ARINC 429 protocol requirements):
 *   0 NORMAL                      (reference class)
 *   1 PARITY_ERROR                (single serial bit inverted on the wire)
 *   2 COMMUNICATION_TIMEOUT       (incomplete / missing reception event)
 *   3 FIFO_OVERFLOW               (verification-modeled FIFO, see note)
 *   4 FIFO_UNDERFLOW              (verification-modeled FIFO, see note)
 *   5 INVALID_LABEL               (APPLICATION-DEFINED invalid label)
 *   6 REPEATED_COMMUNICATION_ERROR(window-level pattern record)
 *   7 BUS_IDLE_ERROR              (suppressed activity, idle time measured)
 *   8 HIGH_ERROR_RATE             (window-level statistical classification)
 *   99 RESET_ABORT                (event row; NOT a communication fault)
 *   20 TWO_BIT (underlying_fault_type column only; ground truth stays 1)
 *   NOTE: the Review-1 RTL contains NO FIFO, NO timeout detector, NO label
 *   validator, NO idle detector, NO repeated-error detector and NO error-rate
 *   detector. Classes 2..8 are therefore observed/classified at verification
 *   level and counted as EXPECTED LIMITATIONS of the conventional design.
 *   Nothing is falsely attributed to the DUT.
 *
 * HONEST DETECTION MODEL (per class):
 *   PARITY_ERROR    : DUT DETECTED iff rx_valid==1 AND rx_word!=original
 *                     word AND parity_error==1 (single-bit flip).
 *   TWO-BIT         : EXPECTED LIMITATION of odd parity (word differs,
 *                     parity_error==0). Reported as such, never as detection.
 *   TIMEOUT/IDLE/
 *   FIFO/LABEL      : DUT cannot detect (no such hardware). Expected
 *                     limitations; observations still fully predicted and
 *                     verified bit-accurately against the RTL behavior.
 *   REPEATED        : window-level: REPEATED ERROR PATTERN OBSERVED by
 *                     analysis; underlying DUT-detected members counted
 *                     separately. Never called hardware detection.
 *   HIGH_ERROR_RATE : window-level statistical classification vs threshold.
 *                     "CLASSIFIED", never "DUT detected".
 *
 * SELF-CHECKING
 * =============
 * Every injected fault is proven end-to-end:
 *   fault request -> actual wire corruption (captured on the wire, bit by
 *   bit) -> DUT observation -> bit-accurate predicted response -> observed
 *   response -> classification -> counters -> final report.
 * PASS/FAIL is derived ONLY from observed DUT outputs and captured wire data.
 * No result is hard-coded. Reaching the end of simulation without failures
 * never produces a PASS by itself.
 *
 * MODES (+MODE=):
 *   0 NORMAL MODE          - regression: normal traffic only, injection off
 *                            (equivalent to FAULT_INJECTION_ENABLE=0)
 *   1 RANDOM FAULT MODE    - staged randomized campaign (default)
 *   2 DIRECTED FAULT MODE  - deterministic demonstration of every fault class
 * MODE 1 also runs the directed suite first (single-fault cases before mixed
 * randomized scenarios, stages: individual -> repeated -> mixed -> reset).
 *
 * RANDOMIZATION
 * =============
 * Verilog-2001 only: $random with one explicit integer seed variable.
 *   +SEED=<n>     seed (default USER_SEED=1); printed at simulation start
 *   +MODE=<n>     run mode (default 1)
 *   +TESTS=<n>    number of stage-3 randomized iterations (default 60)
 *   +PROB=<n>     stage-3 fault probability percent (default 80)
 *   +WINDOW=<n>   transactions per high-rate window (default 10, clamp 2..64)
 *   +THRESH=<n>   high-rate threshold percent (default 30, clamp 1..100)
 *   +TIMEOUT=<n>  timeout threshold cycles (default 22000, clamp >=18000)
 *   +IDLE=<n>     idle threshold cycles (default 22000, clamp >=4001)
 *   +FDEPTH=<n>   verification FIFO depth (default 4, clamp 1..64)
 *   +REPMIN=/<n>  repeated-error block minimum (default 3, clamp >=2)
 *   +REPMAX=<n>   repeated-error block maximum (default 6, >= REPMIN)
 * All randomness flows through rand_range()/pick functions using the single
 * seed, so the same seed always reproduces the identical fault sequence
 * within one simulator. {$random(seed)} is used (unsigned concatenation) so
 * negative $random values can never create invalid indices or ranges.
 *
 * OUTPUTS
 * =======
 *   - structured per-transaction log on stdout
 *   - final counter summary + counter-consistency equations
 *   - CSV ML dataset: arinc429_ml_dataset_seed<SEED>.csv (schema below)
 *
 * CSV SCHEMA (46 columns, identical meaning on every row):
 *   sample_id, seed, row_type, transaction_id, window_id, event_id,
 *   ref_transaction_id, fault_class, underlying_fault_type, fault_position,
 *   word_bit_position, original_label, injected_label, label_supported,
 *   total_transactions, valid_transactions, errors_observed,
 *   faults_injected, fault_tests, parity_error_count, timeout_count,
 *   fifo_overflow_count, fifo_underflow_count, invalid_label_count,
 *   repeated_error_count, bus_idle_count, idle_duration, idle_threshold,
 *   consecutive_error_count, error_rate_pct, high_error_rate_threshold_pct,
 *   high_error_rate_condition, repeat_count,
 *   successful_transactions_between_errors, last_error_type,
 *   rx_word_mismatch, parity_error, rx_valid, tx_done, window_size,
 *   window_faulty, dominant_error_type, detection_status,
 *   verification_status, expected_limitation_flag, health_label
 *   row_type             : 0=TRANSACTION 1=WINDOW 2=EVENT 3=RESET
 *   transaction_id       : communication event id, -1 when the row is not a
 *                          communication transaction (window/event/reset rows)
 *   errors_observed      : cumulative OBSERVED communication error events
 *                          (corrupted received words, verified timeout /
 *                          idle / label / modeled-FIFO conditions)
 *   faults_injected      : cumulative faults intentionally introduced
 *   fault_tests          : cumulative fault TEST CASES (case counter)
 *   detection_status     : 0=N/A 1=DUT_DETECTED 2=DUT_NOT_DETECTED
 *                          3=EXPECTED_LIMITATION_NO_HW 4=ANALYSIS_CLASSIFIED
 *                          5=OBSERVED_AT_VERIFICATION_LEVEL
 *   verification_status  : 0=N/A 1=VERIFIED_PASS 2=VERIFIED_FAIL_DUT
 *                          3=VERIFIED_FAIL_FRAMEWORK
 *   health_label         : 0..8 ground truth, 98=HEALTH_UNRELIABLE (only
 *                          when the row's verification could not be
 *                          established), never for a mere DUT miss
 *============================================================================*/

module tb_arinc429_fault_injection;

    /*------------------------------------------------------------------------
     * ARINC 429 baseline parameters (identical to Review-1)
     *----------------------------------------------------------------------*/
    localparam integer CLK_FREQ_HZ     = 50000000;
    localparam integer ARINC_BAUD      = 100000;
    localparam integer INTERWORD_BITS  = 4;
    localparam integer CYCLES_PER_BIT  = CLK_FREQ_HZ / ARINC_BAUD;  /* 500  */
    localparam integer GAP_CYCLES      = INTERWORD_BITS * CYCLES_PER_BIT; /* 2000 */
    localparam integer TOTAL_TX_CYCLES = 32 * CYCLES_PER_BIT + GAP_CYCLES; /* 18000 */
    localparam integer CLK_PERIOD_NS   = 20;
    /* Exact latency: posedge that samples rx_start -> posedge that raises
     * rx_valid (32-bit reception with half-bit first-sample lead). */
    localparam integer RX_VALID_DELAY_CYCLES = 250 + 31 * CYCLES_PER_BIT + 1; /* 15751 */

    /*------------------------------------------------------------------------
     * PROJECT-DEFINED analysis parameters (NOT ARINC 429 protocol facts)
     *----------------------------------------------------------------------*/
    integer user_seed;                    /* +SEED= override allowed          */
    integer rng_seed;                     /* live $random stream state        */
    integer run_mode;                     /* +MODE= override allowed          */
    integer num_random_tests;             /* +TESTS= override allowed         */
    integer fault_probability_pct;        /* +PROB= override allowed          */
    integer error_rate_window;            /* transactions per rate window     */
    integer high_error_rate_threshold_pct;/* project-defined threshold        */
    integer timeout_threshold_cycles;     /* project-defined timeout limit    */
    integer idle_threshold_cycles;        /* project-defined idle limit       */
    integer fifo_depth;                   /* verification-modeled FIFO depth  */
    integer repeat_error_min;             /* repeated-error block range       */
    integer repeat_error_max;
    integer fault_weights [1:8];          /* weighted random selection        */

    /*------------------------------------------------------------------------
     * Fault / error class codes (analysis dataset labels)
     *----------------------------------------------------------------------*/
    localparam integer CLASS_NORMAL       = 0;
    localparam integer CLASS_PARITY       = 1;
    localparam integer CLASS_TIMEOUT      = 2;
    localparam integer CLASS_FIFO_OVF     = 3;
    localparam integer CLASS_FIFO_UNF     = 4;
    localparam integer CLASS_INVALID_LBL  = 5;
    localparam integer CLASS_REPEATED     = 6;
    localparam integer CLASS_BUS_IDLE     = 7;
    localparam integer CLASS_HIGH_RATE    = 8;
    localparam integer CLASS_RESET        = 99;  /* reset-abort event rows:
                                                     not a communication fault */
    localparam integer CLASS_TWO_BIT      = 20;  /* underlying_fault_type
                                                     subclass code only       */
    localparam integer HEALTH_UNRELIABLE  = 98;  /* verification failed      */

    /* row_type codes */
    localparam integer ROW_TRANSACTION    = 0;
    localparam integer ROW_WINDOW         = 1;
    localparam integer ROW_EVENT          = 2;
    localparam integer ROW_RESET          = 3;

    /* detection_status codes */
    localparam integer DET_NA             = 0;
    localparam integer DET_DUT_DETECTED   = 1;
    localparam integer DET_DUT_MISSED     = 2;
    localparam integer DET_EXPECTED_LIMIT = 3;
    localparam integer DET_ANALYSIS       = 4;
    localparam integer DET_VERIFICATION   = 5;

    /* verification_status codes */
    localparam integer VER_NA             = 0;
    localparam integer VER_PASS           = 1;
    localparam integer VER_FAIL_DUT       = 2;
    localparam integer VER_FAIL_FRAMEWORK = 3;

    /*------------------------------------------------------------------------
     * Serial position classes (ARINC 429 word fields in serial order)
     *   serial 0..7   = label (bit-reversed: serial k <-> word bit 7-k)
     *   serial 8..9   = SDI
     *   serial 10..28 = data
     *   serial 29..30 = SSM
     *   serial 31     = parity
     *----------------------------------------------------------------------*/
    localparam integer POS_LABEL  = 0;
    localparam integer POS_SDI    = 1;
    localparam integer POS_DATA   = 2;
    localparam integer POS_SSM    = 3;
    localparam integer POS_PARITY = 4;

    /*------------------------------------------------------------------------
     * DUT + fault injector wiring (DUT UNMODIFIED)
     *----------------------------------------------------------------------*/
    reg          clk;
    reg          rst;
    reg          tx_start;
    reg  [7:0]   label;
    reg  [1:0]   sdi;
    reg  [18:0]  data;
    reg  [1:0]   ssm;
    wire         tx_busy;
    wire         tx_done;

    reg          rx_start;
    wire [31:0]  rx_word;
    wire         rx_valid;
    wire         parity_error;
    wire         rx_busy;

    wire         arinc_tx;         /* DUT serial output                    */
    wire         arinc_line;       /* FIU output -> DUT arinc_rx_ext pin   */
    reg          fiu_corrupt;      /* FIU control: invert current bit      */
    reg          fiu_idle;         /* FIU control: force line low          */
    reg          loopback_enable;  /* tied 0: RX always listens to FIU     */

    arinc429_controller #(
        .CLK_FREQ_HZ    (CLK_FREQ_HZ),
        .ARINC_BAUD     (ARINC_BAUD),
        .INTERWORD_BITS (INTERWORD_BITS)
    ) dut (
        .clk             (clk),
        .rst             (rst),
        .tx_start        (tx_start),
        .label           (label),
        .sdi             (sdi),
        .data            (data),
        .ssm             (ssm),
        .tx_busy         (tx_busy),
        .tx_done         (tx_done),
        .rx_start        (rx_start),
        .rx_word         (rx_word),
        .rx_valid        (rx_valid),
        .parity_error    (parity_error),
        .rx_busy         (rx_busy),
        .arinc_tx        (arinc_tx),
        .arinc_rx_ext    (arinc_line),
        .loopback_enable (loopback_enable)
    );

    /* VERIFICATION-ONLY pass-through fault insertion unit */
    arinc429_fault_injector fiu (
        .line_in       (arinc_tx),
        .inject_corrupt(fiu_corrupt),
        .force_idle    (fiu_idle),
        .line_out      (arinc_line)
    );

    /*------------------------------------------------------------------------
     * Clock
     *----------------------------------------------------------------------*/
    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD_NS/2) clk = ~clk;
    end

    /*------------------------------------------------------------------------
     * Persistent event monitors (race-free: counters, never pulse waits)
     *----------------------------------------------------------------------*/
    integer tx_done_count;
    integer rx_valid_count;
    integer tx_done_rise_time;
    integer rx_valid_rise_time;
    integer tx_busy_rise_time;
    integer rx_arm_time;
    integer tx_done_width_failures;
    integer rx_valid_width_failures;
    reg     tx_done_prev;
    reg     rx_valid_prev;

    always @(posedge tx_done) begin
        tx_done_count     = tx_done_count + 1;
        tx_done_rise_time = $time;
        tx_done_prev      = 1'b1;
    end

    always @(negedge tx_done) begin
        if (tx_done_prev === 1'b1)
            if (($time - tx_done_rise_time) != CLK_PERIOD_NS)
                tx_done_width_failures = tx_done_width_failures + 1;
        tx_done_prev = 1'b0;
    end

    always @(posedge rx_valid) begin
        rx_valid_count     = rx_valid_count + 1;
        rx_valid_rise_time = $time;
        rx_valid_prev      = 1'b1;
    end

    always @(negedge rx_valid) begin
        if (rx_valid_prev === 1'b1)
            if (($time - rx_valid_rise_time) != CLK_PERIOD_NS)
                rx_valid_width_failures = rx_valid_width_failures + 1;
        rx_valid_prev = 1'b0;
    end

    always @(posedge tx_busy)  tx_busy_rise_time = $time;
    always @(posedge rx_start) rx_arm_time       = $time;

    /*------------------------------------------------------------------------
     * Wire capture (adversarial proof that injection reached the wire)
     *----------------------------------------------------------------------*/
    reg [31:0] orig_capture;       /* bit k = FIU input  sampled mid-bit k   */
    reg [31:0] wire_capture;       /* bit k = FIU output sampled mid-bit k   */

    /*------------------------------------------------------------------------
     * MASTER LEDGERS
     *----------------------------------------------------------------------*/
    integer total_tests, passed_tests, failed_tests;
    integer normal_tests, normal_passed, normal_failed;
    integer fault_tests;                       /* fault TEST CASES             */
    integer faults_injected, faults_detected, faults_undetected;
    integer expected_limitations;
    integer faults_unresolved;                 /* FI-05: framework-failure
                                                  bucket (keeps E2 balanced)  */
    integer errors_observed;                   /* FI-08: observed error events */

    /* per-class ledgers */
    integer parity_faults,   parity_detected,   parity_undetected;
    integer parity_anomalies;                  /* FI-18: detected-but-response-
                                                  mismatched cases             */
    integer two_bit_faults,  two_bit_limitations;
    integer timeout_faults,  timeout_observed,  timeout_unresolved;
    integer fifo_overflow_events,  fifo_overflow_expected_limit;
    integer fifo_overflow_unresolved;
    integer fifo_underflow_events, fifo_underflow_expected_limit;
    integer fifo_underflow_unresolved;
    integer invalid_label_faults,  invalid_label_expected_limit;
    integer invalid_label_unresolved;
    integer repeated_error_cases,  repeated_error_patterns_observed;
    integer repeated_error_failed;             /* FI-11 rename + failure bucket */
    integer repeated_underlying_dut_detected;  /* blocks with >=1 DUT-detected
                                                  member (honest split)        */
    integer bus_idle_cases,        bus_idle_expected_limit;
    integer bus_idle_unresolved;
    integer high_error_rate_cases, high_error_rate_windows_classified;
    integer high_error_rate_windows_below;
    integer high_error_rate_failed;

    /* bit-level fault positions (single-bit corruption ledger) */
    integer bit_faults_by_label, bit_faults_by_sdi, bit_faults_by_data;
    integer bit_faults_by_ssm,   bit_faults_by_parity;

    /* reset scenarios (NOT communication faults) */
    integer reset_tests, reset_passed, reset_failed;

    /* framework integrity */
    integer timing_failures, consistency_violations;
    integer tb_internal_errors;
    integer dataset_integrity_failures;    /* FI-19: per-row CSV audit     */
    integer last_sample_id;                /* FI-19: monotonic id tracker  */

    /* ML / dataset bookkeeping */
    integer sample_id;
    integer event_id;                          /* FI-10: event row id          */
    integer window_id;                         /* FI-10: window row id         */
    integer parity_error_count, timeout_count, fifo_overflow_count;
    integer fifo_underflow_count, invalid_label_count, repeated_error_count;
    integer bus_idle_count;
    integer consecutive_error_count, last_fault_txn_id;
    integer last_error_type;
    real    last_error_rate;
    integer last_idle_duration;
    integer seed_at_txn;
    integer csv_fd;
    reg [511:0] csv_name;

    /* FI-14 label provenance scratch (-1 = not applicable to last row) */
    integer last_orig_label;
    integer last_inj_label;
    integer last_label_supported;

    /* verification-modeled FIFO (no FIFO exists in the Review-1 RTL) */
    reg [31:0] fifo_mem [0:63];
    integer    fifo_occ, fifo_wr_req_total, fifo_rd_req_total;

    /* engine scratch */
    integer txn_id;
    reg     verbose_txn;
    integer fault_pos_scratch;     /* serial position of last bit fault    */
    integer fault_word_bit_scratch;/* word bit position of last bit fault  */

    /* observations exported by the engine for wrapper classification */
    reg        last_rx_valid_seen;
    reg        last_txdone_seen;
    reg [31:0] last_rx_word_obs;
    reg        last_parity_obs;
    reg        last_wire_ok;
    reg        last_timing_ok;
    reg [31:0] last_recv_exp_word;
    reg        last_recv_exp_par;
    reg [31:0] last_orig_word;
    reg        last_idle_event;

    /*------------------------------------------------------------------------
     * FUNCTIONS: word construction and serial<->word mapping
     * (independent reference model: built from the ARINC 429 word layout
     * defined by the project, NOT by copying DUT internals)
     *----------------------------------------------------------------------*/
    function [31:0] build_serial;      /* parallel fields -> serial order */
        input [7:0]  f_label;
        input [1:0]  f_sdi;
        input [18:0] f_data;
        input [1:0]  f_ssm;
        reg parity;
        integer i;
        begin
            parity = ~^{f_label, f_sdi, f_data, f_ssm};
            build_serial[0]  = f_label[7];  /* label transmitted MSB first  */
            build_serial[1]  = f_label[6];
            build_serial[2]  = f_label[5];
            build_serial[3]  = f_label[4];
            build_serial[4]  = f_label[3];
            build_serial[5]  = f_label[2];
            build_serial[6]  = f_label[1];
            build_serial[7]  = f_label[0];
            build_serial[8]  = f_sdi[0];
            build_serial[9]  = f_sdi[1];
            for (i = 0; i < 19; i = i + 1)
                build_serial[10+i] = f_data[i];
            build_serial[29] = f_ssm[0];
            build_serial[30] = f_ssm[1];
            build_serial[31] = parity;
        end
    endfunction

    function [31:0] word_from_serial;  /* serial order -> parallel word */
        input [31:0] ser;
        integer i;
        begin
            for (i = 0; i < 8; i = i + 1)
                word_from_serial[7-i] = ser[i];     /* label bit-reversed  */
            word_from_serial[9:8]   = ser[9:8];     /* SDI                 */
            word_from_serial[28:10] = ser[28:10];   /* data                */
            word_from_serial[30:29] = ser[30:29];   /* SSM                 */
            word_from_serial[31]    = ser[31];      /* parity              */
        end
    endfunction

    function [31:0] build_word;        /* parallel fields -> parallel word */
        input [7:0]  f_label;
        input [1:0]  f_sdi;
        input [18:0] f_data;
        input [1:0]  f_ssm;
        begin
            build_word = {~^{f_label, f_sdi, f_data, f_ssm}, f_ssm,
                          f_data, f_sdi, f_label};
        end
    endfunction

    function [4:0] word_bit_of_serial; /* explicit serial->word bit map */
        input integer sp;
        begin
            if (sp < 8) word_bit_of_serial = 7 - sp;   /* label reversed */
            else        word_bit_of_serial = sp[4:0];  /* identity       */
        end
    endfunction

    function [127:0] pos_class_name;   /* serial position class name */
        input integer pc;
        begin
            case (pc)
                POS_LABEL  : pos_class_name = "LABEL";
                POS_SDI    : pos_class_name = "SDI";
                POS_DATA   : pos_class_name = "DATA";
                POS_SSM    : pos_class_name = "SSM";
                POS_PARITY : pos_class_name = "PARITY";
                default    : pos_class_name = "UNKNOWN";
            endcase
        end
    endfunction

    function integer pos_class_of;     /* serial position -> class code */
        input integer sp;
        begin
            if (sp < 8)       pos_class_of = POS_LABEL;
            else if (sp < 10) pos_class_of = POS_SDI;
            else if (sp < 29) pos_class_of = POS_DATA;
            else if (sp < 31) pos_class_of = POS_SSM;
            else              pos_class_of = POS_PARITY;
        end
    endfunction

    function [255:0] class_name;
        input integer c;
        begin
            case (c)
                CLASS_NORMAL      : class_name = "NORMAL";
                CLASS_PARITY      : class_name = "PARITY_ERROR";
                CLASS_TIMEOUT     : class_name = "COMMUNICATION_TIMEOUT";
                CLASS_FIFO_OVF    : class_name = "FIFO_OVERFLOW";
                CLASS_FIFO_UNF    : class_name = "FIFO_UNDERFLOW";
                CLASS_INVALID_LBL : class_name = "INVALID_LABEL";
                CLASS_REPEATED    : class_name = "REPEATED_COMM_ERROR";
                CLASS_BUS_IDLE    : class_name = "BUS_IDLE_ERROR";
                CLASS_HIGH_RATE   : class_name = "HIGH_ERROR_RATE";
                CLASS_TWO_BIT     : class_name = "PARITY_TWO_BIT_LIMIT";
                CLASS_RESET       : class_name = "RESET_ABORT";
                default           : class_name = "UNKNOWN";
            endcase
        end
    endfunction

    /*------------------------------------------------------------------------
     * PROJECT-SPECIFIC supported-label table (APPLICATION-DEFINED).
     * This is an example analysis configuration, NOT an ARINC 429 rule.
     *----------------------------------------------------------------------*/
    function label_is_valid;
        input [7:0] l;
        begin
            case (l)
                8'h05, 8'h15, 8'h25, 8'h35,
                8'h45, 8'h55, 8'h65, 8'h75 : label_is_valid = 1'b1;
                default                    : label_is_valid = 1'b0;
            endcase
        end
    endfunction

    /*------------------------------------------------------------------------
     * FUNCTIONS: reproducible randomization (Verilog-2001 $random + seed)
     * {$random(seed)} makes the value unsigned so modulo is always safe.
     * FI-17: guard against degenerate ranges (span < 1).
     *----------------------------------------------------------------------*/
    function integer rand_range;
        input integer lo;
        input integer hi;
        integer span;
        begin
            span = hi - lo + 1;
            if (span < 1)
                rand_range = lo;
            else
                rand_range = lo + ({$random(rng_seed)} % span);
        end
    endfunction

    function integer pick_weighted_fault;   /* 1..8, weighted, no zero span */
        input integer dummy;
        integer total_w, acc, w, f;
        begin
            total_w = 0;
            for (f = 1; f <= 8; f = f + 1)
                total_w = total_w + (fault_weights[f] > 0 ? fault_weights[f] : 0);
            if (total_w <= 0) begin
                pick_weighted_fault = 1;
            end else begin
                acc = {$random(rng_seed)} % total_w;
                pick_weighted_fault = 8;
                for (f = 1; f <= 8; f = f + 1) begin
                    w = (fault_weights[f] > 0 ? fault_weights[f] : 0);
                    if (acc < w) begin
                        pick_weighted_fault = f;
                        f = 9;                  /* break out */
                    end else begin
                        acc = acc - w;
                    end
                end
            end
        end
    endfunction

    function [7:0] pick_valid_label;         /* random label from the table */
        input integer dummy;
        integer idx;
        begin
            idx = rand_range(0, 7);
            case (idx)
                0 : pick_valid_label = 8'h05;
                1 : pick_valid_label = 8'h15;
                2 : pick_valid_label = 8'h25;
                3 : pick_valid_label = 8'h35;
                4 : pick_valid_label = 8'h45;
                5 : pick_valid_label = 8'h55;
                6 : pick_valid_label = 8'h65;
                default : pick_valid_label = 8'h75;
            endcase
        end
    endfunction

    function [7:0] pick_invalid_label;       /* random label OUTSIDE the table */
        input integer dummy;
        integer guard;
        reg [7:0] cand;
        begin
            cand = 8'h00;
            for (guard = 0; guard < 200; guard = guard + 1) begin
                cand = rand_range(0, 255);
                if (!label_is_valid(cand)) begin
                    guard = 1000;                /* exit loop */
                end
            end
            pick_invalid_label = cand;
        end
    endfunction

    /*------------------------------------------------------------------------
     * VERIFICATION-MODELED FIFO (the Review-1 RTL contains no FIFO).
     * Pure testbench behavior model used to generate FIFO overflow /
     * underflow analysis events. Never reported as DUT hardware events.
     *----------------------------------------------------------------------*/
    task fifo_model_reset;
        begin
            fifo_occ = 0;
        end
    endtask

    task fifo_model_write;                   /* one write request */
        input [31:0] w;
        begin
            fifo_wr_req_total = fifo_wr_req_total + 1;
            if (fifo_occ >= fifo_depth) begin
                fifo_overflow_events = fifo_overflow_events + 1;
                $display("  [FIFO-MODEL] OVERFLOW: write request dropped, occupancy=%0d (depth=%0d)",
                         fifo_occ, fifo_depth);
            end else begin
                fifo_mem[fifo_occ] = w;
                fifo_occ = fifo_occ + 1;
            end
        end
    endtask

    task fifo_model_read;                    /* one read request */
        begin
            fifo_rd_req_total = fifo_rd_req_total + 1;
            if (fifo_occ == 0) begin
                fifo_underflow_events = fifo_underflow_events + 1;
                $display("  [FIFO-MODEL] UNDERFLOW: read request on empty FIFO");
            end else begin
                fifo_occ = fifo_occ - 1;
            end
        end
    endtask

    /*------------------------------------------------------------------------
     * CSV DATASET ROW (FI-05/06/07/08/09/10/14: full schema, one meaning
     * per column on every row; row_type separates transaction / window /
     * event / reset records; health_label restricted to {0..8, 98})
     *----------------------------------------------------------------------*/
    /*------------------------------------------------------------------------
     * DATASET ROW AUDITOR (FI-19: master-prompt FIX 40 + FINAL CSV AUDIT)
     * Runs on every dataset row before it is written. Any violation
     * increments dataset_integrity_failures, which gates the final
     * OVERALL RESULT, so a malformed CSV can never yield a PASS.
     * Checks:
     *   - sample_id strictly monotonic (unique, no gaps, no reuse)
     *   - row_type in {0 TXN, 1 WINDOW, 2 EVENT, 3 RESET}
     *   - fault_class in {0..8, 20 two-bit subclass, 99 reset}
     *   - fault position in [-1 N/A .. 31]
     *   - error rate in [0..100] percent (no impossible rates)
     *   - window counters coherent (0 <= faulty <= size; nonzero faulty
     *     forbidden on non-window rows)
     *   - health label in {0..8, 98}
     *   - verification status in {0..3}
     *----------------------------------------------------------------------*/
    task audit_csv_row;
        input integer rtype;
        input integer fclass;
        input integer fpos;
        input integer rate_pct;
        input integer wsize;
        input integer wfaulty;
        input integer ver_stat;
        input integer hlabel;
        begin
            if (sample_id !== last_sample_id + 1) begin
                dataset_integrity_failures = dataset_integrity_failures + 1;
                $display("DATASET INTEGRITY FAIL: sample_id %0d is not last+1 (last=%0d) at row_type=%0d",
                         sample_id, last_sample_id, rtype);
            end
            last_sample_id = sample_id;
            if ((rtype < 0) || (rtype > 3)) begin
                dataset_integrity_failures = dataset_integrity_failures + 1;
                $display("DATASET INTEGRITY FAIL: invalid row_type %0d at sample_id %0d",
                         rtype, sample_id);
            end
            if ((fclass < 0) || ((fclass > 8) && (fclass != 20) && (fclass != 99))) begin
                dataset_integrity_failures = dataset_integrity_failures + 1;
                $display("DATASET INTEGRITY FAIL: invalid fault_class %0d at sample_id %0d",
                         fclass, sample_id);
            end
            if ((fpos < -1) || (fpos > 31)) begin
                dataset_integrity_failures = dataset_integrity_failures + 1;
                $display("DATASET INTEGRITY FAIL: invalid fault position %0d at sample_id %0d",
                         fpos, sample_id);
            end
            if ((rate_pct < 0) || (rate_pct > 100)) begin
                dataset_integrity_failures = dataset_integrity_failures + 1;
                $display("DATASET INTEGRITY FAIL: impossible error rate %0d%% at sample_id %0d",
                         rate_pct, sample_id);
            end
            if (wsize > 0) begin
                if ((wfaulty < 0) || (wfaulty > wsize)) begin
                    dataset_integrity_failures = dataset_integrity_failures + 1;
                    $display("DATASET INTEGRITY FAIL: window errors %0d exceed window size %0d at sample_id %0d",
                             wfaulty, wsize, sample_id);
                end
            end else if (wfaulty != 0) begin
                dataset_integrity_failures = dataset_integrity_failures + 1;
                $display("DATASET INTEGRITY FAIL: nonzero window errors %0d on non-window row at sample_id %0d",
                         wfaulty, sample_id);
            end
            if ((hlabel < 0) || ((hlabel > 8) && (hlabel != 98))) begin
                dataset_integrity_failures = dataset_integrity_failures + 1;
                $display("DATASET INTEGRITY FAIL: invalid health label %0d at sample_id %0d",
                         hlabel, sample_id);
            end
            if ((ver_stat < 0) || (ver_stat > 3)) begin
                dataset_integrity_failures = dataset_integrity_failures + 1;
                $display("DATASET INTEGRITY FAIL: invalid verification status %0d at sample_id %0d",
                         ver_stat, sample_id);
            end
        end
    endtask

    task write_csv_row;
        input integer rtype;       /* ROW_* code                            */
        input integer txn;         /* transaction_id or -1                  */
        input integer win;         /* window_id or -1                       */
        input integer evt;         /* event_id or -1                        */
        input integer ref_txn;     /* referenced transaction id or -1       */
        input integer fclass;      /* fault_class (ground-truth family)     */
        input integer ufault;      /* underlying_fault_type or -1           */
        input integer fpos;        /* serial fault position or -1           */
        input integer orig_lbl;    /* original label or -1                  */
        input integer inj_lbl;     /* injected label or -1                  */
        input integer lbl_sup;     /* label supported 1/0 or -1             */
        input integer idle_dur;    /* this-row idle measurement or 0        */
        input integer rate_pct;    /* window rate pct or 0                  */
        input integer her_cond;    /* -1 N/A / 0 below / 1 exceeded         */
        input integer reps;        /* repeat_count (window rows) or 0       */
        input integer suc_between; /* successes between errors (window)     */
        input integer wsize;       /* window size (window rows) or 0        */
        input integer wfaulty;     /* window faulty count or 0              */
        input integer dom_type;    /* dominant error type or -1             */
        input integer det_stat;    /* DET_* code                            */
        input integer ver_stat;    /* VER_* code                            */
        input integer lim_flag;    /* expected limitation flag              */
        input integer hlabel;      /* health label {0..8, 98}               */
        begin
            sample_id = sample_id + 1;
            audit_csv_row(rtype, fclass, fpos, rate_pct, wsize, wfaulty,
                          ver_stat, hlabel);
            $fdisplay(csv_fd,
                "%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",
                sample_id, user_seed, rtype, txn, win, evt, ref_txn,
                fclass, ufault, fpos,
                (fpos >= 0) ? word_bit_of_serial(fpos) : -1,
                orig_lbl, inj_lbl, lbl_sup,
                txn_id, rx_valid_count, errors_observed,
                faults_injected, fault_tests,
                parity_error_count, timeout_count, fifo_overflow_count,
                fifo_underflow_count, invalid_label_count,
                repeated_error_count, bus_idle_count,
                idle_dur, idle_threshold_cycles,
                consecutive_error_count, rate_pct,
                high_error_rate_threshold_pct, her_cond, reps, suc_between,
                last_error_type,
                0, 0, 0, 0,
                wsize, wfaulty, dom_type,
                det_stat, ver_stat, lim_flag, hlabel);
        end
    endtask

    /* transaction rows carry observation flags; the base task above keeps a
     * fixed schema, so the observation columns are written through this
     * variant which patches columns 36..39 (rx_word_mismatch, parity_error,
     * rx_valid, tx_done) - implemented as a separate writer to keep every
     * column positionally fixed. */
    task write_csv_row_obs;
        input integer rtype;
        input integer txn;
        input integer win;
        input integer evt;
        input integer ref_txn;
        input integer fclass;
        input integer ufault;
        input integer fpos;
        input integer orig_lbl;
        input integer inj_lbl;
        input integer lbl_sup;
        input integer idle_dur;
        input integer rate_pct;
        input integer her_cond;
        input integer reps;
        input integer suc_between;
        input integer wsize;
        input integer wfaulty;
        input integer dom_type;
        input integer det_stat;
        input integer ver_stat;
        input integer lim_flag;
        input integer hlabel;
        input integer obs_mismatch;   /* rx_word != expected word        */
        input integer obs_par;        /* observed parity_error flag      */
        input integer obs_rxv;        /* observed rx_valid pulse         */
        input integer obs_txd;        /* observed tx_done pulse          */
        begin
            sample_id = sample_id + 1;
            audit_csv_row(rtype, fclass, fpos, rate_pct, wsize, wfaulty,
                          ver_stat, hlabel);
            $fdisplay(csv_fd,
                "%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",
                sample_id, user_seed, rtype, txn, win, evt, ref_txn,
                fclass, ufault, fpos,
                (fpos >= 0) ? word_bit_of_serial(fpos) : -1,
                orig_lbl, inj_lbl, lbl_sup,
                txn_id, rx_valid_count, errors_observed,
                faults_injected, fault_tests,
                parity_error_count, timeout_count, fifo_overflow_count,
                fifo_underflow_count, invalid_label_count,
                repeated_error_count, bus_idle_count,
                idle_dur, idle_threshold_cycles,
                consecutive_error_count, rate_pct,
                high_error_rate_threshold_pct, her_cond, reps, suc_between,
                last_error_type,
                obs_mismatch, obs_par, obs_rxv, obs_txd,
                wsize, wfaulty, dom_type,
                det_stat, ver_stat, lim_flag, hlabel);
        end
    endtask

    /*------------------------------------------------------------------------
     * CORE TRANSACTION ENGINE
     *
     * Drives one full TX -> (FIU) -> RX transaction with per-serial-bit
     * corrupt/suppress masks, captures the actual wire content bit by bit,
     * computes the bit-accurate expected DUT response BEFORE the transfer,
     * then compares observation vs prediction.
     *
     * Timing anchors (no races):
     *   - all TB drives at negedges; DUT samples at posedges
     *   - tx_start high for exactly one posedge (the latch edge)
     *   - bit k occupies the 500 negedges after its load posedge
     *   - DUT responses sampled at negedges (settled values)
     *   - events consumed via persistent counters, never pulse waits
     *----------------------------------------------------------------------*/
    task run_transaction;
        input [7:0]   w_label;
        input [1:0]   w_sdi;
        input [18:0]  w_data;
        input [1:0]   w_ssm;
        input [31:0]  corrupt_mask;    /* serial bits to invert          */
        input [31:0]  suppress_mask;   /* serial bits to force low       */
        input         arm_rx;          /* issue rx_start (arm receiver)  */
        input integer inj_class;       /* injected class label           */
        input [255:0] txn_tag;
        input integer quiet;           /* 1 = condensed log line         */

        integer   tx_before, rx_before, i, k, n;
        reg [31:0] orig_exp, wire_exp, recv_exp_word;
        reg        recv_exp_par;
        reg        fail, detected, wire_ok;
        integer    tx_dur, rx_lat;

        begin
            txn_id          = txn_id + 1;
            total_tests     = total_tests + 1;
            seed_at_txn     = user_seed;
            orig_exp        = build_serial(w_label, w_sdi, w_data, w_ssm);
            for (k = 0; k < 32; k = k + 1)
                wire_exp[k] = suppress_mask[k] ? 1'b0 :
                              (corrupt_mask[k] ? ~orig_exp[k] : orig_exp[k]);
            recv_exp_word   = word_from_serial(wire_exp);
            recv_exp_par    = (^wire_exp != 1'b1);

            fail        = 1'b0;
            detected    = 1'b0;
            wire_ok     = 1'b1;
            tx_before   = tx_done_count;
            rx_before   = rx_valid_count;

            /*--------- arm receiver (external source latched) ----------*/
            if (arm_rx) begin
                @(negedge clk);
                rx_start = 1'b1;
                @(negedge clk);
                rx_start = 1'b0;
            end

            /*--------- drive TX through the FIU, capture the wire ------*/
            fiu_corrupt = corrupt_mask[0];
            fiu_idle    = suppress_mask[0];
            @(negedge clk);
            label    = w_label;
            sdi      = w_sdi;
            data     = w_data;
            ssm      = w_ssm;
            tx_start = 1'b1;
            @(posedge clk);                       /* word latched, bit0 out */

            for (k = 0; k < 32; k = k + 1) begin
                for (i = 0; i < CYCLES_PER_BIT; i = i + 1) begin
                    @(negedge clk);
                    if (i == 0) begin
                        if (k == 0) tx_start = 1'b0;
                        fiu_corrupt = corrupt_mask[k];
                        fiu_idle    = suppress_mask[k];
                    end
                    if (i == (CYCLES_PER_BIT/2)) begin
                        orig_capture[k] = arinc_tx;      /* FIU input  */
                        wire_capture[k] = arinc_line;    /* FIU output */
                    end
                end
            end
            fiu_corrupt = 1'b0;
            fiu_idle    = 1'b0;
            @(posedge clk);                       /* first gap posedge      */
            @(negedge clk);
            repeat (GAP_CYCLES - 1) @(negedge clk);

            /*--------- consume completion events (bounded polls) -------*/
            n = 0;
            while ((tx_done_count == tx_before) && (n < 4000)) begin
                @(posedge clk);
                n = n + 1;
            end
            n = 0;
            while ((rx_valid_count == rx_before) && arm_rx && (n < 40000)) begin
                @(posedge clk);
                n = n + 1;
            end
            @(negedge clk);

            /*--------- observations (all from DUT outputs / wire) ------*/
            if (orig_capture !== orig_exp) begin
                wire_ok = 0;
                if (!quiet)
                    $display("  [WIRE-PROOF] FIU input != requested word: got=%h exp=%h",
                             orig_capture, orig_exp);
            end
            if (wire_capture !== wire_exp) begin
                wire_ok = 0;
                if (!quiet)
                    $display("  [WIRE-PROOF] FIU output != requested corrupted stream: got=%h exp=%h",
                             wire_capture, wire_exp);
            end
            if (!wire_ok) tb_internal_errors = tb_internal_errors + 1;

            /*--------- timing verification (nominal timing must hold) ---*/
            tx_dur = (tx_done_rise_time - tx_busy_rise_time) / CLK_PERIOD_NS;
            if (tx_done_count == tx_before + 1) begin
                if (tx_dur != TOTAL_TX_CYCLES) begin
                    timing_failures = timing_failures + 1;
                    fail = 1'b1;
                    $display("  [TIMING] TX transaction %0d cycles (expected %0d)",
                             tx_dur, TOTAL_TX_CYCLES);
                end
            end
            if (arm_rx && (rx_valid_count == rx_before + 1)) begin
                rx_lat = (rx_valid_rise_time - rx_arm_time) / CLK_PERIOD_NS;
                if (rx_lat != RX_VALID_DELAY_CYCLES) begin
                    timing_failures = timing_failures + 1;
                    fail = 1'b1;
                    $display("  [TIMING] RX latency %0d cycles (expected %0d)",
                             rx_lat, RX_VALID_DELAY_CYCLES);
                end
            end

            /*--------- print structured transaction log ----------------*/
            if (!quiet) begin
                $display("------------------------------------------------------------");
                $display("Transaction ID      : %0d", txn_id);
                $display("Seed (snapshot)     : %0d", seed_at_txn);
                $display("Fault class         : %0s", class_name(inj_class));
                $display("Tag                 : %0s", txn_tag);
                $display("Original word       : %h", build_word(w_label, w_sdi, w_data, w_ssm));
                $display("Expected word       : %h", word_from_serial(orig_exp));
                $display("Injected stream     : %h", wire_exp);
                $display("Expected RX word    : %h (parity_error=%b)", recv_exp_word, recv_exp_par);
                $display("Actual RX word      : %h (parity_error=%b)",
                         rx_word, parity_error);
                $display("rx_valid=%0d tx_done=%0d  (counters +%0d / +%0d)",
                         (rx_valid_count == rx_before + 1), (tx_done_count == tx_before + 1),
                         rx_valid_count - rx_before, tx_done_count - tx_before);
                $display("TX duration         : %0d cycles (%0d ns)", tx_dur, tx_dur * CLK_PERIOD_NS);
            end

            /*--------- export observations to module level -------------*/
            last_rx_valid_seen = (rx_valid_count == rx_before + 1);
            last_txdone_seen   = (tx_done_count == tx_before + 1);
            last_rx_word_obs   = rx_word;
            last_parity_obs    = parity_error;
            last_wire_ok       = wire_ok;
            last_timing_ok     = !fail;
            last_recv_exp_word = recv_exp_word;
            last_recv_exp_par  = recv_exp_par;
            last_orig_word     = build_word(w_label, w_sdi, w_data, w_ssm);

            /*--------- classification (per injected class) -------------*/
            case (inj_class)

            CLASS_NORMAL: begin
                normal_tests = normal_tests + 1;
                consecutive_error_count = 0;
                if ((rx_valid_count == rx_before + 1) && (rx_word === recv_exp_word) &&
                    (parity_error === 1'b0) && (tx_done_count == tx_before + 1) &&
                    wire_ok && !fail) begin
                    passed_tests = passed_tests + 1;
                    normal_passed = normal_passed + 1;
                    $display("Result              : %0s PASS (normal communication verified)", txn_tag);
                end else begin
                    failed_tests = failed_tests + 1;
                    normal_failed = normal_failed + 1;
                    $display("Result              : FAIL [DUT FAILURE] normal transaction corrupted");
                    if (!quiet)
                        $display("  rx_match=%b par=%b txdone=%b wire_ok=%b",
                                 (rx_word === recv_exp_word), parity_error,
                                 (tx_done_count == tx_before + 1), wire_ok);
                end
                write_csv_row_obs(ROW_TRANSACTION, txn_id, -1, -1, -1,
                    CLASS_NORMAL, -1, -1, w_label, w_label, 1,
                    0, 0, -1, 0, 0, 0, 0, -1,
                    DET_NA,
                    (last_wire_ok && last_timing_ok &&
                     (rx_valid_count == rx_before + 1) && (rx_word === recv_exp_word) &&
                     (parity_error === 1'b0) && (tx_done_count == tx_before + 1))
                        ? VER_PASS : VER_FAIL_DUT,
                    0, CLASS_NORMAL,
                    (rx_word !== recv_exp_word), parity_error,
                    (rx_valid_count == rx_before + 1),
                    (tx_done_count == tx_before + 1));
            end

            CLASS_PARITY: begin
                fault_tests = fault_tests + 1;
                faults_injected = faults_injected + 1;
                parity_faults = parity_faults + 1;
                consecutive_error_count = consecutive_error_count + 1;
                last_fault_txn_id = txn_id;
                last_error_type   = CLASS_PARITY;
                /* single-bit corruption: detection definition (strict):
                 * DETECTED     = rx_valid && rx_word != original && parity_error==1
                 * UNDETECTED   = rx_valid && rx_word != original && parity_error==0
                 *                (impossible for a true single-bit flip; would be
                 *                 a DUT parity-checker failure)
                 * ANOMALY      = DUT raised parity_error but the full response
                 *                does not match the bit-accurate prediction
                 *                (verification cannot establish ground truth) */
                if ((rx_valid_count == rx_before + 1) &&
                    (rx_word !== build_word(w_label, w_sdi, w_data, w_ssm)) &&
                    (parity_error === 1'b1)) begin
                    detected = 1'b1;
                    parity_error_count = parity_error_count + 1;
                    errors_observed    = errors_observed + 1;
                end
                if ((rx_valid_count == rx_before + 1) && (rx_word === recv_exp_word) &&
                    (parity_error === recv_exp_par) && wire_ok && !fail && detected) begin
                    parity_detected = parity_detected + 1;
                    faults_detected = faults_detected + 1;
                    passed_tests = passed_tests + 1;
                    $display("Result              : PASS (FAULT DETECTED BY DUT: parity_error=1, word mismatch, serial pos %0d = word bit %0d [%0s])",
                             fault_pos_scratch, fault_word_bit_scratch,
                             pos_class_name(pos_class_of(fault_pos_scratch)));
                    write_csv_row_obs(ROW_TRANSACTION, txn_id, -1, -1, -1,
                        CLASS_PARITY, -1, fault_pos_scratch, w_label, w_label, 1,
                        0, 0, -1, 0, 0, 0, 0, -1,
                        DET_DUT_DETECTED, VER_PASS, 0, CLASS_PARITY,
                        (rx_word !== recv_exp_word), parity_error,
                        last_rx_valid_seen, last_txdone_seen);
                end else if (detected) begin
                    /* FI-18: DUT flagged parity but response != prediction:
                     * ground truth cannot be established -> untrustworthy row */
                    parity_anomalies = parity_anomalies + 1;
                    faults_unresolved = faults_unresolved + 1;
                    failed_tests = failed_tests + 1;
                    $display("Result              : FAIL [DUT FAILURE] parity flagged but response != bit-accurate prediction (row tagged HEALTH_UNRELIABLE)");
                    write_csv_row_obs(ROW_TRANSACTION, txn_id, -1, -1, -1,
                        CLASS_PARITY, -1, fault_pos_scratch, w_label, w_label, 1,
                        0, 0, -1, 0, 0, 0, 0, -1,
                        DET_DUT_DETECTED, VER_FAIL_FRAMEWORK, 0, HEALTH_UNRELIABLE,
                        (rx_word !== recv_exp_word), parity_error,
                        last_rx_valid_seen, last_txdone_seen);
                end else begin
                    /* FI-18: genuine DUT miss of a single-bit fault: keep the
                     * ground-truth class, mark DUT FAIL (never health=98) */
                    parity_undetected = parity_undetected + 1;
                    faults_undetected = faults_undetected + 1;
                    failed_tests = failed_tests + 1;
                    $display("Result              : FAIL [DUT FAILURE] single-bit parity fault NOT detected");
                    write_csv_row_obs(ROW_TRANSACTION, txn_id, -1, -1, -1,
                        CLASS_PARITY, -1, fault_pos_scratch, w_label, w_label, 1,
                        0, 0, -1, 0, 0, 0, 0, -1,
                        DET_DUT_MISSED, VER_FAIL_DUT, 0, CLASS_PARITY,
                        (rx_word !== recv_exp_word), parity_error,
                        last_rx_valid_seen, last_txdone_seen);
                end
            end

            default: begin
                /* wrapper-classified classes (two-bit, timeout, fifo,
                 * label, idle, repeated, high-rate): the specialized task
                 * that called the engine classifies from last_* exports. */
            end

            endcase
        end
    endtask

    /*------------------------------------------------------------------------
     * SPECIALIZED FAULT TASKS (wrapper classification, honest ledgers)
     *----------------------------------------------------------------------*/

    /* helper: random word with a valid label */
    task random_word;
        output [7:0]  o_label;
        output [1:0]  o_sdi;
        output [18:0] o_data;
        output [1:0]  o_ssm;
        begin
            o_label = pick_valid_label(0);
            o_sdi   = rand_range(0, 3);
            o_data  = rand_range(0, 524287);
            o_ssm   = rand_range(0, 3);
        end
    endtask

    /* single-bit parity fault at a random serial position */
    task run_parity_fault_rand;
        input integer quiet;
        integer sp;
        reg [31:0] mask;
        reg [7:0] w_label; reg [1:0] w_sdi; reg [18:0] w_data; reg [1:0] w_ssm;
        begin
            random_word(w_label, w_sdi, w_data, w_ssm);
            sp   = rand_range(0, 31);
            mask = 32'h00000001 << sp;
            fault_pos_scratch    = sp;
            fault_word_bit_scratch = word_bit_of_serial(sp);
            case (pos_class_of(sp))
                POS_LABEL  : bit_faults_by_label  = bit_faults_by_label  + 1;
                POS_SDI    : bit_faults_by_sdi    = bit_faults_by_sdi    + 1;
                POS_DATA   : bit_faults_by_data   = bit_faults_by_data   + 1;
                POS_SSM    : bit_faults_by_ssm    = bit_faults_by_ssm    + 1;
                POS_PARITY : bit_faults_by_parity = bit_faults_by_parity + 1;
            endcase
            run_transaction(w_label, w_sdi, w_data, w_ssm, mask, 32'h0, 1'b1,
                            CLASS_PARITY, "PARITY_FAULT(random pos)", quiet);
        end
    endtask

    /* single-bit parity fault at a directed serial position (mapping proof) */
    task run_parity_fault_at;
        input integer sp;
        input integer quiet;
        reg [31:0] mask;
        reg [7:0] w_label; reg [1:0] w_sdi; reg [18:0] w_data; reg [1:0] w_ssm;
        begin
            random_word(w_label, w_sdi, w_data, w_ssm);
            mask = 32'h00000001 << sp;
            fault_pos_scratch    = sp;
            fault_word_bit_scratch = word_bit_of_serial(sp);
            case (pos_class_of(sp))
                POS_LABEL  : bit_faults_by_label  = bit_faults_by_label  + 1;
                POS_SDI    : bit_faults_by_sdi    = bit_faults_by_sdi    + 1;
                POS_DATA   : bit_faults_by_data   = bit_faults_by_data   + 1;
                POS_SSM    : bit_faults_by_ssm    = bit_faults_by_ssm    + 1;
                POS_PARITY : bit_faults_by_parity = bit_faults_by_parity + 1;
            endcase
            run_transaction(w_label, w_sdi, w_data, w_ssm, mask, 32'h0, 1'b1,
                            CLASS_PARITY, "PARITY_FAULT(directed pos)", quiet);
        end
    endtask

    /* two-bit corruption: EXPECTED LIMITATION of odd parity.
     * FI-05: limitation counters increment only when the limitation
     * condition is actually observed. */
    task run_two_bit_fault;
        input integer pa;
        input integer pb;
        reg [31:0] mask;
        reg [7:0] w_label; reg [1:0] w_sdi; reg [18:0] w_data; reg [1:0] w_ssm;
        begin
            fault_tests = fault_tests + 1;
            random_word(w_label, w_sdi, w_data, w_ssm);
            mask = (32'h00000001 << pa) | (32'h00000001 << pb);
            fault_pos_scratch    = pa;
            fault_word_bit_scratch = word_bit_of_serial(pa);
            run_transaction(w_label, w_sdi, w_data, w_ssm, mask, 32'h0, 1'b1,
                            CLASS_TWO_BIT, "TWO_BIT_FAULT", 1'b0);
            two_bit_faults = two_bit_faults + 1;
            faults_injected = faults_injected + 1;
            consecutive_error_count = consecutive_error_count + 1;
            last_fault_txn_id = txn_id;
            last_error_type   = CLASS_PARITY;
            if (last_rx_valid_seen && (last_rx_word_obs === last_recv_exp_word) &&
                (last_parity_obs === last_recv_exp_par) && (last_recv_exp_par === 1'b0) &&
                last_wire_ok && last_timing_ok) begin
                two_bit_limitations  = two_bit_limitations + 1;
                expected_limitations = expected_limitations + 1;
                errors_observed      = errors_observed + 1;
                passed_tests = passed_tests + 1;
                $display("Result              : EXPECTED LIMITATION OBSERVED");
                $display("                      two-bit corruption escaped odd parity");
                $display("                      (rx_word differs, parity_error=0) - correct parity mathematics");
                write_csv_row_obs(ROW_TRANSACTION, txn_id, -1, -1, -1,
                    CLASS_PARITY, CLASS_TWO_BIT, pa, w_label, w_label, 1,
                    0, 0, -1, 0, 0, 0, 0, -1,
                    DET_EXPECTED_LIMIT, VER_PASS, 1, CLASS_PARITY,
                    (last_rx_word_obs !== last_recv_exp_word), last_parity_obs,
                    last_rx_valid_seen, last_txdone_seen);
            end else begin
                faults_unresolved = faults_unresolved + 1;
                failed_tests = failed_tests + 1;
                $display("Result              : FAIL [DUT FAILURE] two-bit response violates parity mathematics");
                write_csv_row_obs(ROW_TRANSACTION, txn_id, -1, -1, -1,
                    CLASS_PARITY, CLASS_TWO_BIT, pa, w_label, w_label, 1,
                    0, 0, -1, 0, 0, 0, 0, -1,
                    DET_NA, VER_FAIL_FRAMEWORK, 0, HEALTH_UNRELIABLE,
                    (last_rx_word_obs !== last_recv_exp_word), last_parity_obs,
                    last_rx_valid_seen, last_txdone_seen);
            end
        end
    endtask

    /*------------------------------------------------------------------------
     * COMMUNICATION TIMEOUT (FI-03/04/05 - corrected model)
     *
     * The Review-1 RX is rx_start-armed and then blindly samples 32 bit
     * times: an ARMED receiver on a silent line WILL complete a hallucinated
     * zero word (rx_valid=1, rx_word=0, parity_error=1). A true timeout with
     * NO rx_valid therefore requires an UN-ARMED receiver. The four honest
     * scenarios are:
     *   subtype 0  TRUNCATED WORD      : leading bits real, trailing bits
     *                                    suppressed -> RX completes a
     *                                    corrupted word (data corruption,
     *                                    classified separately from a true
     *                                    timeout, recorded as its own case)
     *   subtype 1  SILENT BUS, ARMED RX: whole word suppressed, RX armed ->
     *                                    false reception (hallucinated zero
     *                                    word) documented bit-accurately
     *   subtype 2  NO COMMUNICATION    : whole word suppressed, RX NOT armed
     *                                    -> wait TIMEOUT_THRESHOLD with
     *                                    rx_before/rx_after check; NO rx_valid
     *   subtype 3  ARMED RX, NO TX     : RX armed, no transmission started
     *                                    -> hallucinated zero word predicted
     *                                    and verified (no-activity-qualifier
     *                                    limitation of the Review-1 RX)
     * The RTL has NO timeout detector: every verified case is an EXPECTED
     * LIMITATION observed at verification level (FI-05: counters increment
     * only after verification).
     *----------------------------------------------------------------------*/
    task run_timeout_fault;
        input integer subtype;
        reg [31:0] sup_mask;
        reg [7:0] w_label; reg [1:0] w_sdi; reg [18:0] w_data; reg [1:0] w_ssm;
        integer k, n, elapsed, rx_before2;
        reg [255:0] sub_name;
        reg verified;
        begin
            fault_tests = fault_tests + 1;
            faults_injected = faults_injected + 1;
            timeout_faults = timeout_faults + 1;
            random_word(w_label, w_sdi, w_data, w_ssm);
            sup_mask = 32'h00000000;
            sub_name = "TIMEOUT";
            fault_pos_scratch = -1;
            fault_word_bit_scratch = -1;
            verified = 1'b0;
            elapsed  = 0;

            if (subtype == 0) begin
                k = rand_range(4, 28);
                sup_mask = 32'hFFFFFFFF << k;
                sub_name = "TIMEOUT_TRUNCATED_WORD";
            end else if (subtype == 1) begin
                sup_mask = 32'hFFFFFFFF;
                sub_name = "TIMEOUT_SILENT_BUS_ARMED_RX";
            end else if (subtype == 2) begin
                sup_mask = 32'hFFFFFFFF;
                sub_name = "TIMEOUT_NO_COMMUNICATION";
            end else begin
                sub_name = "TIMEOUT_ARMED_RX_NO_TX";
            end

            if (subtype != 3) begin
                run_transaction(w_label, w_sdi, w_data, w_ssm, 32'h0, sup_mask,
                                (subtype != 2), CLASS_TIMEOUT, sub_name, 1'b0);
            end

            if (subtype == 2) begin
                /* FI-03: snapshot AFTER the engine, then wait out the full
                 * threshold and prove no reception event occurred. */
                rx_before2 = rx_valid_count;
                for (n = 0; n < timeout_threshold_cycles; n = n + 1)
                    @(posedge clk);
                @(negedge clk);
                elapsed = timeout_threshold_cycles;
                if (rx_valid_count == rx_before2) begin
                    verified = 1'b1;
                    last_rx_valid_seen = 1'b0;
                    last_txdone_seen   = 1'b1;
                    last_rx_word_obs   = rx_word;
                    last_parity_obs    = parity_error;
                    last_wire_ok       = 1'b1;
                    last_timing_ok     = 1'b1;
                    last_recv_exp_word = 32'h0;
                    last_recv_exp_par  = 1'b1;
                end else begin
                    last_rx_valid_seen = 1'b1;
                    last_txdone_seen   = 1'b1;
                    last_wire_ok       = 1'b1;
                    last_timing_ok     = 1'b1;
                    $display("  [TIMEOUT-2] UNEXPECTED rx_valid during no-communication window");
                end
            end else if (subtype == 3) begin
                /* armed RX, no TX: hallucination must arrive bit-accurately */
                total_tests = total_tests + 1;
                txn_id      = txn_id + 1;      /* RX event = transaction */
                seed_at_txn = user_seed;
                @(negedge clk);
                rx_start = 1'b1;
                @(negedge clk);
                rx_start = 1'b0;
                rx_before2 = rx_valid_count;
                /* wait past arm + one word time + margin */
                repeat (RX_VALID_DELAY_CYCLES + 2 * CYCLES_PER_BIT) @(posedge clk);
                @(negedge clk);
                elapsed = (rx_valid_rise_time - rx_arm_time) / CLK_PERIOD_NS;
                if ((rx_valid_count == rx_before2 + 1) && (rx_word === 32'h0) &&
                    (parity_error === 1'b1) && (elapsed == RX_VALID_DELAY_CYCLES)) begin
                    verified = 1'b1;
                    last_rx_valid_seen = 1'b1;
                    last_txdone_seen   = 1'b0;
                    last_rx_word_obs   = rx_word;
                    last_parity_obs    = parity_error;
                    last_wire_ok       = 1'b1;
                    last_timing_ok     = 1'b1;
                    last_recv_exp_word = 32'h0;
                    last_recv_exp_par  = 1'b1;
                end else begin
                    last_rx_valid_seen = (rx_valid_count == rx_before2 + 1);
                    last_txdone_seen   = 1'b0;
                    last_wire_ok       = 1'b1;
                    last_timing_ok     = (elapsed == RX_VALID_DELAY_CYCLES);
                    $display("  [TIMEOUT-3] armed-RX response != predicted hallucination (word=%h par=%b lat=%0d)",
                             rx_word, parity_error, elapsed);
                end
            end else begin
                elapsed = (rx_valid_rise_time - rx_arm_time) / CLK_PERIOD_NS;
                verified = last_rx_valid_seen &&
                           (last_rx_word_obs === last_recv_exp_word) &&
                           (last_parity_obs === last_recv_exp_par) &&
                           last_wire_ok && last_timing_ok;
            end

            timeout_count = timeout_count + 1;
            consecutive_error_count = consecutive_error_count + 1;
            last_fault_txn_id = txn_id;
            last_error_type   = CLASS_TIMEOUT;
            last_idle_duration = elapsed;

            $display("------------------------------------------------------------");
            $display("Transaction ID      : %0d", txn_id);
            $display("Fault class         : %0s", class_name(CLASS_TIMEOUT));
            $display("Tag                 : %0s", sub_name);
            $display("Timeout threshold   : %0d cycles [PROJECT-DEFINED]", timeout_threshold_cycles);
            $display("Elapsed             : %0d cycles", elapsed);
            $display("rx_valid seen       : %0d", last_rx_valid_seen);

            if (verified) begin
                timeout_observed = timeout_observed + 1;
                expected_limitations = expected_limitations + 1;
                errors_observed = errors_observed + 1;
                passed_tests = passed_tests + 1;
                $display("Result              : PASS (fault observed at verification level)");
                if (subtype == 0)
                    $display("                      RX completed an INCOMPLETE word (trailing bits read as 0) after %0d cycles", elapsed);
                if (subtype == 1)
                    $display("                      ARMED RX on SILENT BUS: DUT produced a FALSE RECEPTION (hallucinated zero word) after %0d cycles", elapsed);
                if (subtype == 2)
                    $display("                      NO reception event within the %0d-cycle threshold (rx_valid_count unchanged)", timeout_threshold_cycles);
                if (subtype == 3)
                    $display("                      ARMED RX with NO transmission: hallucinated zero word at %0d cycles (RX has no activity qualifier)", elapsed);
                $display("                      DUT TIMEOUT DETECTOR: ABSENT - EXPECTED LIMITATION (no such RTL hardware)");
                write_csv_row_obs(ROW_TRANSACTION, txn_id, -1, -1, -1,
                    CLASS_TIMEOUT, -1, -1, -1, -1, -1,
                    elapsed, 0, -1, 0, 0, 0, 0, -1,
                    DET_EXPECTED_LIMIT, VER_PASS, 1, CLASS_TIMEOUT,
                    (last_rx_word_obs !== last_recv_exp_word), last_parity_obs,
                    last_rx_valid_seen, last_txdone_seen);
            end else begin
                /* FI-05: failed verification is NOT booked as a limitation */
                timeout_unresolved = timeout_unresolved + 1;
                faults_unresolved  = faults_unresolved + 1;
                failed_tests = failed_tests + 1;
                $display("Result              : FAIL [FRAMEWORK FAILURE] timeout response != bit-accurate prediction");
                write_csv_row_obs(ROW_TRANSACTION, txn_id, -1, -1, -1,
                    CLASS_TIMEOUT, -1, -1, -1, -1, -1,
                    elapsed, 0, -1, 0, 0, 0, 0, -1,
                    DET_NA, VER_FAIL_FRAMEWORK, 0, HEALTH_UNRELIABLE,
                    (last_rx_word_obs !== last_recv_exp_word), last_parity_obs,
                    last_rx_valid_seen, last_txdone_seen);
            end
        end
    endtask

    /* verification-modeled FIFO overflow around a verified normal transfer.
     * FI-13: per-case event DELTA is verified (never cumulative). */
    task run_fifo_overflow_case;
        input integer burst_extra;
        reg [7:0] w_label; reg [1:0] w_sdi; reg [18:0] w_data; reg [1:0] w_ssm;
        integer j, planned_events, occ_before, ev_before, ev_delta;
        begin
            fault_tests = fault_tests + 1;
            random_word(w_label, w_sdi, w_data, w_ssm);
            while (fifo_occ > 0) fifo_model_read;  /* drain without underflow */
            planned_events = 1 + burst_extra;
            run_transaction(w_label, w_sdi, w_data, w_ssm, 32'h0, 32'h0, 1'b1,
                            CLASS_FIFO_OVF, "FIFO_OVERFLOW(verification-modeled)", 1'b0);
            occ_before = fifo_occ;
            ev_before  = fifo_overflow_events;
            for (j = 0; j < fifo_depth + planned_events; j = j + 1)
                fifo_model_write(rx_word);
            ev_delta = fifo_overflow_events - ev_before;
            consecutive_error_count = consecutive_error_count + 1;
            last_fault_txn_id = txn_id;
            last_error_type   = CLASS_FIFO_OVF;
            if (last_rx_valid_seen && (last_rx_word_obs === last_recv_exp_word) &&
                last_wire_ok && last_timing_ok && (ev_delta == planned_events)) begin
                fifo_overflow_expected_limit = fifo_overflow_expected_limit + ev_delta;
                expected_limitations = expected_limitations + ev_delta;
                faults_injected = faults_injected + ev_delta;
                fifo_overflow_count = fifo_overflow_count + ev_delta;
                errors_observed = errors_observed + ev_delta;
                passed_tests = passed_tests + 1;
                $display("Result              : PASS (verification-modeled FIFO overflow)");
                $display("                      occupancy_before=%0d writes_attempted=%0d overflow_events=%0d (planned %0d)",
                         occ_before, fifo_depth + planned_events, ev_delta, planned_events);
                $display("                      NO FIFO HARDWARE IN RTL - VERIFICATION-MODELED EVENT (expected limitation)");
                write_csv_row_obs(ROW_EVENT, -1, -1, event_id, txn_id,
                    CLASS_FIFO_OVF, -1, -1, -1, -1, -1,
                    0, 0, -1, 0, 0, 0, 0, -1,
                    DET_EXPECTED_LIMIT, VER_PASS, 1, CLASS_FIFO_OVF,
                    0, 0, last_rx_valid_seen, last_txdone_seen);
            end else begin
                fifo_overflow_unresolved = fifo_overflow_unresolved + ev_delta;
                faults_unresolved = faults_unresolved + ev_delta;
                faults_injected = faults_injected + ev_delta;
                fifo_overflow_count = fifo_overflow_count + ev_delta;
                failed_tests = failed_tests + 1;
                $display("Result              : FAIL [FRAMEWORK FAILURE] FIFO overflow case inconsistent (delta=%0d planned=%0d)",
                         ev_delta, planned_events);
                write_csv_row_obs(ROW_EVENT, -1, -1, event_id, txn_id,
                    CLASS_FIFO_OVF, -1, -1, -1, -1, -1,
                    0, 0, -1, 0, 0, 0, 0, -1,
                    DET_NA, VER_FAIL_FRAMEWORK, 0, HEALTH_UNRELIABLE,
                    0, 0, last_rx_valid_seen, last_txdone_seen);
            end
            event_id = event_id + 1;
            /* drain the model so later cases start clean (never read empty:
             * spurious reads would contaminate the underflow ledger) */
            while (fifo_occ > 0)
                fifo_model_read;
        end
    endtask

    /* verification-modeled FIFO underflow around a verified normal transfer.
     * FI-13: per-case event DELTA is verified (never cumulative). */
    task run_fifo_underflow_case;
        input integer burst_reads;
        reg [7:0] w_label; reg [1:0] w_sdi; reg [18:0] w_data; reg [1:0] w_ssm;
        integer j, planned_events, occ_before, ev_before, ev_delta;
        begin
            fault_tests = fault_tests + 1;
            random_word(w_label, w_sdi, w_data, w_ssm);
            while (fifo_occ > 0) fifo_model_read;  /* ensure empty */
            planned_events = burst_reads;
            run_transaction(w_label, w_sdi, w_data, w_ssm, 32'h0, 32'h0, 1'b1,
                            CLASS_FIFO_UNF, "FIFO_UNDERFLOW(verification-modeled)", 1'b0);
            occ_before = fifo_occ;
            ev_before  = fifo_underflow_events;
            for (j = 0; j < planned_events; j = j + 1)
                fifo_model_read;
            ev_delta = fifo_underflow_events - ev_before;
            consecutive_error_count = consecutive_error_count + 1;
            last_fault_txn_id = txn_id;
            last_error_type   = CLASS_FIFO_UNF;
            if (last_rx_valid_seen && (last_rx_word_obs === last_recv_exp_word) &&
                last_wire_ok && last_timing_ok && (ev_delta == planned_events)) begin
                fifo_underflow_expected_limit = fifo_underflow_expected_limit + ev_delta;
                expected_limitations = expected_limitations + ev_delta;
                faults_injected = faults_injected + ev_delta;
                fifo_underflow_count = fifo_underflow_count + ev_delta;
                errors_observed = errors_observed + ev_delta;
                passed_tests = passed_tests + 1;
                $display("Result              : PASS (verification-modeled FIFO underflow)");
                $display("                      occupancy_before=%0d reads_attempted=%0d underflow_events=%0d (planned %0d)",
                         occ_before, planned_events, ev_delta, planned_events);
                $display("                      NO FIFO HARDWARE IN RTL - VERIFICATION-MODELED EVENT (expected limitation)");
                write_csv_row_obs(ROW_EVENT, -1, -1, event_id, txn_id,
                    CLASS_FIFO_UNF, -1, -1, -1, -1, -1,
                    0, 0, -1, 0, 0, 0, 0, -1,
                    DET_EXPECTED_LIMIT, VER_PASS, 1, CLASS_FIFO_UNF,
                    0, 0, last_rx_valid_seen, last_txdone_seen);
            end else begin
                fifo_underflow_unresolved = fifo_underflow_unresolved + ev_delta;
                faults_unresolved = faults_unresolved + ev_delta;
                faults_injected = faults_injected + ev_delta;
                fifo_underflow_count = fifo_underflow_count + ev_delta;
                failed_tests = failed_tests + 1;
                $display("Result              : FAIL [FRAMEWORK FAILURE] FIFO underflow case inconsistent (delta=%0d planned=%0d)",
                         ev_delta, planned_events);
                write_csv_row_obs(ROW_EVENT, -1, -1, event_id, txn_id,
                    CLASS_FIFO_UNF, -1, -1, -1, -1, -1,
                    0, 0, -1, 0, 0, 0, 0, -1,
                    DET_NA, VER_FAIL_FRAMEWORK, 0, HEALTH_UNRELIABLE,
                    0, 0, last_rx_valid_seen, last_txdone_seen);
            end
            event_id = event_id + 1;
        end
    endtask

    /* APPLICATION-DEFINED invalid label (DUT has no label validator).
     * FI-14: original/injected label provenance recorded. */
    task run_invalid_label_case;
        input [7:0] bad_label;
        input integer quiet;
        reg [7:0] w_label; reg [1:0] w_sdi; reg [18:0] w_data; reg [1:0] w_ssm;
        begin
            fault_tests = fault_tests + 1;
            faults_injected = faults_injected + 1;
            invalid_label_faults = invalid_label_faults + 1;
            random_word(w_label, w_sdi, w_data, w_ssm);
            last_orig_label   = w_label;
            last_inj_label    = bad_label;
            last_label_supported = 0;
            w_label = bad_label;
            fault_pos_scratch = -1;
            fault_word_bit_scratch = -1;
            run_transaction(w_label, w_sdi, w_data, w_ssm, 32'h0, 32'h0, 1'b1,
                            CLASS_INVALID_LBL, "INVALID_LABEL(application-defined)", quiet);
            invalid_label_count = invalid_label_count + 1;
            consecutive_error_count = consecutive_error_count + 1;
            last_fault_txn_id = txn_id;
            last_error_type   = CLASS_INVALID_LBL;
            if (!label_is_valid(bad_label)) begin
                /* framework sanity: the label really is outside the table */
            end else begin
                tb_internal_errors = tb_internal_errors + 1;
                $display("  [LABEL-SANITY] injected label %h IS in the supported set - case invalid", bad_label);
            end
            if (last_rx_valid_seen && (last_rx_word_obs === last_recv_exp_word) &&
                (last_parity_obs === 1'b0) && last_wire_ok && last_timing_ok) begin
                invalid_label_expected_limit = invalid_label_expected_limit + 1;
                expected_limitations = expected_limitations + 1;
                errors_observed = errors_observed + 1;
                passed_tests = passed_tests + 1;
                if (!quiet) begin
                    $display("Result              : PASS (fault observed at verification level)");
                    $display("                      original_label=%h injected_label=%h supported_label_status=INVALID", last_orig_label, bad_label);
                    $display("                      invalid_label_condition: received label NOT in APPLICATION-DEFINED supported set");
                    $display("                      DUT accepted the word: NO label validator in RTL - EXPECTED LIMITATION");
                    $display("                      NOT an ARINC protocol violation claim");
                end
                write_csv_row_obs(ROW_TRANSACTION, txn_id, -1, -1, -1,
                    CLASS_INVALID_LBL, -1, -1, last_orig_label, bad_label, 0,
                    0, 0, -1, 0, 0, 0, 0, -1,
                    DET_EXPECTED_LIMIT, VER_PASS, 1, CLASS_INVALID_LBL,
                    0, last_parity_obs, last_rx_valid_seen, last_txdone_seen);
            end else begin
                invalid_label_unresolved = invalid_label_unresolved + 1;
                faults_unresolved = faults_unresolved + 1;
                failed_tests = failed_tests + 1;
                $display("Result              : FAIL [DUT FAILURE] unexpected DUT response on invalid-label word");
                write_csv_row_obs(ROW_TRANSACTION, txn_id, -1, -1, -1,
                    CLASS_INVALID_LBL, -1, -1, last_orig_label, bad_label, 0,
                    0, 0, -1, 0, 0, 0, 0, -1,
                    DET_NA, VER_FAIL_FRAMEWORK, 0, HEALTH_UNRELIABLE,
                    0, last_parity_obs, last_rx_valid_seen, last_txdone_seen);
            end
        end
    endtask

    /*------------------------------------------------------------------------
     * BUS IDLE (FI-15): suppression of ALL activity for a duration that
     * exceeds the PROJECT-DEFINED IDLE_THRESHOLD. The classification
     * condition (idle_duration >= threshold AND no TX/RX activity) is
     * recorded explicitly. A separate directed gap control proves that a
     * normal 2000-cycle interword gap is NOT classified as an idle error.
     *----------------------------------------------------------------------*/
    task run_bus_idle_case;
        input integer min_cycles;
        integer idle_wait, n;
        integer tx_b, rx_b;
        begin
            fault_tests = fault_tests + 1;
            faults_injected = faults_injected + 1;
            bus_idle_cases = bus_idle_cases + 1;
            total_tests = total_tests + 1;
            txn_id = txn_id + 1;              /* idle window = measured event */
            seed_at_txn = user_seed;
            idle_wait = min_cycles + rand_range(0, 4000);
            tx_b = tx_done_count;
            rx_b = rx_valid_count;
            $display("------------------------------------------------------------");
            $display("Transaction ID      : %0d", txn_id);
            $display("Fault class         : BUS_IDLE_ERROR");
            $display("Idle threshold      : %0d cycles (PROJECT-DEFINED)", idle_threshold_cycles);
            for (n = 0; n < idle_wait; n = n + 1)
                @(posedge clk);
            @(negedge clk);
            last_idle_event = ((tx_done_count == tx_b) && (rx_valid_count == rx_b) &&
                               (tx_busy === 1'b0) && (rx_busy === 1'b0));
            last_idle_duration = idle_wait;
            consecutive_error_count = consecutive_error_count + 1;
            last_fault_txn_id = txn_id;
            last_error_type   = CLASS_BUS_IDLE;
            if (last_idle_event && (idle_wait >= idle_threshold_cycles)) begin
                bus_idle_expected_limit = bus_idle_expected_limit + 1;
                expected_limitations = expected_limitations + 1;
                errors_observed = errors_observed + 1;
                bus_idle_count = bus_idle_count + 1;
                passed_tests = passed_tests + 1;
                $display("Result              : PASS (fault observed at verification level)");
                $display("                      idle_duration=%0d cycles >= IDLE_THRESHOLD=%0d -> BUS IDLE condition", idle_wait, idle_threshold_cycles);
                $display("                      (%0d us with no TX/RX activity)", idle_wait * CLK_PERIOD_NS / 1000);
                $display("                      DUT IDLE DETECTOR: ABSENT - EXPECTED LIMITATION (no such RTL hardware)");
                write_csv_row_obs(ROW_EVENT, -1, -1, event_id, -1,
                    CLASS_BUS_IDLE, -1, -1, -1, -1, -1,
                    idle_wait, 0, -1, 0, 0, 0, 0, -1,
                    DET_EXPECTED_LIMIT, VER_PASS, 1, CLASS_BUS_IDLE,
                    0, 0, 0, 0);
            end else begin
                bus_idle_unresolved = bus_idle_unresolved + 1;
                faults_unresolved = faults_unresolved + 1;
                failed_tests = failed_tests + 1;
                $display("Result              : FAIL [DUT FAILURE] activity observed during forced idle window");
                write_csv_row_obs(ROW_EVENT, -1, -1, event_id, -1,
                    CLASS_BUS_IDLE, -1, -1, -1, -1, -1,
                    idle_wait, 0, -1, 0, 0, 0, 0, -1,
                    DET_NA, VER_FAIL_DUT, 0, CLASS_BUS_IDLE,
                    0, 0, 0, 0);
            end
            event_id = event_id + 1;
        end
    endtask

    /* FI-15 positive control: a normal interword gap (GAP_CYCLES=2000) is
     * valid protocol behavior and must NOT be classified as a bus idle
     * error. Runs one normal transaction, then checks that the bus-idle
     * ledger did not move and that the gap is below the idle threshold. */
    task check_normal_gap_not_idle;
        integer idle_before;
        reg [7:0] w_label; reg [1:0] w_sdi; reg [18:0] w_data; reg [1:0] w_ssm;
        begin
            total_tests = total_tests + 1;
            idle_before = bus_idle_count;
            random_word(w_label, w_sdi, w_data, w_ssm);
            run_transaction(w_label, w_sdi, w_data, w_ssm, 32'h0, 32'h0, 1'b1,
                            CLASS_NORMAL, "GAP_CONTROL(normal gap)", 1'b0);
            if ((bus_idle_count == idle_before) && (GAP_CYCLES < idle_threshold_cycles) &&
                last_wire_ok && last_timing_ok) begin
                passed_tests = passed_tests + 1;
                $display("Result              : PASS (GAP CONTROL)");
                $display("                      normal interword gap = %0d cycles < IDLE_THRESHOLD=%0d", GAP_CYCLES, idle_threshold_cycles);
                $display("                      normal gap NOT classified as BUS_IDLE_ERROR (bus_idle_count unchanged)");
            end else begin
                failed_tests = failed_tests + 1;
                $display("Result              : FAIL [FRAMEWORK FAILURE] normal interword gap misclassified as bus idle");
            end
        end
    endtask

    /*------------------------------------------------------------------------
     * REPEATED COMMUNICATION ERROR BLOCK (FI-02/06/11)
     * Window-level record: the repetition condition is PROVEN by running
     * rep_count genuinely consecutive fault transactions (each with its own
     * completed transaction) and recording the pattern as an analysis
     * classification. Underlying DUT detection is counted separately.
     *----------------------------------------------------------------------*/
    task run_repeated_block;
        input integer base_class;     /* CLASS_PARITY or CLASS_INVALID_LBL */
        input integer rep_count;
        integer m, gap_since, member_fail_before, member_dut_detected;
        integer first_member_txn, last_member_txn, successes_between;
        reg verified;
        begin
            fault_tests = fault_tests + 1;
            repeated_error_cases = repeated_error_cases + 1;
            gap_since = txn_id - last_fault_txn_id;
            member_fail_before = failed_tests;
            member_dut_detected = 0;
            first_member_txn = txn_id + 1;
            verified = 1'b1;
            $display("============================================================");
            $display("REPEATED ERROR BLOCK: base=%0s repeat_count=%0d (gap_since_last=%0d)",
                     class_name(base_class), rep_count, gap_since);
            $display("============================================================");
            for (m = 0; m < rep_count; m = m + 1) begin
                if (base_class == CLASS_PARITY) begin
                    run_parity_fault_rand(1'b0);
                    if (last_parity_obs === 1'b1) member_dut_detected = member_dut_detected + 1;
                end else begin
                    run_invalid_label_case(pick_invalid_label(0), 1'b0);
                    /* no DUT label validator: cannot be flagged by the DUT */
                end
                if (!last_wire_ok || !last_timing_ok) verified = 1'b0;
            end
            last_member_txn = txn_id;
            /* successes between errors: consecutive members -> expected 0 */
            successes_between = (last_member_txn - first_member_txn + 1) - rep_count;

            repeated_error_count = repeated_error_count + 1;
            window_id = window_id + 1;
            consecutive_error_count = consecutive_error_count + rep_count;

            if (verified && (member_fail_before == failed_tests)) begin
                repeated_error_patterns_observed = repeated_error_patterns_observed + 1;
                if (member_dut_detected > 0)
                    repeated_underlying_dut_detected = repeated_underlying_dut_detected + 1;
                /* window-level records never touch total/passed/failed:
                 * the member transactions were already counted (no
                 * double-counting); E10 is the window-level ledger */
                $display("REPEATED BLOCK SUMMARY: REPEATED ERROR PATTERN OBSERVED (analysis classification, NOT hardware detection)");
                $display("                        repeat_count=%0d consecutive_error_count=%0d successes_between=%0d",
                         rep_count, consecutive_error_count, successes_between);
                $display("                        underlying_error_type=%0s underlying DUT-detected members=%0d/%0d",
                         class_name(base_class), member_dut_detected, rep_count);
                if (base_class == CLASS_INVALID_LBL)
                    $display("                        INVALID_LABEL base: DUT has no label validator, underlying detection impossible (honest 0)");
                write_csv_row(ROW_WINDOW, -1, window_id, -1, first_member_txn,
                    CLASS_REPEATED, base_class, -1, -1, -1, -1,
                    0, 0, -1, rep_count, successes_between, rep_count, rep_count,
                    base_class, DET_ANALYSIS, VER_PASS, 0, CLASS_REPEATED);
            end else begin
                repeated_error_failed = repeated_error_failed + 1;
                /* member failures were already counted in failed_tests by
                 * their own transactions (no double-counting) */
                $display("REPEATED BLOCK SUMMARY: FAIL [FRAMEWORK FAILURE] block member verification failed");
                write_csv_row(ROW_WINDOW, -1, window_id, -1, first_member_txn,
                    CLASS_REPEATED, base_class, -1, -1, -1, -1,
                    0, 0, -1, rep_count, successes_between, rep_count, rep_count,
                    base_class, DET_ANALYSIS, VER_FAIL_FRAMEWORK, 0, HEALTH_UNRELIABLE);
            end
        end
    endtask

    /*------------------------------------------------------------------------
     * HIGH ERROR RATE WINDOW (FI-07/12/16/17)
     * Window-level statistical classification over error_rate_window
     * transactions. The ground-truth label HIGH_ERROR_RATE is applied ONLY
     * when the measured rate actually meets the configured threshold
     * (>= semantics, boundary exercised explicitly in the directed suite);
     * below-threshold windows are recorded as class 0 with
     * high_error_rate_condition=0. This is an ANALYSIS CLASSIFICATION -
     * the Review-1 DUT has no error-rate detector.
     *----------------------------------------------------------------------*/
    task run_high_rate_window;
        input integer planned_faults;
        input integer win_size;
        integer w, i, p, assigned, win_faults, win_normal;
        integer member_parity, member_label, member_fail_before;
        integer dom_type, win_id_snapshot;
        reg is_fault [0:63];
        reg verified;
        begin
            fault_tests = fault_tests + 1;
            high_error_rate_cases = high_error_rate_cases + 1;
            w = win_size;
            if (w < 2)     w = 2;                 /* FI-17 clamps            */
            if (w > 64)    w = 64;
            p = planned_faults;
            if (p < 0)     p = 0;
            if (p > w)     p = w;                 /* no infinite assignment  */
            for (i = 0; i < w; i = i + 1) is_fault[i] = 1'b0;
            assigned = 0;
            while (assigned < p) begin
                i = rand_range(0, w - 1);
                if (!is_fault[i]) begin
                    is_fault[i] = 1'b1;
                    assigned = assigned + 1;
                end
            end
            win_id_snapshot = window_id + 1;
            $display("============================================================");
            $display("HIGH-RATE WINDOW: window=%0d txns, planned_faults=%0d (threshold=%0d%% PROJECT-DEFINED)",
                     w, p, high_error_rate_threshold_pct);
            $display("============================================================");
            win_faults = 0;
            win_normal = 0;
            member_parity = 0;
            member_label  = 0;
            member_fail_before = failed_tests;
            verified = 1'b1;
            for (i = 0; i < w; i = i + 1) begin
                if (is_fault[i]) begin
                    win_faults = win_faults + 1;
                    if (({$random(rng_seed)} % 2) == 1) begin
                        member_parity = member_parity + 1;
                        run_parity_fault_rand(1'b1);
                        $display("  [WINDOW %0d/%0d] COMBO: PARITY_ERROR within window", i + 1, w);
                    end else begin
                        member_label = member_label + 1;
                        run_invalid_label_case(pick_invalid_label(0), 1'b1);
                        $display("  [WINDOW %0d/%0d] COMBO: INVALID_LABEL within window", i + 1, w);
                    end
                end else begin
                    win_normal = win_normal + 1;
                    run_normal_txn(1'b1);
                end
            end
            if (failed_tests != member_fail_before) verified = 1'b0;
            last_error_rate = (100.0 * win_faults) / w;
            /* dominant error type among faulty members */
            if (member_parity > member_label)      dom_type = CLASS_PARITY;
            else if (member_label > member_parity) dom_type = CLASS_INVALID_LBL;
            else if (member_parity > 0)            dom_type = CLASS_PARITY;
            else                                   dom_type = -1;
            window_id = window_id + 1;
            $display("HIGH-RATE WINDOW SUMMARY: total=%0d faulty=%0d normal=%0d error_rate=%0d%%",
                     w, win_faults, win_normal, $rtoi(last_error_rate));
            $display("                          dominant_error_type=%0s (parity=%0d label=%0d)",
                     (dom_type >= 0) ? class_name(dom_type) : "NONE",
                     member_parity, member_label);
            if (win_faults * 100 >= high_error_rate_threshold_pct * w) begin
                high_error_rate_windows_classified = high_error_rate_windows_classified + 1;
                last_error_type = CLASS_HIGH_RATE;
                $display("                          CLASSIFICATION: HIGH ERROR RATE CLASSIFIED (rate >= threshold; window-level ANALYSIS, not hardware detection)");
                write_csv_row(ROW_WINDOW, -1, window_id, -1, -1,
                    CLASS_HIGH_RATE, -1, -1, -1, -1, -1,
                    0, $rtoi(last_error_rate), 1, 0, 0, w, win_faults, dom_type,
                    DET_ANALYSIS,
                    verified ? VER_PASS : VER_FAIL_FRAMEWORK, 0,
                    verified ? CLASS_HIGH_RATE : HEALTH_UNRELIABLE);
            end else begin
                high_error_rate_windows_below = high_error_rate_windows_below + 1;
                last_error_type = CLASS_NORMAL;
                $display("                          CLASSIFICATION: BELOW_HIGH_ERROR_RATE_THRESHOLD (rate < threshold; recorded as class 0 window)");
                write_csv_row(ROW_WINDOW, -1, window_id, -1, -1,
                    CLASS_NORMAL, -1, -1, -1, -1, -1,
                    0, $rtoi(last_error_rate), 0, 0, 0, w, win_faults, dom_type,
                    DET_ANALYSIS, VER_PASS, 0, CLASS_NORMAL);
            end
            if (!verified) begin
                high_error_rate_failed = high_error_rate_failed + 1;
                /* member failures already counted in failed_tests (no
                 * double-counting); E11 is the window-level ledger */
                $display("                          FAIL [FRAMEWORK FAILURE] window member verification failed");
            end
        end
    endtask

    /*------------------------------------------------------------------------
     * RESET-DURING-FAULT SCENARIOS (FI-01/02/18 corrected)
     *
     * Classified RESET RECOVERY - NOT communication faults. Every variant:
     *   1. proves the DUT is actually active before reset is applied
     *      (or proves the fault is genuinely on the wire first)
     *   2. applies synchronous reset and checks clean outputs (settled
     *      values sampled at a negedge AFTER the reset edge)
     *   3. proves no stale tx_done/rx_valid events for two word times
     *   4. runs a post-reset RECOVERY transaction that must fully pass
     * Corruption uses the SAME time-domain per-bit mechanism as the engine
     * (assert fiu_corrupt during the target serial bit window) - the 1-bit
     * `1'b1 << k` defect FI-01 can never recur.
     *----------------------------------------------------------------------*/
    task run_reset_case;
        input integer variant;     /* 1 parity-fault TX, 2 incomplete word,
                                      3 repeated-error sequence, 4 idle     */
        reg [7:0] w_label; reg [1:0] w_sdi; reg [18:0] w_data; reg [1:0] w_ssm;
        integer tx_b, rx_b, n, i, k, failed_before, t1_txdone_base;
        reg checks_ok, no_stale, fault_on_wire, t1_complete, t2_started;
        reg recovery_ok;
        reg [255:0] vname;
        begin
            total_tests = total_tests + 1;
            reset_tests = reset_tests + 1;
            checks_ok = 1'b1;
            fault_on_wire = 1'b0;
            t1_complete = 1'b0;
            t2_started  = 1'b0;
            random_word(w_label, w_sdi, w_data, w_ssm);
            fiu_corrupt = 1'b0;
            fiu_idle    = 1'b0;

            case (variant)
                1 : vname = "RESET_DURING_PARITY_FAULT_TX";
                2 : vname = "RESET_DURING_INCOMPLETE_WORD";
                3 : vname = "RESET_DURING_REPEATED_ERROR_SEQ";
                default : vname = "RESET_DURING_IDLE";
            endcase
            $display("------------------------------------------------------------");
            $display("Reset scenario       : %0s", vname);

            if (variant == 3) begin
                /* FI-02: transaction 1 is a REAL, fully completed parity-
                 * fault transaction (its own verified case). The repeated
                 * error context is therefore proven, not assumed. */
                t1_txdone_base = tx_done_count;
                run_parity_fault_at(12, 1'b1);
                t1_complete = last_txdone_seen && last_rx_valid_seen &&
                              (tx_done_count == t1_txdone_base + 1);
                if (t1_complete)
                    $display("  [REPEAT-PROOF] transaction 1 COMPLETED (tx_done + rx_valid + parity_error=%b)",
                             last_parity_obs);
                else begin
                    checks_ok = 1'b0;
                    $display("  FAIL: transaction 1 did not complete - repeated-error context invalid");
                end
            end

            if (variant != 4) begin
                if (variant == 1 || variant == 2) begin
                    /* arm receiver and start a transmission that will be
                     * aborted mid-word by the reset */
                    @(negedge clk);
                    rx_start = 1'b1;
                    @(negedge clk);
                    rx_start = 1'b0;
                    tx_b = tx_done_count;
                    fiu_idle = (variant == 2);   /* variant 2: suppress word */
                    @(negedge clk);
                    label    = w_label;
                    sdi      = w_sdi;
                    data     = w_data;
                    ssm      = w_ssm;
                    tx_start = 1'b1;
                    @(posedge clk);              /* word latched, bit 0 out */
                    @(negedge clk);
                    tx_start = 1'b0;

                    if (variant == 1) begin
                        /* FI-01: corrupt serial bit 12 by asserting the FIU
                         * control exactly during the bit-12 window, then
                         * PROVE the wire flipped (mid-bit capture). */
                        for (k = 0; k < 12; k = k + 1)
                            repeat (CYCLES_PER_BIT) @(negedge clk);
                        fiu_corrupt = 1'b1;      /* bit 12 window begins   */
                        repeat (CYCLES_PER_BIT/2) @(negedge clk);
                        fault_on_wire = (arinc_tx !== arinc_line);
                        if (fault_on_wire)
                            $display("  [WIRE-PROOF] serial bit 12 corrupted on the wire: FIU_in=%b FIU_out=%b",
                                     arinc_tx, arinc_line);
                        else begin
                            checks_ok = 1'b0;
                            $display("  FAIL: requested corruption did not reach the wire");
                        end
                    end else begin
                        fault_on_wire = 1'b1;    /* whole word suppressed  */
                        repeat (10 * CYCLES_PER_BIT) @(negedge clk);
                    end
                    if (variant == 1)
                        repeat ((CYCLES_PER_BIT/2) + 4 * CYCLES_PER_BIT) @(negedge clk);
                end else begin
                    /* variant 3: transaction 2 of the repeated sequence.
                     * FI-02: start it ONLY after tx_busy==0 proves the DUT
                     * is ready, so the second tx_start is genuinely
                     * accepted (the DUT ignores tx_start while busy). */
                    n = 0;
                    while ((tx_busy !== 1'b0) && (n < 40000)) begin
                        @(negedge clk);
                        n = n + 1;
                    end
                    if (tx_busy !== 1'b0) begin
                        checks_ok = 1'b0;
                        $display("  FAIL: DUT never became ready for transaction 2");
                    end
                    @(negedge clk);
                    rx_start = 1'b1;
                    @(negedge clk);
                    rx_start = 1'b0;
                    @(negedge clk);
                    label    = w_label;
                    sdi      = w_sdi;
                    data     = w_data;
                    ssm      = w_ssm;
                    tx_start = 1'b1;
                    @(posedge clk);              /* T2 latched: REAL start */
                    @(negedge clk);
                    tx_start = 1'b0;
                    t2_started = 1'b1;
                    $display("  [REPEAT-PROOF] transaction 2 STARTED after tx_busy==0 (second tx_start genuinely accepted)");
                    /* corrupt serial bit 5 of T2 with the per-bit mechanism */
                    for (k = 0; k < 5; k = k + 1)
                        repeat (CYCLES_PER_BIT) @(negedge clk);
                    fiu_corrupt = 1'b1;
                    repeat (CYCLES_PER_BIT/2) @(negedge clk);
                    fault_on_wire = (arinc_tx !== arinc_line);
                    if (fault_on_wire)
                        $display("  [WIRE-PROOF] T2 serial bit 5 corrupted on the wire: FIU_in=%b FIU_out=%b",
                                 arinc_tx, arinc_line);
                    else begin
                        checks_ok = 1'b0;
                        $display("  FAIL: T2 requested corruption did not reach the wire");
                    end
                    repeat (5 * CYCLES_PER_BIT) @(negedge clk);
                end
            end else begin
                /* idle condition: confirm bus quiet first */
                repeat (100) @(posedge clk);
                @(negedge clk);
                fault_on_wire = 1'b1;            /* nothing to corrupt     */
            end

            tx_b = tx_done_count;
            rx_b = rx_valid_count;

            /* synchronous reset, sampled after it has taken effect */
            @(negedge clk);
            rst = 1'b1;
            fiu_corrupt = 1'b0;
            fiu_idle    = 1'b0;
            tx_start    = 1'b0;
            rx_start    = 1'b0;
            @(posedge clk);          /* reset applies at this edge */
            @(negedge clk);          /* settled outputs            */
            if ((tx_busy !== 1'b0) || (tx_done !== 1'b0) ||
                (rx_busy !== 1'b0) || (rx_valid !== 1'b0) ||
                (parity_error !== 1'b0) || (rx_word !== 32'd0) ||
                (arinc_tx !== 1'b0)) begin
                checks_ok = 1'b0;
                $display("  FAIL: stale DUT outputs after reset (tx_busy=%b rx_busy=%b rx_valid=%b par=%b word=%h)",
                         tx_busy, rx_busy, rx_valid, parity_error, rx_word);
            end
            rst = 1'b0;

            /* no stale completion events for two word times */
            repeat (2 * TOTAL_TX_CYCLES) @(posedge clk);
            @(negedge clk);
            no_stale = (tx_done_count == tx_b) && (rx_valid_count == rx_b);
            if (!no_stale) begin
                checks_ok = 1'b0;
                $display("  FAIL: stale tx_done/rx_valid event after mid-operation reset");
            end

            /* FI-18: post-reset RECOVERY transaction must fully pass */
            failed_before = failed_tests;
            run_normal_txn(1'b0);
            recovery_ok = (failed_tests == failed_before) && last_rx_valid_seen &&
                          last_wire_ok && last_timing_ok;
            if (!recovery_ok) begin
                checks_ok = 1'b0;
                $display("  FAIL: post-reset recovery transaction did not pass");
            end

            if (checks_ok && no_stale && recovery_ok &&
                (variant == 4 ? 1'b1 : fault_on_wire) &&
                (variant == 3 ? (t1_complete && t2_started) : 1'b1)) begin
                reset_passed = reset_passed + 1;
                passed_tests = passed_tests + 1;
                $display("Result              : PASS (DUT returned to reset state, no stale events, recovery transaction verified)");
                if (variant == 3)
                    $display("                      repeated-error context proven: T1 completed + T2 genuinely started, both aborted by reset");
            end else begin
                reset_failed = reset_failed + 1;
                failed_tests = failed_tests + 1;
                $display("Result              : FAIL [DUT FAILURE] reset recovery incomplete");
            end
            write_csv_row(ROW_RESET, -1, -1, event_id, -1,
                CLASS_RESET, -1, -1, -1, -1, -1,
                0, 0, -1, 0, 0, 0, 0, -1,
                DET_NA,
                (checks_ok && no_stale && recovery_ok) ? VER_PASS : VER_FAIL_DUT,
                0, CLASS_NORMAL);
            event_id = event_id + 1;
        end
    endtask

    /*------------------------------------------------------------------------
     * STAGE TASKS
     *----------------------------------------------------------------------*/
    task run_normal_txn;
        input integer quiet;
        reg [7:0] w_label; reg [1:0] w_sdi; reg [18:0] w_data; reg [1:0] w_ssm;
        begin
            random_word(w_label, w_sdi, w_data, w_ssm);
            run_transaction(w_label, w_sdi, w_data, w_ssm, 32'h0, 32'h0, 1'b1,
                            CLASS_NORMAL, "NORMAL", quiet);
        end
    endtask

    task regression_normal_suite;
        input integer n;
        integer i;
        begin
            $display("============================================================");
            $display("REGRESSION BLOCK: normal traffic, injection disabled (FIU=wire)");
            $display("============================================================");
            for (i = 0; i < n; i = i + 1)
                run_normal_txn(i == 0 ? 1'b0 : 1'b1);
        end
    endtask

    task directed_suite;
        integer sp;
        begin
            $display("============================================================");
            $display("DIRECTED SUITE 1: single-bit fault at EVERY serial position");
            $display("(proves serial<->word mapping for all 32 positions)");
            $display("============================================================");
            for (sp = 0; sp < 32; sp = sp + 1)
                run_parity_fault_at(sp, 1'b1);
            $display("DIRECTED SUITE 1 COMPLETE: 32/32 serial positions exercised");

            $display("============================================================");
            $display("DIRECTED SUITE 2: two-bit corruption (parity limitation)");
            $display("============================================================");
            run_two_bit_fault(0, 1);
            run_two_bit_fault(29, 31);

            $display("============================================================");
            $display("DIRECTED SUITE 3: communication timeout sub-types");
            $display("(0 truncated word, 1 silent-bus false reception,");
            $display(" 2 no communication, 3 armed RX with no TX)");
            $display("============================================================");
            run_timeout_fault(0);
            run_timeout_fault(1);
            run_timeout_fault(2);
            run_timeout_fault(3);

            $display("============================================================");
            $display("DIRECTED SUITE 4: verification-modeled FIFO events");
            $display("============================================================");
            run_fifo_overflow_case(1);
            run_fifo_underflow_case(2);

            $display("============================================================");
            $display("DIRECTED SUITE 5: application-defined invalid labels");
            $display("============================================================");
            run_invalid_label_case(8'h00, 1'b0);
            run_invalid_label_case(8'hFF, 1'b0);

            $display("============================================================");
            $display("DIRECTED SUITE 6: bus idle error + normal-gap control");
            $display("============================================================");
            run_bus_idle_case(idle_threshold_cycles);
            check_normal_gap_not_idle;

            $display("============================================================");
            $display("DIRECTED SUITE 7: high-error-rate windows incl. boundary");
            $display("(FI-16: 0%%, low, below-boundary, at-boundary, above)");
            $display("============================================================");
            run_high_rate_window(0,  10);   /* 0%   : reference window     */
            run_high_rate_window(5,  50);   /* 10%  : low rate              */
            run_high_rate_window(14, 50);   /* 28%  : BELOW 30% threshold   */
            run_high_rate_window(15, 50);   /* 30%  : AT threshold (>=)     */
            run_high_rate_window(25, 50);   /* 50%  : above threshold       */
        end
    endtask

    task stage1_individual;
        integer i;
        begin
            $display("============================================================");
            $display("STAGE 1: normal + individual faults (randomized parameters)");
            $display("============================================================");
            for (i = 0; i < 6; i = i + 1)
                run_parity_fault_rand(1'b0);
            run_timeout_fault(rand_range(0, 3));
            run_timeout_fault(rand_range(0, 3));
            run_fifo_overflow_case(rand_range(0, 2));
            run_fifo_underflow_case(rand_range(1, 3));
            for (i = 0; i < 4; i = i + 1)
                run_invalid_label_case(pick_invalid_label(0), 1'b0);
            run_bus_idle_case(idle_threshold_cycles);
            run_bus_idle_case(idle_threshold_cycles);
        end
    endtask

    task stage2_repeated;
        integer b;
        begin
            $display("============================================================");
            $display("STAGE 2: repeated communication errors");
            $display("============================================================");
            run_repeated_block(CLASS_PARITY, rand_range(repeat_error_min, repeat_error_max));
            run_repeated_block(CLASS_INVALID_LBL, rand_range(repeat_error_min, repeat_error_max));
            run_repeated_block(CLASS_PARITY, rand_range(repeat_error_min, repeat_error_max));
        end
    endtask

    task stage3_random;
        integer t, f, planned;
        begin
            $display("============================================================");
            $display("STAGE 3: mixed randomized fault scenarios (%0d iterations, prob=%0d%%)",
                     num_random_tests, fault_probability_pct);
            $display("============================================================");
            for (t = 0; t < num_random_tests; t = t + 1) begin
                if (rand_range(1, 100) <= fault_probability_pct) begin
                    f = pick_weighted_fault(0);
                    case (f)
                        1 : run_parity_fault_rand(1'b1);
                        2 : run_timeout_fault(rand_range(0, 3));
                        3 : run_fifo_overflow_case(rand_range(0, 2));
                        4 : run_fifo_underflow_case(rand_range(1, 3));
                        5 : run_invalid_label_case(pick_invalid_label(0), 1'b1);
                        6 : run_repeated_block(
                                ({$random(rng_seed)} % 2) ? CLASS_PARITY : CLASS_INVALID_LBL,
                                rand_range(repeat_error_min, repeat_error_max));
                        7 : run_bus_idle_case(idle_threshold_cycles);
                        8 : run_high_rate_window(rand_range(2, error_rate_window),
                                                 error_rate_window);
                        default : run_parity_fault_rand(1'b1);
                    endcase
                end else begin
                    run_normal_txn(1'b1);
                end
            end
        end
    endtask

    task stage4_reset;
        begin
            $display("============================================================");
            $display("STAGE 4: reset-during-fault scenarios (RESET RECOVERY class)");
            $display("============================================================");
            run_reset_case(1);
            run_reset_case(2);
            run_reset_case(3);
            run_reset_case(4);
        end
    endtask

    /*------------------------------------------------------------------------
     * SUMMARY + COUNTER CONSISTENCY (FI-05/11/12: honest buckets; the
     * equations now include the *_unresolved buckets so every injected
     * fault is accounted for exactly once)
     *----------------------------------------------------------------------*/
    task print_summary;
        begin
            $display("");
            $display("============================================================");
            $display("PHASE-1 FAULT INJECTION - COUNTER SUMMARY (seed=%0d mode=%0d)", user_seed, run_mode);
            $display("============================================================");
            $display("total_tests                  = %0d", total_tests);
            $display("passed_tests                 = %0d", passed_tests);
            $display("failed_tests                 = %0d", failed_tests);
            $display("normal_tests                 = %0d", normal_tests);
            $display("normal_passed                = %0d", normal_passed);
            $display("normal_failed                = %0d", normal_failed);
            $display("fault_tests                  = %0d", fault_tests);
            $display("faults_injected              = %0d", faults_injected);
            $display("faults_detected              = %0d", faults_detected);
            $display("faults_undetected            = %0d", faults_undetected);
            $display("expected_limitations         = %0d", expected_limitations);
            $display("faults_unresolved            = %0d", faults_unresolved);
            $display("errors_observed              = %0d", errors_observed);
            $display("------------------------------------------------------------");
            $display("parity_faults                = %0d", parity_faults);
            $display("parity_detected              = %0d", parity_detected);
            $display("parity_undetected            = %0d", parity_undetected);
            $display("parity_anomalies             = %0d", parity_anomalies);
            $display("two_bit_faults               = %0d", two_bit_faults);
            $display("two_bit_limitations          = %0d", two_bit_limitations);
            $display("timeout_faults               = %0d", timeout_faults);
            $display("timeout_observed             = %0d", timeout_observed);
            $display("timeout_unresolved           = %0d", timeout_unresolved);
            $display("timeout_detected_by_dut      = 0   (no timeout detector in RTL)");
            $display("fifo_overflow_events         = %0d (verification-modeled)", fifo_overflow_events);
            $display("fifo_underflow_events        = %0d (verification-modeled)", fifo_underflow_events);
            $display("invalid_label_faults         = %0d", invalid_label_faults);
            $display("repeated_error_cases         = %0d", repeated_error_cases);
            $display("repeated_error_patterns_observed = %0d (ANALYSIS classification)", repeated_error_patterns_observed);
            $display("repeated_underlying_dut_detected = %0d (blocks with >=1 DUT-detected member)", repeated_underlying_dut_detected);
            $display("repeated_error_failed        = %0d", repeated_error_failed);
            $display("bus_idle_cases               = %0d", bus_idle_cases);
            $display("high_error_rate_cases        = %0d", high_error_rate_cases);
            $display("high_error_rate_windows_classified = %0d (ANALYSIS classification)", high_error_rate_windows_classified);
            $display("high_error_rate_windows_below      = %0d", high_error_rate_windows_below);
            $display("high_error_rate_failed       = %0d", high_error_rate_failed);
            $display("------------------------------------------------------------");
            $display("bit_faults_by_label          = %0d", bit_faults_by_label);
            $display("bit_faults_by_sdi            = %0d", bit_faults_by_sdi);
            $display("bit_faults_by_data           = %0d", bit_faults_by_data);
            $display("bit_faults_by_ssm            = %0d", bit_faults_by_ssm);
            $display("bit_faults_by_parity         = %0d", bit_faults_by_parity);
            $display("------------------------------------------------------------");
            $display("reset_tests                  = %0d", reset_tests);
            $display("reset_passed                 = %0d", reset_passed);
            $display("reset_failed                 = %0d", reset_failed);
            $display("------------------------------------------------------------");
            $display("timing_failures              = %0d", timing_failures);
            $display("tx_done width failures       = %0d", tx_done_width_failures);
            $display("rx_valid width failures      = %0d", rx_valid_width_failures);
            $display("tb_internal_errors           = %0d", tb_internal_errors);
            $display("consistency_violations       = %0d", consistency_violations);
            $display("dataset_integrity_failures   = %0d (per-row CSV audit)", dataset_integrity_failures);
            $display("FIFO model: write_req=%0d read_req=%0d final_occ=%0d",
                     fifo_wr_req_total, fifo_rd_req_total, fifo_occ);
            $display("============================================================");
        end
    endtask

    task check_consistency;
        integer v;
        begin
            v = 0;
            if (total_tests !== passed_tests + failed_tests) begin
                v = v + 1;
                $display("CONSISTENCY E1  FAIL: total_tests != passed+failed");
            end
            if (faults_injected !== faults_detected + faults_undetected +
                expected_limitations + faults_unresolved) begin
                v = v + 1;
                $display("CONSISTENCY E2  FAIL: faults_injected != detected+undetected+limitations+unresolved");
            end
            if (parity_faults !== parity_detected + parity_undetected +
                parity_anomalies) begin
                v = v + 1;
                $display("CONSISTENCY E3  FAIL: parity ledger (incl. anomalies)");
            end
            if (two_bit_faults !== two_bit_limitations) begin
                v = v + 1;
                $display("CONSISTENCY E4  FAIL: two-bit ledger");
            end
            if (timeout_faults !== timeout_observed + timeout_unresolved) begin
                v = v + 1;
                $display("CONSISTENCY E5  FAIL: timeout ledger");
            end
            if (fifo_overflow_events !== fifo_overflow_expected_limit +
                fifo_overflow_unresolved) begin
                v = v + 1;
                $display("CONSISTENCY E6  FAIL: fifo overflow ledger");
            end
            if (fifo_underflow_events !== fifo_underflow_expected_limit +
                fifo_underflow_unresolved) begin
                v = v + 1;
                $display("CONSISTENCY E7  FAIL: fifo underflow ledger");
            end
            if (invalid_label_faults !== invalid_label_expected_limit +
                invalid_label_unresolved) begin
                v = v + 1;
                $display("CONSISTENCY E8  FAIL: invalid label ledger");
            end
            if (bus_idle_cases !== bus_idle_expected_limit +
                bus_idle_unresolved) begin
                v = v + 1;
                $display("CONSISTENCY E9  FAIL: bus idle ledger");
            end
            if (repeated_error_cases !== repeated_error_patterns_observed +
                repeated_error_failed) begin
                v = v + 1;
                $display("CONSISTENCY E10 FAIL: repeated-error ledger");
            end
            if (high_error_rate_cases !== high_error_rate_windows_classified +
                high_error_rate_windows_below + high_error_rate_failed) begin
                v = v + 1;
                $display("CONSISTENCY E11 FAIL: high-rate ledger");
            end
            if (normal_tests !== normal_passed + normal_failed) begin
                v = v + 1;
                $display("CONSISTENCY E12 FAIL: normal ledger");
            end
            if (reset_tests !== reset_passed + reset_failed) begin
                v = v + 1;
                $display("CONSISTENCY E13 FAIL: reset ledger");
            end
            if ((bit_faults_by_label + bit_faults_by_sdi + bit_faults_by_data +
                 bit_faults_by_ssm + bit_faults_by_parity) !== parity_faults) begin
                v = v + 1;
                $display("CONSISTENCY E14 FAIL: bit-position ledger != parity_faults");
            end
            consistency_violations = v;
            if (v == 0)
                $display("COUNTER CONSISTENCY: ALL 14 EQUATIONS HOLD");
            else
                $display("COUNTER CONSISTENCY: %0d VIOLATIONS", v);
        end
    endtask

    /*------------------------------------------------------------------------
     * MAIN SEQUENCE
     *----------------------------------------------------------------------*/
    integer cfg_i;
    integer clamp_warn;

    initial begin
        /*---------------- configuration defaults -------------------------*/
        user_seed                   = 1;
        run_mode                    = 1;
        num_random_tests            = 60;
        fault_probability_pct       = 80;
        error_rate_window           = 10;
        high_error_rate_threshold_pct = 30;   /* PROJECT-DEFINED, not ARINC */
        timeout_threshold_cycles    = 22000;  /* PROJECT-DEFINED, not ARINC */
        idle_threshold_cycles       = 22000;  /* PROJECT-DEFINED, not ARINC */
        fifo_depth                  = 4;      /* verification model         */
        repeat_error_min            = 3;
        repeat_error_max            = 6;
        for (cfg_i = 1; cfg_i <= 8; cfg_i = cfg_i + 1)
            fault_weights[cfg_i] = 10;

        /*---------------- plusarg overrides ------------------------------*/
        if ($value$plusargs("SEED=%d", user_seed)) ;
        if ($value$plusargs("MODE=%d", run_mode)) ;
        if ($value$plusargs("TESTS=%d", num_random_tests)) ;
        if ($value$plusargs("PROB=%d", fault_probability_pct)) ;
        if ($value$plusargs("WINDOW=%d", error_rate_window)) ;
        if ($value$plusargs("THRESH=%d", high_error_rate_threshold_pct)) ;
        if ($value$plusargs("TIMEOUT=%d", timeout_threshold_cycles)) ;
        if ($value$plusargs("IDLE=%d", idle_threshold_cycles)) ;
        if ($value$plusargs("FDEPTH=%d", fifo_depth)) ;
        if ($value$plusargs("REPMIN=%d", repeat_error_min)) ;
        if ($value$plusargs("REPMAX=%d", repeat_error_max)) ;
        rng_seed = user_seed;    /* $random advances rng_seed; user_seed
                                    stays immutable for logging/CSV       */

        /*---------------- sanity clamps (FI-17) --------------------------*/
        clamp_warn = 0;
        if (num_random_tests < 0) begin
            num_random_tests = 0;  clamp_warn = clamp_warn + 1; end
        if (fault_probability_pct < 0) begin
            fault_probability_pct = 0;  clamp_warn = clamp_warn + 1; end
        if (fault_probability_pct > 100) begin
            fault_probability_pct = 100;  clamp_warn = clamp_warn + 1; end
        if (error_rate_window < 2) begin
            error_rate_window = 2;  clamp_warn = clamp_warn + 1; end
        if (error_rate_window > 64) begin
            error_rate_window = 64;  clamp_warn = clamp_warn + 1; end
        if (high_error_rate_threshold_pct < 1) begin
            high_error_rate_threshold_pct = 1;  clamp_warn = clamp_warn + 1; end
        if (high_error_rate_threshold_pct > 100) begin
            high_error_rate_threshold_pct = 100;  clamp_warn = clamp_warn + 1; end
        if (timeout_threshold_cycles < TOTAL_TX_CYCLES) begin
            timeout_threshold_cycles = TOTAL_TX_CYCLES;
            clamp_warn = clamp_warn + 1; end
        if (idle_threshold_cycles <= GAP_CYCLES) begin
            /* IDLE_THRESHOLD must exceed the normal interword gap so a
             * valid 4-bit gap can never be classified as a bus idle error */
            idle_threshold_cycles = GAP_CYCLES + 2000;
            clamp_warn = clamp_warn + 1; end
        if (fifo_depth < 1) begin
            fifo_depth = 1;  clamp_warn = clamp_warn + 1; end
        if (fifo_depth > 64) begin
            fifo_depth = 64;  clamp_warn = clamp_warn + 1; end
        if (repeat_error_min < 2) begin
            repeat_error_min = 2;  clamp_warn = clamp_warn + 1; end
        if (repeat_error_max < repeat_error_min) begin
            repeat_error_max = repeat_error_min;  clamp_warn = clamp_warn + 1; end
        if (clamp_warn > 0)
            $display("NOTE: %0d configuration value(s) were clamped into the legal range (see header).", clamp_warn);

        /*---------------- counter initialization -------------------------*/
        txn_id = 0; sample_id = 0; event_id = 0; window_id = 0;
        total_tests = 0; passed_tests = 0; failed_tests = 0;
        normal_tests = 0; normal_passed = 0; normal_failed = 0;
        fault_tests = 0;
        faults_injected = 0; faults_detected = 0; faults_undetected = 0;
        expected_limitations = 0; faults_unresolved = 0; errors_observed = 0;
        parity_faults = 0; parity_detected = 0; parity_undetected = 0;
        parity_anomalies = 0;
        two_bit_faults = 0; two_bit_limitations = 0;
        timeout_faults = 0; timeout_observed = 0; timeout_unresolved = 0;
        fifo_overflow_events = 0; fifo_overflow_expected_limit = 0;
        fifo_overflow_unresolved = 0;
        fifo_underflow_events = 0; fifo_underflow_expected_limit = 0;
        fifo_underflow_unresolved = 0;
        invalid_label_faults = 0; invalid_label_expected_limit = 0;
        invalid_label_unresolved = 0;
        repeated_error_cases = 0; repeated_error_patterns_observed = 0;
        repeated_error_failed = 0; repeated_underlying_dut_detected = 0;
        bus_idle_cases = 0; bus_idle_expected_limit = 0;
        bus_idle_unresolved = 0;
        high_error_rate_cases = 0; high_error_rate_windows_classified = 0;
        high_error_rate_windows_below = 0; high_error_rate_failed = 0;
        bit_faults_by_label = 0; bit_faults_by_sdi = 0; bit_faults_by_data = 0;
        bit_faults_by_ssm = 0; bit_faults_by_parity = 0;
        reset_tests = 0; reset_passed = 0; reset_failed = 0;
        timing_failures = 0; consistency_violations = 0; tb_internal_errors = 0;
        dataset_integrity_failures = 0; last_sample_id = 0;
        tx_done_count = 0; rx_valid_count = 0;
        tx_done_rise_time = 0; rx_valid_rise_time = 0;
        tx_busy_rise_time = 0; rx_arm_time = 0;
        tx_done_width_failures = 0; rx_valid_width_failures = 0;
        tx_done_prev = 1'b0; rx_valid_prev = 1'b0;
        parity_error_count = 0; timeout_count = 0; fifo_overflow_count = 0;
        fifo_underflow_count = 0; invalid_label_count = 0; repeated_error_count = 0;
        bus_idle_count = 0;
        consecutive_error_count = 0; last_fault_txn_id = 0; last_error_type = 0;
        last_error_rate = 0.0; last_idle_duration = 0;
        last_orig_label = -1; last_inj_label = -1; last_label_supported = -1;
        fault_pos_scratch = -1; fault_word_bit_scratch = -1;
        fifo_occ = 0; fifo_wr_req_total = 0; fifo_rd_req_total = 0;
        orig_capture = 32'h0; wire_capture = 32'h0;

        /*---------------- signals ----------------------------------------*/
        rst             = 1'b1;
        tx_start        = 1'b0;
        rx_start        = 1'b0;
        label           = 8'h00;
        sdi             = 2'b00;
        data            = 19'h00000;
        ssm             = 2'b00;
        loopback_enable = 1'b0;      /* RX always listens to the FIU output */
        fiu_corrupt     = 1'b0;
        fiu_idle        = 1'b0;

        /*---------------- CSV dataset ------------------------------------*/
        $sformat(csv_name, "arinc429_ml_dataset_seed%0d.csv", user_seed);
        csv_fd = $fopen(csv_name, "w");
        if (csv_fd == 0) begin
            $display("ERROR: cannot open CSV dataset file %0s - aborting (no silent data loss).", csv_name);
            $finish;
        end
        $fdisplay(csv_fd, "sample_id,seed,row_type,transaction_id,window_id,event_id,ref_transaction_id,fault_class,underlying_fault_type,fault_position,word_bit_position,original_label,injected_label,label_supported,total_transactions,valid_transactions,errors_observed,faults_injected,fault_tests,parity_error_count,timeout_count,fifo_overflow_count,fifo_underflow_count,invalid_label_count,repeated_error_count,bus_idle_count,idle_duration,idle_threshold,consecutive_error_count,error_rate_pct,high_error_rate_threshold_pct,high_error_rate_condition,repeat_count,successful_transactions_between_errors,last_error_type,rx_word_mismatch,parity_error,rx_valid,tx_done,window_size,window_faulty,dominant_error_type,detection_status,verification_status,expected_limitation_flag,health_label");

        /*---------------- banner -----------------------------------------*/
        $display("============================================================");
        $display("ARINC 429 PHASE-1 FAULT INJECTION TESTBENCH (Review-2 rev B)");
        $display("============================================================");
        $display("USER_SEED                    = %0d  (same seed reproduces the identical fault sequence)", user_seed);
        $display("RUN MODE                     = %0d  (0=NORMAL, 1=RANDOM, 2=DIRECTED)", run_mode);
        $display("NUM_RANDOM_TESTS             = %0d", num_random_tests);
        $display("FAULT_PROBABILITY            = %0d %%", fault_probability_pct);
        $display("ERROR_RATE_WINDOW            = %0d transactions", error_rate_window);
        $display("HIGH_ERROR_RATE_THRESHOLD    = %0d %%   [PROJECT-DEFINED]", high_error_rate_threshold_pct);
        $display("TIMEOUT_THRESHOLD            = %0d cycles (%0d us) [PROJECT-DEFINED]", timeout_threshold_cycles, timeout_threshold_cycles * CLK_PERIOD_NS / 1000);
        $display("IDLE_THRESHOLD               = %0d cycles (%0d us) [PROJECT-DEFINED, > normal gap %0d]", idle_threshold_cycles, idle_threshold_cycles * CLK_PERIOD_NS / 1000, GAP_CYCLES);
        $display("FIFO_DEPTH (verification model) = %0d  [NO FIFO IN RTL]", fifo_depth);
        $display("REPEAT_ERROR_RANGE           = %0d..%0d", repeat_error_min, repeat_error_max);
        $display("CYCLES_PER_BIT=%0d GAP_CYCLES=%0d TOTAL_TX_CYCLES=%0d RX_VALID_DELAY=%0d",
                 CYCLES_PER_BIT, GAP_CYCLES, TOTAL_TX_CYCLES, RX_VALID_DELAY_CYCLES);
        $display("CSV dataset file             = %0s (46-column schema)", csv_name);
        $display("DUT files: UNMODIFIED Review-1 RTL; injector: TESTBENCH ONLY");
        $display("Detection honesty: REPEATED/HIGH-RATE are ANALYSIS classifications;");
        $display("  TIMEOUT/IDLE/FIFO/LABEL are EXPECTED LIMITATIONS (no such RTL hardware).");
        $display("============================================================");

        /*---------------- reset ------------------------------------------*/
        repeat (5) @(negedge clk);
        rst = 1'b0;
        repeat (2) @(negedge clk);

        /* reset sanity: outputs must be clean before any traffic */
        total_tests = total_tests + 1;
        if ((tx_busy !== 1'b0) || (tx_done !== 1'b0) || (rx_busy !== 1'b0) ||
            (rx_valid !== 1'b0) || (parity_error !== 1'b0) || (rx_word !== 32'd0)) begin
            failed_tests = failed_tests + 1;
            $display("Result              : FAIL [DUT FAILURE] outputs not clean after initial reset");
        end else begin
            passed_tests = passed_tests + 1;
            $display("Result              : PASS [INITIAL_RESET] outputs clean");
        end

        /*---------------- mode dispatch ----------------------------------*/
        case (run_mode)
            0 : begin
                regression_normal_suite(4);
            end
            2 : begin
                regression_normal_suite(2);
                directed_suite;
            end
            default : begin
                regression_normal_suite(2);
                directed_suite;
                stage1_individual;
                stage2_repeated;
                stage3_random;
                stage4_reset;
            end
        endcase

        /*---------------- closeout ---------------------------------------*/
        print_summary;
        check_consistency;

        if ((failed_tests == 0) && (tb_internal_errors == 0) &&
            (consistency_violations == 0) && (timing_failures == 0) &&
            (tx_done_width_failures == 0) && (rx_valid_width_failures == 0) &&
            (passed_tests == total_tests) && (faults_unresolved == 0) &&
            (parity_anomalies == 0) && (dataset_integrity_failures == 0)) begin
            $display("OVERALL RESULT = PASS");
            $display("============================================================");
            $display("FAULT-INJECTION FRAMEWORK READY");
            $display("(verified by this simulation run; re-run under Vivado XSim");
            $display(" with the same seed to reproduce this exact fault sequence)");
            $display("============================================================");
        end else begin
            $display("OVERALL RESULT = FAIL");
            $display("============================================================");
            $display("FAULT-INJECTION FRAMEWORK NOT READY - see failures above");
            $display("============================================================");
        end

        $fclose(csv_fd);
        $finish;
    end

    /*------------------------------------------------------------------------
     * WATCHDOG (never passes silently)
     *----------------------------------------------------------------------*/
    initial begin
        #500000000;    /* 500 ms simulated time - far beyond all stages */
        $display("ERROR: fault-injection testbench watchdog timeout.");
        $display("OVERALL RESULT = FAIL (WATCHDOG ABORT)");
        $finish;
    end

endmodule
