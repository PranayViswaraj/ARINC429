`timescale 1ns/1ps
/*==============================================================================
 * FILE   : arinc429_fault_injector.v
 * STATUS : VERIFICATION-ONLY HELPER  --  TESTBENCH ONLY  --  DO NOT SYNTHESIZE
 *
 *          This file must NOT be added to the synthesis / FPGA implementation
 *          file set. It contains no clocked logic and no reset. It exists only
 *          inside the Phase-1 fault-injection testbench.
 *
 * ROLE (Phase-1 / Review-2 fault injection architecture):
 *
 *        NORMAL TX (arinc429_tx, inside arinc429_controller, UNMODIFIED)
 *                                |
 *                                v
 *                 arinc429_fault_injector  (THIS MODULE, testbench only)
 *                                |
 *                                v
 *        NORMAL RX (arinc429_rx, inside arinc429_controller, UNMODIFIED)
 *
 * The Review-1 DUT remains GOLDEN: no DUT port, FSM, timing or parity logic
 * is modified. The injector is a pure combinational pass-through element
 * inserted on the serial wire between the controller's arinc_tx output pin
 * and its arinc_rx_ext input pin. When both control inputs are low the module
 * is exactly a wire, so with fault injection disabled the DUT sees a normal
 * Review-1 serial link.
 *
 * CONTROL PROTOCOL (driven by tb_arinc429_fault_injection):
 *   inject_corrupt = 1 : line_out = ~line_in    (single-bit corruption of the
 *                                               serial bit currently on the
 *                                               wire)
 *   force_idle    = 1  : line_out = 0            (dominant: suppresses the
 *                                               transmitted stream, used for
 *                                               truncated-word / communication
 *                                               timeout faults)
 *   both = 0           : line_out = line_in      (NORMAL MODE: exact wire)
 *
 * The testbench owns ALL randomization ($random with an explicit seed) and
 * owns the serial bit schedule; this module deliberately contains no state,
 * no counter and no randomness, so every injected fault is fully traceable to
 * a testbench decision.
 *============================================================================*/

module arinc429_fault_injector (
    input  wire line_in,         // serial stream from DUT arinc_tx output pin
    input  wire inject_corrupt,  // 1 = invert the bit currently on the wire
    input  wire force_idle,      // 1 = force line low (dominant over corrupt)
    output wire line_out         // serial stream to DUT arinc_rx_ext input pin
);

    assign line_out = force_idle    ? 1'b0    :
                      inject_corrupt ? ~line_in :
                                       line_in;

endmodule
