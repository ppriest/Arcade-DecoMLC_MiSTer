// SPDX-License-Identifier: GPL-3.0-or-later
// 442 x 274 at a 7 MHz pixel clock from 84 MHz (docs/ROADMAP.md, Clocks; docs/HACKS.md: the
// driver has no raw timing, this is Data East's standard). Lines carry MAME's numbers: 8-247
// visible (mlc 567), 248 the vblank start where the list is copied (v 545). A line period is
// 5304 clocks; it starts one pixel clock before the line's first visible pixel, on the clock
// the counters wrap, so the line buffer has swapped before scan-out reads it. line_start marks
// that clock and names the line the engine renders during the period: the line that is
// starting, as MAME draws a line at its start with the registers as they are then
// (VIDEO_UPDATE_SCANLINE). The picture is shown a line later: dvpos, vblank and vs count the
// displayed line, one behind vpos, which stays the game's (the 0x200074 read, the interrupt).
module mlc_video_timing (
	input  logic       clk,
	input  logic       reset,

	output logic       ce_pix,        // one clock in twelve
	output logic [8:0] hpos,          // 0..441
	output logic [8:0] vpos,          // 0..273, MAME's line number
	output logic [8:0] dvpos,         // the displayed line: vpos - 1
	output logic       hblank,        // hpos >= 320
	output logic       vblank,        // dvpos not 8..247
	output logic       hs,            // hpos 360..391
	output logic       vs,            // dvpos 256..258

	output logic       line_start,    // first clock of a line period
	output logic       render_line_v, // the period renders a visible line
	output logic [8:0] render_line,   // that line, 8..247
	output logic       vbl_start      // the period is line 248's
);

	localparam int HTOTAL = 442, VTOTAL = 274;

	logic [3:0] div;
	assign ce_pix = (div == 4'd0);

	wire [8:0] next_v = (vpos == VTOTAL - 1) ? 9'd0 : vpos + 9'd1;
	wire       wrap   = ce_pix && (hpos == HTOTAL - 1);

	always_ff @(posedge clk) begin
		if (reset) begin
			div  <= '0;
			hpos <= HTOTAL - 1;
			vpos <= 9'd247;              // the first period after reset is line 248's
		end else begin
			div <= (div == 4'd11) ? 4'd0 : div + 4'd1;
			if (ce_pix) begin
				if (hpos == HTOTAL - 1) begin
					hpos <= '0;
					vpos <= next_v;
				end else begin
					hpos <= hpos + 9'd1;
				end
			end
		end
	end

	assign hblank = (hpos >= 9'd320);
	assign dvpos  = (vpos == 9'd0) ? VTOTAL[8:0] - 9'd1 : vpos - 9'd1;
	assign vblank = (dvpos < 9'd8) || (dvpos > 9'd247);
	assign hs = (hpos >= 9'd360) && (hpos < 9'd392);
	assign vs = (dvpos >= 9'd256) && (dvpos < 9'd259);

	assign line_start    = !reset && wrap;
	assign vbl_start     = line_start && (next_v == 9'd248);
	assign render_line   = next_v;
	assign render_line_v = (next_v >= 9'd8) && (next_v <= 9'd247);

endmodule
