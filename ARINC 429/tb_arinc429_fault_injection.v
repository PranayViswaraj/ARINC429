`timescale 1ns/1ps
/*==============================================================================
 * FILE   : tb_arinc429_fault_injection.v
 * STATUS : TESTBENCH ONLY (Phase-1 / Review-2 verification layer)
 *
 * PURPOSE
 * =======
 * Randomized, reproducible, self-checking fault injection and communication
 * error analysis for the Review-1 ARINC 429 controller. The three DUT files
 * (arinc429_tx.v, arinc429_rx.v, arinc429_controller.v) are used UNMODIFIED.
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
 *   6 REPEATED_COMMUNICATION_ERROR(repeated block of one error type)
 *   7 BUS_IDLE_ERROR              (suppressed activity, idle time measured)
 *   8 HIGH_ERROR_RATE             (statistical window classification)
 *   NOTE: the Review-1 RTL contains NO FIFO, NO timeout detector, NO label
 *   validator and NO idle detector. Classes 2..7 are therefore observed and
 *   recorded at verification level and counted as EXPECTED LIMITATIONS of the
 *   conventional (Review-1) design. Nothing is falsely attributed to the DUT.
 *
 * HONEST DETECTION MODEL (per class):
 *   PARITY_ERROR    : DETECTED BY DUT iff rx_valid==1 AND rx_word!=expected
 *                     AND parity_error==1 (single-bit flip).
 *   TWO-BIT         : EXPECTED LIMITATION of odd parity (word differs,
 *                     parity_error==0). Reported as such, never as detection.
 *   TIMEOUT/IDLE/
 *   FIFO/LABEL      : DUT cannot detect (no such hardware). Expected
 *                     limitations; observations still fully predicted and
 *                     verified bit-accurately against the RTL behavior.
 *   REPEATED        : block-level: detected iff DUT raised parity_error on at
 *                     least one member transaction.
 *   HIGH_ERROR_RATE : window-level statistical classification vs threshold.
 *
 * SELF-CHECKING
 * =============
 * Every injected fault is proven end-to-end:
 *   fault request -> actual wire corruption (captured on the wire, bit by
 *   bit) -> DUT observation -> bit-accurate predicted response -> observed
 *   response -> classification -> counters -> final report.
 * The full expected received word AND expected parity_error flag are computed
 * BEFORE the transaction (including truncation-to-zero effects for suppressed
 * bits) and the DUT must match them exactly.
 *
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
 * randomized scenarios, three stages: individual -> repeated -> mixed).
 *
 * RANDOMIZATION
 * =============
 * Verilog-2001 only: $random with one explicit integer seed variable.
 *   +SEED=<n>   seed (default USER_SEED=1); printed at start of simulation
 *   +MODE=<n>   run mode (default 1)
 *   +TESTS=<n>  number of stage-3 randomized transactions (default 60)
 *   +PROB=<n>   stage-3 fault probability percent (default 80)
 * All randomness flows through rand_range()/pick functions using the single
 * seed, so the same seed always reproduces the identical fault sequence.
 * {$random(seed)} is used (unsigned concatenation) so negative $random values
 * can never create invalid indices or negative ranges.
 *
 * RESET-DURING-FAULT SCENARIOS are run after the fault stages and are
 * classified as RESET RECOVERY tests, NOT as communication faults.
 *
 * OUTPUTS
 * =======
 *   - structured per-transaction log on stdout
 *   - final counter summary + counter-consistency equations
 *   - CSV ML dataset: arinc429_ml_dataset_seed<SEED>.csv
 *     (labels are derived from injected conditions AND verified observations;
 *      a row whose verification failed is tagged health_label=98 and fails
 *      the simulation)
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
    integer rng_seed;                     /* live $random stream state (starts
                                             at user_seed, then advances)     */
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
    localparam integer CLASS_RESET        = 99;  /* reset-abort rows: not a
                                                     communication fault      */
    localparam integer CLASS_TWO_BIT      = 20;  /* supplementary analysis row:
                                                     two-bit parity limitation */
    localparam integer HEALTH_UNRELIABLE  = 98;  /* verification failed      */

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
    integer fault_tests;                       /* transactions w/ injected fault */
    integer faults_injected, faults_detected, faults_undetected;
    integer expected_limitations;

    /* per-class ledgers */
    integer parity_faults,   parity_detected,   parity_undetected;
    integer two_bit_faults,  two_bit_limitations;
    integer timeout_faults,  timeout_observed,  timeout_expected_limit;
    integer fifo_overflow_events,  fifo_overflow_expected_limit;
    integer fifo_underflow_events, fifo_underflow_expected_limit;
    integer invalid_label_faults,  invalid_label_expected_limit;
    integer repeated_error_cases,  repeated_error_detected, repeated_error_undetected;
    integer bus_idle_cases,        bus_idle_expected_limit;
    integer high_error_rate_cases, high_error_rate_detected, high_error_rate_below;

    /* bit-level fault positions (single-bit corruption ledger) */
    integer bit_faults_by_label, bit_faults_by_sdi, bit_faults_by_data;
    integer bit_faults_by_ssm,   bit_faults_by_parity;

    /* reset scenarios (NOT communication faults) */
    integer reset_tests, reset_passed, reset_failed;

    /* framework integrity */
    integer timing_failures, bit_errors, consistency_violations;
    integer tb_internal_errors;

    /* ML / dataset bookkeeping */
    integer sample_id;
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

    /* verification-modeled FIFO (no FIFO exists in the Review-1 RTL) */
    reg [31:0] fifo_mem [0:63];
    integer    fifo_occ, fifo_wr_req_total, fifo_rd_req_total;

    /* engine scratch */
    integer txn_id;
    reg     verbose_txn;
    integer fault_pos_scratch;     /* serial position of last bit fault    */

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
     *----------------------------------------------------------------------*/
    function integer rand_range;
        input integer lo;
        input integer hi;
        integer span;
        begin
            span = hi - lo + 1;
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
     * CSV dataset row (ML-oriented, derived from injection + observation)
     *----------------------------------------------------------------------*/
    task write_csv_row;
        input integer hlabel;              /* verified health label        */
        input integer fault_pos;           /* serial fault position or -1  */
        input integer rx_mismatch;         /* rx_word != expected flag     */
        input integer obs_parity_err;      /* observed DUT parity_error    */
        input integer obs_rx_valid;        /* observed rx_valid pulse      */
        input integer obs_tx_done;         /* observed tx_done pulse       */
        input integer err_rate_pct;        /* last window rate or 0        */
        begin
            sample_id = sample_id + 1;
            $fdisplay(csv_fd,
                "%0d,%0d,%0d,%0d,%0s,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",
                sample_id, user_seed, txn_id, hlabel, class_name(hlabel),
                fault_pos,
                txn_id,                       /* total_transactions so far  */
                rx_valid_count,               /* valid_transactions         */
                fault_tests,                  /* error_count                */
                parity_error_count, timeout_count, fifo_overflow_count,
                fifo_underflow_count, invalid_label_count,
                repeated_error_count, bus_idle_count,
                last_idle_duration, err_rate_pct,
                consecutive_error_count, last_error_type,
                rx_mismatch, obs_parity_err, obs_rx_valid, obs_tx_done,
                hlabel);
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
                write_csv_row(CLASS_NORMAL, -1, (rx_word !== recv_exp_word),
                              parity_error, (rx_valid_count == rx_before + 1),
                              (tx_done_count == tx_before + 1), 0);
            end

            CLASS_PARITY: begin
                fault_tests = fault_tests + 1;
                faults_injected = faults_injected + 1;
                parity_faults = parity_faults + 1;
                consecutive_error_count = consecutive_error_count + 1;
                last_fault_txn_id = txn_id;
                last_error_type   = CLASS_PARITY;
                /* single-bit corruption: detection definition (strict) */
                if ((rx_valid_count == rx_before + 1) && (rx_word !== build_word(w_label, w_sdi, w_data, w_ssm)) &&
                    (parity_error === 1'b1)) begin
                    detected = 1'b1;
                    parity_error_count = parity_error_count + 1;
                end
                if ((rx_valid_count == rx_before + 1) && (rx_word === recv_exp_word) &&
                    (parity_error === recv_exp_par) && wire_ok && detected) begin
                    parity_detected = parity_detected + 1;
                    faults_detected = faults_detected + 1;
                    passed_tests = passed_tests + 1;
                    $display("Result              : PASS (FAULT DETECTED BY DUT: parity_error=1, word mismatch, serial pos %0d)", fault_pos_scratch);
                end else if (detected) begin
                    /* detected but word/parity detail mismatched prediction */
                    failed_tests = failed_tests + 1;
                    faults_undetected = faults_undetected + 1;
                    parity_undetected = parity_undetected + 1;
                    $display("Result              : FAIL [DUT FAILURE] detected but response != bit-accurate prediction");
                end else begin
                    failed_tests = failed_tests + 1;
                    faults_undetected = faults_undetected + 1;
                    parity_undetected = parity_undetected + 1;
                    $display("Result              : FAIL [DUT FAILURE] single-bit parity fault NOT detected");
                end
                write_csv_row(CLASS_PARITY, fault_pos_scratch,
                              (rx_word !== recv_exp_word), parity_error,
                              (rx_valid_count == rx_before + 1),
                              (tx_done_count == tx_before + 1), 0);
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
            fault_pos_scratch = sp;
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
            fault_pos_scratch = sp;
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

    /* two-bit corruption: EXPECTED LIMITATION of odd parity */
    task run_two_bit_fault;
        input integer pa;
        input integer pb;
        reg [31:0] mask;
        reg [7:0] w_label; reg [1:0] w_sdi; reg [18:0] w_data; reg [1:0] w_ssm;
        begin
            random_word(w_label, w_sdi, w_data, w_ssm);
            mask = (32'h00000001 << pa) | (32'h00000001 << pb);
            fault_pos_scratch = pa;
            run_transaction(w_label, w_sdi, w_data, w_ssm, mask, 32'h0, 1'b1,
                            CLASS_TWO_BIT, "TWO_BIT_FAULT", 1'b0);
            two_bit_faults = two_bit_faults + 1;
            faults_injected = faults_injected + 1;
            fault_tests = fault_tests + 1;
            if (last_rx_valid_seen && (last_rx_word_obs === last_recv_exp_word) &&
                (last_parity_obs === last_recv_exp_par) && (last_recv_exp_par === 1'b0) &&
                last_wire_ok && last_timing_ok) begin
                two_bit_limitations  = two_bit_limitations + 1;
                expected_limitations = expected_limitations + 1;
                passed_tests = passed_tests + 1;
                $display("Result              : EXPECTED LIMITATION OBSERVED");
                $display("                      two-bit corruption escaped odd parity");
                $display("                      (rx_word differs, parity_error=0) - correct parity mathematics");
            end else begin
                failed_tests = failed_tests + 1;
                $display("Result              : FAIL [DUT FAILURE] two-bit response violates parity mathematics");
            end
            write_csv_row(CLASS_TWO_BIT, pa, (last_rx_word_obs !== last_recv_exp_word),
                          last_parity_obs, last_rx_valid_seen, last_txdone_seen, 0);
            consecutive_error_count = consecutive_error_count + 1;
            last_fault_txn_id = txn_id;
            last_error_type   = CLASS_PARITY;
        end
    endtask

    /* communication timeout: 0=truncated word, 1=whole word suppressed,
     * 2=receiver never armed. The RTL has NO timeout detector, so every
     * case is an EXPECTED LIMITATION; the DUT response is still predicted
     * bit-accurately and verified. */
    task run_timeout_fault;
        input integer subtype;
        reg [31:0] sup_mask;
        reg [7:0] w_label; reg [1:0] w_sdi; reg [18:0] w_data; reg [1:0] w_ssm;
        integer k, n, elapsed;
        reg [255:0] sub_name;
        begin
            timeout_faults = timeout_faults + 1;
            faults_injected = faults_injected + 1;
            fault_tests = fault_tests + 1;
            random_word(w_label, w_sdi, w_data, w_ssm);
            sup_mask = 32'h00000000;
            sub_name = "TIMEOUT";
            fault_pos_scratch = -1;

            if (subtype == 0) begin
                k = rand_range(4, 28);
                sup_mask = 32'hFFFFFFFF << k;
                sub_name = "TIMEOUT_TRUNCATED_WORD";
            end else if (subtype == 1) begin
                sup_mask = 32'hFFFFFFFF;
                sub_name = "TIMEOUT_WHOLE_WORD_SUPPRESSED";
            end else begin
                sub_name = "TIMEOUT_RX_NEVER_ARMED";
            end

            run_transaction(w_label, w_sdi, w_data, w_ssm, 32'h0, sup_mask,
                            (subtype != 2), CLASS_TIMEOUT, sub_name, 1'b0);

            /* measure / verify against the project-defined threshold */
            if (subtype == 2) begin
                /* no reception event expected: wait out the threshold */
                for (n = 0; n < timeout_threshold_cycles; n = n + 1)
                    @(posedge clk);
                @(negedge clk);
                last_rx_valid_seen = 1'b0;
                elapsed = timeout_threshold_cycles;
                if (rx_valid_count != 0) begin end /* confirm reception occurred */
                if (last_txdone_seen !== 1'b1) begin end     /* no-op */
            end else begin
                elapsed = (rx_valid_rise_time - rx_arm_time) / CLK_PERIOD_NS;
            end

            last_idle_event = 1'b1;
            timeout_observed = timeout_observed + 1;
            timeout_expected_limit = timeout_expected_limit + 1;
            expected_limitations = expected_limitations + 1;
            timeout_count = timeout_count + 1;
            consecutive_error_count = consecutive_error_count + 1;
            last_fault_txn_id = txn_id;
            last_error_type   = CLASS_TIMEOUT;

            /* prediction check */
            if (subtype == 2) begin
                /* nothing must have been received since engine snapshot */
                if (!last_txdone_seen || last_rx_valid_seen) begin
                    failed_tests = failed_tests + 1;
                    $display("Result              : FAIL [TESTBENCH FAILURE] unexpected RX activity without rx_start");
                end else if (!last_wire_ok || !last_timing_ok) begin
                    failed_tests = failed_tests + 1;
                    $display("Result              : FAIL [FRAMEWORK FAILURE] wire/timing proof failed");
                end else begin
                    passed_tests = passed_tests + 1;
                    $display("Result              : PASS (fault observed at verification level)");
                    $display("                      no rx_valid within %0d cycles of expected word start", timeout_threshold_cycles);
                    $display("                      DUT TIMEOUT DETECTOR: ABSENT - EXPECTED LIMITATION (no such RTL hardware)");
                end
            end else begin
                if (last_rx_valid_seen && (last_rx_word_obs === last_recv_exp_word) &&
                    (last_parity_obs === last_recv_exp_par) && last_wire_ok && last_timing_ok) begin
                    passed_tests = passed_tests + 1;
                    $display("Result              : PASS (fault observed at verification level)");
                    $display("                      RX completed an INCOMPLETE word after %0d cycles (rx_valid=1)", elapsed);
                    if (last_parity_obs === 1'b1)
                        $display("                      parity_error=1 observed on truncated stream (DUT error response)");
                    $display("                      DUT TIMEOUT DETECTOR: ABSENT - EXPECTED LIMITATION (no such RTL hardware)");
                end else begin
                    failed_tests = failed_tests + 1;
                    $display("Result              : FAIL [DUT FAILURE] truncated-word response != bit-accurate prediction");
                end
            end
            last_idle_duration = elapsed;
            write_csv_row(CLASS_TIMEOUT, -1, (last_rx_word_obs !== last_recv_exp_word),
                          last_parity_obs, last_rx_valid_seen, last_txdone_seen, 0);
        end
    endtask

    /* verification-modeled FIFO overflow around a verified normal transfer */
    task run_fifo_overflow_case;
        input integer burst_extra;
        reg [7:0] w_label; reg [1:0] w_sdi; reg [18:0] w_data; reg [1:0] w_ssm;
        integer j, planned_events, occ_before;
        begin
            fault_tests = fault_tests + 1;
            random_word(w_label, w_sdi, w_data, w_ssm);
            while (fifo_occ > 0) fifo_model_read;  /* drain without underflow */
            planned_events = 1 + burst_extra;
            run_transaction(w_label, w_sdi, w_data, w_ssm, 32'h0, 32'h0, 1'b1,
                            CLASS_FIFO_OVF, "FIFO_OVERFLOW(verification-modeled)", 1'b0);
            occ_before = fifo_occ;
            for (j = 0; j < fifo_depth + planned_events; j = j + 1)
                fifo_model_write(rx_word);
            fifo_overflow_expected_limit = fifo_overflow_expected_limit + planned_events;
            expected_limitations = expected_limitations + planned_events;
            faults_injected = faults_injected + planned_events;
            fifo_overflow_count = fifo_overflow_count + planned_events;
            consecutive_error_count = consecutive_error_count + 1;
            last_fault_txn_id = txn_id;
            last_error_type   = CLASS_FIFO_OVF;
            if (last_rx_valid_seen && (last_rx_word_obs === last_recv_exp_word) &&
                last_wire_ok && last_timing_ok &&
                (fifo_overflow_events >= planned_events)) begin
                passed_tests = passed_tests + 1;
                $display("Result              : PASS (verification-modeled FIFO overflow)");
                $display("                      occupancy_before=%0d writes_attempted=%0d overflow_events_planned=%0d",
                         occ_before, fifo_depth + planned_events, planned_events);
                $display("                      NO FIFO HARDWARE IN RTL - VERIFICATION-MODELED EVENT (expected limitation)");
            end else begin
                failed_tests = failed_tests + 1;
                $display("Result              : FAIL [FRAMEWORK FAILURE] FIFO overflow case inconsistent");
            end
            /* drain the model so later cases start clean (never read empty:
             * spurious reads would contaminate the underflow ledger) */
            while (fifo_occ > 0)
                fifo_model_read;
            write_csv_row(CLASS_FIFO_OVF, -1, 0, 0, last_rx_valid_seen,
                          last_txdone_seen, 0);
        end
    endtask

    /* verification-modeled FIFO underflow around a verified normal transfer */
    task run_fifo_underflow_case;
        input integer burst_reads;
        reg [7:0] w_label; reg [1:0] w_sdi; reg [18:0] w_data; reg [1:0] w_ssm;
        integer j, planned_events, occ_before;
        begin
            fault_tests = fault_tests + 1;
            random_word(w_label, w_sdi, w_data, w_ssm);
            while (fifo_occ > 0) fifo_model_read;  /* ensure empty */
            planned_events = burst_reads;
            run_transaction(w_label, w_sdi, w_data, w_ssm, 32'h0, 32'h0, 1'b1,
                            CLASS_FIFO_UNF, "FIFO_UNDERFLOW(verification-modeled)", 1'b0);
            occ_before = fifo_occ;
            for (j = 0; j < planned_events; j = j + 1)
                fifo_model_read;
            fifo_underflow_expected_limit = fifo_underflow_expected_limit + planned_events;
            expected_limitations = expected_limitations + planned_events;
            faults_injected = faults_injected + planned_events;
            fifo_underflow_count = fifo_underflow_count + planned_events;
            consecutive_error_count = consecutive_error_count + 1;
            last_fault_txn_id = txn_id;
            last_error_type   = CLASS_FIFO_UNF;
            if (last_rx_valid_seen && (last_rx_word_obs === last_recv_exp_word) &&
                last_wire_ok && last_timing_ok &&
                (fifo_underflow_events >= planned_events)) begin
                passed_tests = passed_tests + 1;
                $display("Result              : PASS (verification-modeled FIFO underflow)");
                $display("                      occupancy_before=%0d reads_attempted=%0d underflow_events=%0d",
                         occ_before, planned_events, planned_events);
                $display("                      NO FIFO HARDWARE IN RTL - VERIFICATION-MODELED EVENT (expected limitation)");
            end else begin
                failed_tests = failed_tests + 1;
                $display("Result              : FAIL [FRAMEWORK FAILURE] FIFO underflow case inconsistent");
            end
            write_csv_row(CLASS_FIFO_UNF, -1, 0, 0, last_rx_valid_seen,
                          last_txdone_seen, 0);
        end
    endtask

    /* APPLICATION-DEFINED invalid label (DUT has no label validator) */
    task run_invalid_label_case;
        input [7:0] bad_label;
        input integer quiet;
        reg [7:0] w_label; reg [1:0] w_sdi; reg [18:0] w_data; reg [1:0] w_ssm;
        begin
            invalid_label_faults = invalid_label_faults + 1;
            faults_injected = faults_injected + 1;
            fault_tests = fault_tests + 1;
            random_word(w_label, w_sdi, w_data, w_ssm);
            w_label = bad_label;
            fault_pos_scratch = -1;
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
            end
            if (last_rx_valid_seen && (last_rx_word_obs === last_recv_exp_word) &&
                (last_parity_obs === 1'b0) && last_wire_ok && last_timing_ok) begin
                invalid_label_expected_limit = invalid_label_expected_limit + 1;
                expected_limitations = expected_limitations + 1;
                passed_tests = passed_tests + 1;
                if (!quiet) begin
                    $display("Result              : PASS (fault observed at verification level)");
                    $display("                      received_label=%h is APPLICATION-DEFINED INVALID (not in supported set)", bad_label);
                    $display("                      DUT accepted the word: NO label validator in RTL - EXPECTED LIMITATION");
                    $display("                      NOT an ARINC protocol violation claim");
                end
            end else begin
                failed_tests = failed_tests + 1;
                $display("Result              : FAIL [DUT FAILURE] unexpected DUT response on invalid-label word");
            end
            write_csv_row(CLASS_INVALID_LBL, -1, 0, last_parity_obs,
                          last_rx_valid_seen, last_txdone_seen, 0);
        end
    endtask

    /* bus idle: suppress ALL activity for a random duration >= threshold */
    task run_bus_idle_case;
        input integer min_cycles;
        integer idle_wait, n;
        integer tx_b, rx_b;
        begin
            bus_idle_cases = bus_idle_cases + 1;
            faults_injected = faults_injected + 1;
            fault_tests = fault_tests + 1;
            total_tests = total_tests + 1;
            idle_wait = min_cycles + rand_range(0, 4000);
            tx_b = tx_done_count;
            rx_b = rx_valid_count;
            $display("------------------------------------------------------------");
            $display("Transaction ID      : %0d", txn_id + 1);
            $display("Fault class         : BUS_IDLE_ERROR");
            $display("Idle threshold      : %0d cycles (PROJECT-DEFINED)", idle_threshold_cycles);
            txn_id = txn_id + 1;
            seed_at_txn = user_seed;
            for (n = 0; n < idle_wait; n = n + 1)
                @(posedge clk);
            @(negedge clk);
            last_idle_event = ((tx_done_count == tx_b) && (rx_valid_count == rx_b) &&
                               (tx_busy === 1'b0) && (rx_busy === 1'b0));
            bus_idle_expected_limit = bus_idle_expected_limit + 1;
            expected_limitations = expected_limitations + 1;
            bus_idle_count = bus_idle_count + 1;
            last_idle_duration = idle_wait;
            consecutive_error_count = consecutive_error_count + 1;
            last_fault_txn_id = txn_id;
            last_error_type   = CLASS_BUS_IDLE;
            if (last_idle_event) begin
                passed_tests = passed_tests + 1;
                $display("Result              : PASS (fault observed at verification level)");
                $display("                      idle_duration=%0d cycles (%0d us) - no TX/RX activity", idle_wait, idle_wait * CLK_PERIOD_NS / 1000);
                $display("                      DUT IDLE DETECTOR: ABSENT - EXPECTED LIMITATION (no such RTL hardware)");
            end else begin
                failed_tests = failed_tests + 1;
                $display("Result              : FAIL [DUT FAILURE] activity observed during forced idle window");
            end
            write_csv_row(CLASS_BUS_IDLE, -1, 0, 0, 0, 0, 0);
        end
    endtask

    /* repeated communication error block (same error, consecutive txns) */
    task run_repeated_block;
        input integer base_class;     /* CLASS_PARITY or CLASS_INVALID_LBL */
        input integer rep_count;
        integer m, gap_since, member_fail_before;
        reg detected_flag;
        begin
            repeated_error_cases = repeated_error_cases + 1;
            gap_since = txn_id - last_fault_txn_id;
            member_fail_before = failed_tests;
            detected_flag = 1'b0;
            $display("============================================================");
            $display("REPEATED ERROR BLOCK: base=%0s repeat_count=%0d (gap_since_last=%0d)",
                     class_name(base_class), rep_count, gap_since);
            $display("============================================================");
            for (m = 0; m < rep_count; m = m + 1) begin
                if (base_class == CLASS_PARITY) begin
                    run_parity_fault_rand(1'b0);
                    if (last_parity_obs === 1'b1) detected_flag = 1'b1;
                end else begin
                    run_invalid_label_case(pick_invalid_label(0), 1'b0);
                    /* no DUT label validator: cannot be flagged */
                end
            end
            repeated_error_count = repeated_error_count + 1;
            if (detected_flag)
                repeated_error_detected = repeated_error_detected + 1;
            else
                repeated_error_undetected = repeated_error_undetected + 1;
            $display("REPEATED BLOCK SUMMARY: consecutive_error_count=%0d total_errors_in_block=%0d detected=%0s",
                     rep_count, rep_count, detected_flag ? "YES" : "NO");
        end
    endtask

    /* high error rate statistical window */
    task run_high_rate_window;
        input integer planned_faults;
        integer w, i, p, assigned, win_faults, member_class;
        reg is_fault [0:63];
        reg [255:0] combo;
        reg [7:0] n_label; reg [1:0] n_sdi; reg [18:0] n_data; reg [1:0] n_ssm;
        begin
            high_error_rate_cases = high_error_rate_cases + 1;
            w = error_rate_window;
            if (w > 64) w = 64;
            for (i = 0; i < w; i = i + 1) is_fault[i] = 1'b0;
            assigned = 0;
            while (assigned < planned_faults) begin
                p = rand_range(0, w - 1);
                if (!is_fault[p]) begin
                    is_fault[p] = 1'b1;
                    assigned = assigned + 1;
                end
            end
            $display("============================================================");
            $display("HIGH-RATE WINDOW: window=%0d txns, planned_faults=%0d (threshold=%0d%% PROJECT-DEFINED)",
                     w, planned_faults, high_error_rate_threshold_pct);
            $display("============================================================");
            win_faults = 0;
            for (i = 0; i < w; i = i + 1) begin
                if (is_fault[i]) begin
                    win_faults = win_faults + 1;
                    member_class = ({$random(rng_seed)} % 2) ? CLASS_PARITY
                                                              : CLASS_INVALID_LBL;
                    if (member_class == CLASS_PARITY) begin
                        run_parity_fault_rand(1'b1);
                        $display("  [WINDOW %0d/%0d] COMBO: PARITY_ERROR within HIGH-RATE window", i + 1, w);
                    end else begin
                        run_invalid_label_case(pick_invalid_label(0), 1'b1);
                        $display("  [WINDOW %0d/%0d] COMBO: INVALID_LABEL within HIGH-RATE window", i + 1, w);
                    end
                end else begin
                    random_word(n_label, n_sdi, n_data, n_ssm);
                    run_transaction(n_label, n_sdi, n_data, n_ssm, 32'h0, 32'h0,
                                    1'b1, CLASS_NORMAL, "WINDOW_NORMAL", 1'b1);
                end
            end
            last_error_rate = (100.0 * win_faults) / w;
            $display("HIGH-RATE WINDOW SUMMARY: total=%0d faulty=%0d error_rate=%0d%%",
                     w, win_faults, $rtoi(last_error_rate));
            if (win_faults * 100 >= high_error_rate_threshold_pct * w) begin
                high_error_rate_detected = high_error_rate_detected + 1;
                $display("                          CLASSIFICATION: HIGH ERROR RATE (>= threshold)");
            end else begin
                high_error_rate_below = high_error_rate_below + 1;
                $display("                          CLASSIFICATION: below threshold");
            end
            last_error_type = CLASS_HIGH_RATE;
        end
    endtask

    /*------------------------------------------------------------------------
     * RESET-DURING-FAULT SCENARIOS (classified RESET RECOVERY - NOT
     * communication faults; verified: clean outputs, no stale events,
     * next transaction normal)
     *----------------------------------------------------------------------*/
    task run_reset_case;
        input integer variant;     /* 1 parity-fault TX, 2 incomplete word,
                                      3 repeated-error context, 4 idle     */
        reg [7:0] w_label; reg [1:0] w_sdi; reg [18:0] w_data; reg [1:0] w_ssm;
        integer tx_b, rx_b, n;
        reg checks_ok, no_stale;
        reg [255:0] vname;
        reg [31:0] corrupt_mask_reset;
        begin
            total_tests = total_tests + 1;
            reset_tests = reset_tests + 1;
            checks_ok = 1'b1;
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
                /* context: one completed parity-fault transaction first */
                run_parity_fault_rand(1'b1);
            end

            if (variant != 4) begin
                /* arm receiver and start a transmission */
                @(negedge clk);
                rx_start = 1'b1;
                @(negedge clk);
                rx_start = 1'b0;
                corrupt_mask_reset = (variant == 3) ? 32'h00001000 : 32'h00000000;
                if (variant == 1 || variant == 3) fiu_corrupt = corrupt_mask_reset[0];
                if (variant == 2)                 fiu_idle    = 1'b1;
                @(negedge clk);
                label    = w_label;
                sdi      = w_sdi;
                data     = w_data;
                ssm      = w_ssm;
                tx_start = 1'b1;
                @(posedge clk);
                @(negedge clk);
                tx_start = 1'b0;
                /* reach mid-word, then reset */
                if (variant == 3) begin
                    repeat (20 * CYCLES_PER_BIT) @(negedge clk);
                end else begin
                    repeat (10 * CYCLES_PER_BIT) @(negedge clk);
                end
                if (variant == 3) begin
                    /* start a second (repeated) fault transmission */
                    corrupt_mask_reset = 32'h00000020;
                    fiu_corrupt = corrupt_mask_reset[0];
                    @(negedge clk);
                    tx_start = 1'b1;
                    @(posedge clk);
                    @(negedge clk);
                    tx_start = 1'b0;
                    repeat (10 * CYCLES_PER_BIT) @(negedge clk);
                end
            end else begin
                /* idle condition: confirm bus quiet first */
                repeat (100) @(posedge clk);
                @(negedge clk);
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

            if (checks_ok && no_stale) begin
                reset_passed = reset_passed + 1;
                passed_tests = passed_tests + 1;
                $display("Result              : PASS (DUT returned to reset state, no stale events)");
            end else begin
                reset_failed = reset_failed + 1;
                failed_tests = failed_tests + 1;
                $display("Result              : FAIL [DUT FAILURE] reset recovery incomplete");
            end
            write_csv_row(CLASS_RESET, -1, 0, 0, 0, 0, 0);
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
            $display("============================================================");
            run_timeout_fault(0);
            run_timeout_fault(1);
            run_timeout_fault(2);

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
            $display("DIRECTED SUITE 6: bus idle error");
            $display("============================================================");
            run_bus_idle_case(idle_threshold_cycles);
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
            run_timeout_fault(rand_range(0, 2));
            run_timeout_fault(rand_range(0, 2));
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
                        2 : run_timeout_fault(rand_range(0, 2));
                        3 : run_fifo_overflow_case(rand_range(0, 2));
                        4 : run_fifo_underflow_case(rand_range(1, 3));
                        5 : run_invalid_label_case(pick_invalid_label(0), 1'b1);
                        6 : run_repeated_block(
                                ({$random(rng_seed)} % 2) ? CLASS_PARITY : CLASS_INVALID_LBL,
                                rand_range(repeat_error_min, repeat_error_max));
                        7 : run_bus_idle_case(idle_threshold_cycles);
                        8 : begin
                                planned = rand_range(2, error_rate_window);
                                run_high_rate_window(planned);
                            end
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
     * SUMMARY + COUNTER CONSISTENCY
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
            $display("------------------------------------------------------------");
            $display("parity_faults                = %0d", parity_faults);
            $display("parity_detected              = %0d", parity_detected);
            $display("parity_undetected            = %0d", parity_undetected);
            $display("two_bit_faults               = %0d", two_bit_faults);
            $display("two_bit_limitations          = %0d", two_bit_limitations);
            $display("timeout_faults               = %0d", timeout_faults);
            $display("timeout_observed             = %0d", timeout_observed);
            $display("timeout_detected_by_dut      = 0   (no timeout detector in RTL)");
            $display("fifo_overflow_events         = %0d (verification-modeled)", fifo_overflow_events);
            $display("fifo_underflow_events        = %0d (verification-modeled)", fifo_underflow_events);
            $display("invalid_label_faults         = %0d", invalid_label_faults);
            $display("repeated_error_cases         = %0d", repeated_error_cases);
            $display("repeated_error_detected      = %0d", repeated_error_detected);
            $display("bus_idle_cases               = %0d", bus_idle_cases);
            $display("high_error_rate_cases        = %0d", high_error_rate_cases);
            $display("high_error_rate_detected     = %0d", high_error_rate_detected);
            $display("high_error_rate_below        = %0d", high_error_rate_below);
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
            if (faults_injected !== faults_detected + faults_undetected + expected_limitations) begin
                v = v + 1;
                $display("CONSISTENCY E2  FAIL: faults_injected != detected+undetected+limitations");
            end
            if (parity_faults !== parity_detected + parity_undetected) begin
                v = v + 1;
                $display("CONSISTENCY E3  FAIL: parity ledger");
            end
            if (two_bit_faults !== two_bit_limitations) begin
                v = v + 1;
                $display("CONSISTENCY E4  FAIL: two-bit ledger");
            end
            if (timeout_faults !== timeout_expected_limit) begin
                v = v + 1;
                $display("CONSISTENCY E5  FAIL: timeout ledger");
            end
            if (fifo_overflow_events !== fifo_overflow_expected_limit) begin
                v = v + 1;
                $display("CONSISTENCY E6  FAIL: fifo overflow ledger");
            end
            if (fifo_underflow_events !== fifo_underflow_expected_limit) begin
                v = v + 1;
                $display("CONSISTENCY E7  FAIL: fifo underflow ledger");
            end
            if (invalid_label_faults !== invalid_label_expected_limit) begin
                v = v + 1;
                $display("CONSISTENCY E8  FAIL: invalid label ledger");
            end
            if (bus_idle_cases !== bus_idle_expected_limit) begin
                v = v + 1;
                $display("CONSISTENCY E9  FAIL: bus idle ledger");
            end
            if (repeated_error_cases !== repeated_error_detected + repeated_error_undetected) begin
                v = v + 1;
                $display("CONSISTENCY E10 FAIL: repeated ledger");
            end
            if (high_error_rate_cases !== high_error_rate_detected + high_error_rate_below) begin
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
        rng_seed = user_seed;    /* $random advances rng_seed; user_seed
                                    stays immutable for logging/CSV       */

        /*---------------- counter initialization -------------------------*/
        txn_id = 0; sample_id = 0;
        total_tests = 0; passed_tests = 0; failed_tests = 0;
        normal_tests = 0; normal_passed = 0; normal_failed = 0;
        fault_tests = 0;
        faults_injected = 0; faults_detected = 0; faults_undetected = 0;
        expected_limitations = 0;
        parity_faults = 0; parity_detected = 0; parity_undetected = 0;
        two_bit_faults = 0; two_bit_limitations = 0;
        timeout_faults = 0; timeout_observed = 0; timeout_expected_limit = 0;
        fifo_overflow_events = 0; fifo_overflow_expected_limit = 0;
        fifo_underflow_events = 0; fifo_underflow_expected_limit = 0;
        invalid_label_faults = 0; invalid_label_expected_limit = 0;
        repeated_error_cases = 0; repeated_error_detected = 0;
        repeated_error_undetected = 0;
        bus_idle_cases = 0; bus_idle_expected_limit = 0;
        high_error_rate_cases = 0; high_error_rate_detected = 0;
        high_error_rate_below = 0;
        bit_faults_by_label = 0; bit_faults_by_sdi = 0; bit_faults_by_data = 0;
        bit_faults_by_ssm = 0; bit_faults_by_parity = 0;
        reset_tests = 0; reset_passed = 0; reset_failed = 0;
        timing_failures = 0; consistency_violations = 0; tb_internal_errors = 0;
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
        fault_pos_scratch = -1;
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
        $fdisplay(csv_fd, "sample_id,seed,transaction_id,fault_class,fault_type,fault_position,total_transactions,valid_transactions,error_count,parity_error_count,timeout_count,fifo_overflow_count,fifo_underflow_count,invalid_label_count,repeated_error_count,bus_idle_count,idle_duration,error_rate,consecutive_error_count,last_error_type,rx_word_mismatch,parity_error,rx_valid,tx_done,health_label");

        /*---------------- banner -----------------------------------------*/
        $display("============================================================");
        $display("ARINC 429 PHASE-1 FAULT INJECTION TESTBENCH (Review-2)");
        $display("============================================================");
        $display("USER_SEED                    = %0d  (same seed reproduces the identical fault sequence)", user_seed);
        $display("RUN MODE                     = %0d  (0=NORMAL, 1=RANDOM, 2=DIRECTED)", run_mode);
        $display("NUM_RANDOM_TESTS             = %0d", num_random_tests);
        $display("FAULT_PROBABILITY            = %0d %%", fault_probability_pct);
        $display("ERROR_RATE_WINDOW            = %0d transactions", error_rate_window);
        $display("HIGH_ERROR_RATE_THRESHOLD    = %0d %%   [PROJECT-DEFINED]", high_error_rate_threshold_pct);
        $display("TIMEOUT_THRESHOLD            = %0d cycles (%0d us) [PROJECT-DEFINED]", timeout_threshold_cycles, timeout_threshold_cycles * CLK_PERIOD_NS / 1000);
        $display("IDLE_THRESHOLD               = %0d cycles (%0d us) [PROJECT-DEFINED]", idle_threshold_cycles, idle_threshold_cycles * CLK_PERIOD_NS / 1000);
        $display("FIFO_DEPTH (verification model) = %0d  [NO FIFO IN RTL]", fifo_depth);
        $display("REPEAT_ERROR_RANGE           = %0d..%0d", repeat_error_min, repeat_error_max);
        $display("CYCLES_PER_BIT=%0d GAP_CYCLES=%0d TOTAL_TX_CYCLES=%0d RX_VALID_DELAY=%0d",
                 CYCLES_PER_BIT, GAP_CYCLES, TOTAL_TX_CYCLES, RX_VALID_DELAY_CYCLES);
        $display("CSV dataset file             = %0s", csv_name);
        $display("DUT files: UNMODIFIED Review-1 RTL; injector: TESTBENCH ONLY");
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
            (passed_tests == total_tests)) begin
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




