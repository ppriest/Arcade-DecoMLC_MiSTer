// SPDX-License-Identifier: GPL-3.0-or-later
// The DE156 (the Amber a23 ARMv2a, rtl/cpu/amber) on mlc_core's bus glue, in place of the
// SH-2's jtsh7604 seam: the same request signals, cache_cs held with the address, data and lane
// strobes until cache_ok.
//
// The CPU runs on clk_cpu, 42 MHz from the same PLL as the glue's 84 MHz (the Amber's paths do
// not close at 84 MHz), with i_system_rdy as its clock enable: 1 in 3, 14 MHz, which is MAME's
// 7 MHz with set_clock_scale(2.0) (deco_mlc.cpp init_mlc; docs/MAME_KLUDGES.md). The enable is
// also held by pause and while coprocessor 0 works.
//
// The crossing: every signal to the glue comes from a 42 MHz register or the Amber's own, and
// the glue's answer (cache_ok, the read data) is registered on the 42 MHz side before the Amber
// sees it, so no 84 MHz register drives the Amber's logic. An access is acknowledged once, then
// the request is withheld until the glue's answer has dropped, because Wishbone may start its
// next access on the clock after an ack without dropping its strobe and the glue needs the
// request to fall between accesses.
//
// Byte lanes are bit positions on both CPUs (sel[k] = bits 8k+7:8k), so the glue's decode and
// MAME's umask32 values hold unchanged; only byte addressing within a word differs (the ARM is
// little-endian).
module mlc_de156 (
	input  logic         clk_cpu,
	input  logic         reset,
	input  logic         pause,
	input  logic         irq,             // IRQ, a level (MAME's ARM7_IRQ_LINE, HOLD_LINE)

	output logic         cache_cs,
	output logic         cache_rd,
	output logic         cache_wr,
	output logic [26:1]  cache_addr,
	output logic [31:0]  cache_din,
	output logic [3:0]   cache_dsn,
	input  logic         cache_ok,
	input  logic [31:0]  cpu_din
);
	logic [1:0] div = 2'd0;
	always_ff @(posedge clk_cpu) div <= (div == 2'd2) ? 2'd0 : div + 2'd1;

	logic [31:0] wb_adr, wb_wdat;
	logic [3:0]  wb_sel;
	logic        wb_we, wb_cyc, wb_stb, busy;

	// the glue's answer, on this side
	logic        ok_r, done, irq_r;
	logic [31:0] din_r;
	always_ff @(posedge clk_cpu) begin
		ok_r  <= cache_ok;
		din_r <= cpu_din;
		irq_r <= irq;
		if (reset)     done <= 1'b0;
		else if (ack)  done <= 1'b1;
		else if (!ok_r) done <= 1'b0;
	end
	wire ack = ok_r && !done && wb_cyc && wb_stb;

	a23_core u_arm (
		.i_clk(clk_cpu), .i_reset(reset), .i_irq(irq_r), .i_firq(1'b0),
		.i_system_rdy(div == 2'd0 && !pause && !busy),
		.o_wb_adr(wb_adr), .o_wb_sel(wb_sel), .o_wb_we(wb_we), .i_wb_dat(din_r), .o_wb_dat(wb_wdat),
		.o_wb_cyc(wb_cyc), .o_wb_stb(wb_stb), .i_wb_ack(ack), .i_wb_err(1'b0), .o_wb_tga(),
		.o_copro_busy(busy)
	);

	assign cache_cs   = wb_cyc && wb_stb && !done && !(ok_r && !done);
	assign cache_wr   = wb_we;
	assign cache_rd   = !wb_we;
	assign cache_addr = wb_adr[26:1];
	assign cache_din  = wb_wdat;
	assign cache_dsn  = ~wb_sel;
endmodule
