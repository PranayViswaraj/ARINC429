#!/bin/bash
# ============================================================
# PHASE-1 / REVIEW-2 full re-verification run (fresh evidence)
# Deliverable set: /home/z/my-project/download/review2_phase1_fixed
# Tool: Icarus Verilog 12.0 (local install, no root)
# ============================================================
set +u
export IV=/home/z/my-project/tools/iv-root/usr/bin
export LD_LIBRARY_PATH=/home/z/my-project/tools/iv-root/usr/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}
D=/home/z/my-project/download/review2_phase1_fixed
S=/home/z/my-project/sim/recheck
mkdir -p $S
cd $S

echo "=== [1/3] Review-1 regressions on DELIVERED DUT (byte-identical to upload) ==="
$IV/iverilog -g2001 -o regr_tx.vvp $D/rtl/arinc429_tx.v        $D/tb_review1/tb_arinc429_tx_review1_fix.v        && $IV/vvp regr_tx.vvp    > regr_tx.log 2>&1;    tail -4 regr_tx.log
$IV/iverilog -g2001 -o regr_rx.vvp $D/rtl/arinc429_rx.v        $D/tb_review1/tb_arinc429_rx_review1_fix.v        && $IV/vvp regr_rx.vvp    > regr_rx.log 2>&1;    tail -4 regr_rx.log
$IV/iverilog -g2001 -o regr_ctl.vvp $D/rtl/arinc429_tx.v $D/rtl/arinc429_rx.v $D/rtl/arinc429_controller.v $D/tb_review1/tb_arinc429_controller_review1_fix.v && $IV/vvp regr_ctl.vvp > regr_ctl.log 2>&1; tail -4 regr_ctl.log

echo "=== [2/3] Fault-injection framework (corrected rev B TB) ==="
RTL="$D/rtl/arinc429_tx.v $D/rtl/arinc429_rx.v $D/rtl/arinc429_controller.v $D/tb/arinc429_fault_injector.v"
$IV/iverilog -g2001 -o fi.vvp $RTL $D/tb/tb_arinc429_fault_injection.v || { echo COMPILE-FAIL; exit 1; }

$IV/vvp fi.vvp +MODE=0                         > mode0.log 2>&1;   tail -3 mode0.log
$IV/vvp fi.vvp +MODE=2                         > mode2.log 2>&1;   tail -3 mode2.log
$IV/vvp fi.vvp +MODE=1                         > mode1_s1.log 2>&1; tail -3 mode1_s1.log
$IV/vvp fi.vvp +MODE=1 +SEED=42 +TESTS=12      > mode1_s42a.log 2>&1
$IV/vvp fi.vvp +MODE=1 +SEED=42 +TESTS=12      > mode1_s42b.log 2>&1
$IV/vvp fi.vvp +MODE=1 +SEED=7  +TESTS=12      > mode1_s7.log 2>&1
echo "seed reproducibility (42a vs 42b):"; cmp -s mode1_s42a.log mode1_s42b.log && echo "  IDENTICAL logs" || echo "  DIFFER (FAIL)"
echo "seed variation (42a vs 7):";        cmp -s mode1_s42a.log mode1_s7.log   && echo "  IDENTICAL (FAIL)" || echo "  differ (expected)"

echo "=== [3/3] clamped-config smoke (FI-17) ==="
$IV/vvp fi.vvp +MODE=0 +SEED=3 +IDLE=100 +TIMEOUT=5 +THRESH=0 +WINDOW=1 +FDEPTH=99 +REPMIN=9 +REPMAX=2 > clamps.log 2>&1
grep -m1 "NOTE:" clamps.log
tail -3 clamps.log
echo "ALL RUNS DONE - logs in $S"
