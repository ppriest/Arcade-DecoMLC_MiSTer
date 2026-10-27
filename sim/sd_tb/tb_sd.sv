// SPDX-License-Identifier: GPL-3.0-or-later
// The video output path with each Scandoubler Fx: mlc_video_timing -> crt_chain -> arcade_video,
// as DecoMLC.sv wires them. Prints, per frame, what reaches VGA_*: lines with DE, DE pixels per
// line, HS and VS pulses, CE_PIXEL count. +FX=n (0-4), +ADJ=1 (CRT Adjust on), +FRAMES=n.
module tb_sd;
	logic clk = 0;
	always #1 clk = ~clk;
	logic reset = 1;

	logic       ce_pix, hblank, vblank, hs, vs;
	logic [8:0] hpos, vpos, dvpos;
	mlc_video_timing u_t (
		.clk, .reset, .ce_pix, .hpos, .vpos, .dvpos, .hblank, .vblank, .hs, .vs,
		.line_start(), .render_line_v(), .render_line(), .vbl_start()
	);
	wire [7:0] r8 = hpos[7:0], g8 = vpos[7:0], b8 = 8'h55;

	int fx = 0, adj = 0;
	wire [2:0] fx3 = 3'(fx);
	wire crt_ce, crt_hs, crt_vs, crt_hb, crt_vb;
	wire [7:0] crt_r, crt_g, crt_b;
	crt_chain #(.HTOTAL(442), .VTOTAL(274), .ACTIVE_W(320), .RD_BASE(48)) u_crt (
		.clk, .ce_pix, .active(adj != 0), .scale_en(fx3 == 3'd0),
		.hoffset('0), .voffset('0), .hsize('0), .vsize_step('0), .vsize_cabinet(1'b0),
		.r_in(r8), .g_in(g8), .b_in(b8),
		.hs_in(hs), .vs_in(vs), .hb_in(hblank), .vb_in(vblank),
		.ce_out(crt_ce), .r_out(crt_r), .g_out(crt_g), .b_out(crt_b),
		.hs_out(crt_hs), .vs_out(crt_vs), .hb_out(crt_hb), .vb_out(crt_vb)
	);

	wire        CLK_VIDEO, CE_PIXEL, VGA_HS, VGA_VS, VGA_DE;
	wire [7:0]  VGA_R, VGA_G, VGA_B;
	wire [1:0]  VGA_SL;
	wire [21:0] gamma_bus;
	assign gamma_bus[20:0] = '0;
	arcade_video #(.WIDTH(320), .DW(24), .GAMMA(1)) u_av (
		.clk_video(clk), .ce_pix(crt_ce),
		.RGB_in({crt_r, crt_g, crt_b}), .HBlank(crt_hb), .VBlank(crt_vb), .HSync(crt_hs), .VSync(crt_vs),
		.CLK_VIDEO, .CE_PIXEL, .VGA_R, .VGA_G, .VGA_B, .VGA_HS, .VGA_VS, .VGA_DE, .VGA_SL,
		.fx(fx3), .forced_scandoubler(1'b0), .gamma_bus
	);

	int frames = 6, f = 0;
	int de_lines, de_px, de_px_min, de_px_max, hs_n, ce_n, lines_n, crt_ce_n;
	logic vs_d, hs_d, de_d;
	initial begin
		void'($value$plusargs("FX=%d", fx));
		void'($value$plusargs("ADJ=%d", adj));
		void'($value$plusargs("FRAMES=%d", frames));
		repeat (20) @(posedge clk);
		reset = 0;
	end
	always @(posedge clk) begin
		vs_d <= VGA_VS; hs_d <= VGA_HS;
		if (CE_PIXEL) begin
			ce_n++;
			de_d <= VGA_DE;
			if (VGA_DE) de_px++;
			if (de_d && !VGA_DE) begin
				de_lines++;
				if (de_px < de_px_min) de_px_min = de_px;
				if (de_px > de_px_max) de_px_max = de_px;
				de_px = 0;
			end
		end
		if (crt_ce) crt_ce_n++;
		if (VGA_HS && !hs_d) hs_n++;
		if (VGA_VS && !vs_d) begin
			$display("fx %0d frame %0d: DE lines %0d, DE px/line %0d-%0d, HS %0d, CE_PIXEL %0d, crt_ce %0d",
			         fx, f, de_lines, de_px_min, de_px_max, hs_n, ce_n, crt_ce_n);
			de_lines = 0; de_px = 0; de_px_min = 9999; de_px_max = 0; hs_n = 0; ce_n = 0; crt_ce_n = 0;
			f++;
			if (f == frames) $finish;
		end
	end
	// one input frame is 442 * 274 * 12 clocks: report each, whether or not VGA_VS came
	int clk_n = 0, vs_t = 0, de_n = 0;
	always @(posedge clk) begin
		clk_n++;
		if (VGA_VS != vs_d) vs_t++;
		if (VGA_DE) de_n++;
		if (clk_n % (442 * 274 * 12) == 0) begin
			$display("  period %0d: VGA_VS toggles %0d, VGA_VS=%0d, HS %0d, clocks with DE %0d, CE_PIXEL %0d, in VS=%0d HS=%0d HBL=%0d VBL=%0d",
			         clk_n / (442 * 274 * 12), vs_t, VGA_VS, hs_n, de_n, ce_n, u_av.VS, u_av.HS, u_av.HBL, u_av.VBL);
			vs_t = 0; de_n = 0;
			if (clk_n / (442 * 274 * 12) == 8) $finish;
		end
	end
endmodule
