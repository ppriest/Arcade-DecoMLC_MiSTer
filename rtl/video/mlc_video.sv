// SPDX-License-Identifier: GPL-3.0-or-later
// The MLC video block: timing, the sprite list, VRAM, the palette, the clip and IRQ-block
// registers the engine reads, the engine, the line buffer and scan-out (docs/phase1_video.md).
// The CPU-side ports are plain RAM/register writes; the bus glue that decodes the SH-2's
// addresses onto them is Phase 2.
module mlc_video
	import mlc_video_pkg::*;
(
	input  logic         clk,
	input  logic         reset,
	input  logic         video_reset,     // the raster only: it runs through the game's reset

	// CPU side: 32-bit stores to the list and the palette carry the word in the low half
	// (the boot trace has no narrower write to either); reads answer the next clock
	input  logic         list_we,
	input  logic [11:0]  list_addr,
	input  logic [15:0]  list_wdata,
	output logic [15:0]  list_rdata,
	input  logic         vram_we,
	input  logic [14:0]  vram_addr,
	input  logic [31:0]  vram_wdata,
	input  logic [3:0]   vram_be,
	output logic [31:0]  vram_rdata,
	input  logic         pal_we,
	input  logic [10:0]  pal_addr,
	input  logic [15:0]  pal_wdata,
	output logic [15:0]  pal_rdata,
	input  logic         reg_we,          // IRQ block 0x200000-0x2000ff as 64 words, the merged word
	input  logic [5:0]   reg_addr,        // 0..31 IRQ words, 32..63 clip words
	input  logic [31:0]  reg_wdata,

	input  logic         parity,          // frame parity for auto-flicker
	input  logic         flip,            // flip screen: the frame rotated 180 degrees, latched at vblank

	// SDRAM: two arbiter clients (mlc_sprite_engine), 16-byte units
	output logic [1:0]   mem_req,
	output logic [51:0]  mem_addr,
	input  logic [1:0]   mem_valid,
	input  logic [127:0] mem_rdata,

	// video out
	output logic         ce_pix,
	output logic [7:0]   r, g, b,
	output logic         hblank, vblank, hs, vs,
	output logic         pix_valid,       // r, g, b hold the pixel at pix_x, pix_y (MAME line)
	output logic [8:0]   pix_x,
	output logic [8:0]   pix_y,

	// status
	output logic [8:0]   vpos,            // MAME's line number (the 0x200074 read)
	output logic         hpos_zero,       // the line's first pixel
	output logic         vbl_start,
	output logic         line_start,
	output logic         line_valid,
	output logic [8:0]   render_line,
	output logic         line_done,
	output logic         ovr_ev,
	output logic         list_busy
);

	// ---- timing ----
	logic [8:0] hpos;
	assign hpos_zero = (hpos == 9'd0);
	mlc_video_timing u_timing (
		.clk, .reset(video_reset), .ce_pix, .hpos, .vpos, .hblank, .vblank, .hs, .vs,
		.line_start, .render_line_v(line_valid), .render_line, .vbl_start
	);

	// ---- flip screen: one mechanism for every output. The engine draws line 255 - L (lines
	// 8-247 map onto each other) into the buffer as usual and scan-out reads it right to left,
	// which is the unflipped frame rotated 180 degrees. Latched at vblank so a frame is whole.
	logic       flip_r;
	wire  [8:0] scan_line = flip_r ? 9'd255 - render_line : render_line;
	always_ff @(posedge clk) begin
		if (reset)          flip_r <= 1'b0;
		else if (vbl_start) flip_r <= flip;
	end

	// ---- registers ----
	logic [79:0] clip_min_y, clip_max_y, clip_min_x, clip_max_x;
	logic [32:0] ras_y, ras_x;
	logic [29:0] ras_s;
	logic        alpha_on;

	// x limits clamped to the screen as v 259-260 does when drawing
	wire signed [31:0] rw = $signed(reg_wdata);
	wire [9:0] min_x_c = (rw < 0) ? 10'd0 : (rw > 320) ? 10'd320 : reg_wdata[9:0];
	wire [9:0] max_x_c = (rw < -1) ? 10'h3ff : (rw > 319) ? 10'd319 : reg_wdata[9:0];
	wire [9:0] y_c     = (rw < 0) ? 10'd0 : (rw > 1023) ? 10'd1023 : reg_wdata[9:0];

	always_ff @(posedge clk) begin
		if (reset) begin
			clip_min_y <= '0; clip_max_y <= '0; clip_min_x <= '0; clip_max_x <= '0;
			ras_y <= '0; ras_x <= '0; ras_s <= '0; alpha_on <= 1'b0;
		end else if (reg_we) begin
			if (reg_addr[5]) begin
				case (reg_addr[1:0])
					2'd0: clip_min_y[10*reg_addr[4:2] +: 10] <= y_c;
					2'd1: clip_max_y[10*reg_addr[4:2] +: 10] <= y_c;
					2'd2: clip_min_x[10*reg_addr[4:2] +: 10] <= min_x_c;
					2'd3: clip_max_x[10*reg_addr[4:2] +: 10] <= max_x_c;
				endcase
			end else begin
				if (reg_addr == 6'd1) alpha_on <= |reg_wdata[7:6];                 // v 47
				case (reg_addr)                                                     // v 383-385
					6'd6:  ras_y[0  +: 11] <= reg_wdata[10:0];
					6'd7:  ras_x[0  +: 11] <= reg_wdata[10:0];
					6'd8:  ras_s[0  +: 10] <= reg_wdata[9:0];
					6'd9:  ras_y[11 +: 11] <= reg_wdata[10:0];
					6'd10: ras_x[11 +: 11] <= reg_wdata[10:0];
					6'd11: ras_s[10 +: 10] <= reg_wdata[9:0];
					6'd12: ras_y[22 +: 11] <= reg_wdata[10:0];
					6'd13: ras_x[22 +: 11] <= reg_wdata[10:0];
					6'd14: ras_s[20 +: 10] <= reg_wdata[9:0];
					default: ;
				endcase
			end
		end
	end

	// ---- list ----
	logic [8:0]   cand_addr, ent_addr;
	logic [9:0]   cand_data, cand_count;
	logic [127:0] ent_data;
	mlc_sprite_list u_list (
		.clk, .reset,
		.cpu_we(list_we), .cpu_addr(list_addr), .cpu_wdata(list_wdata),
		.cpu_raddr(list_addr), .cpu_rdata(list_rdata),
		.snap_start(vbl_start), .parity, .busy(list_busy),
		.ent_addr, .ent_data, .cand_addr, .cand_data, .cand_count
	);

	// ---- VRAM ----
	logic [12:0]  vram_rd_addr;
	logic [127:0] vram_rd_data;
	mlc_vram u_vram (
		.clk, .cpu_we(vram_we), .cpu_addr(vram_addr), .cpu_wdata(vram_wdata), .cpu_be(vram_be),
		.cpu_rdata(vram_rdata), .rd_addr(vram_rd_addr), .rd_data(vram_rd_data)
	);

	// ---- engine and line buffer ----
	logic         lb_we, lb_shadow_only;
	logic [8:0]   lb_x;
	logic [10:0]  lb_pen;
	logic [1:0]   lb_flags;
	logic [319:0] lb_written;
	logic [10:0]  rpen;
	logic         rwritten;
	logic [1:0]   rflags;

	mlc_sprite_engine u_engine (
		.clk, .reset, .line_start, .line_valid, .scanline(scan_line), .parity, .alpha_on,
		.clip_min_y, .clip_max_y, .clip_min_x, .clip_max_x, .ras_y, .ras_x, .ras_s,
		.cand_addr, .cand_data, .cand_count, .ent_addr, .ent_data,
		.vram_rd_addr, .vram_rd_data,
		.mem_req, .mem_addr, .mem_valid, .mem_rdata,
		.lb_we, .lb_x, .lb_pen, .lb_flags, .lb_shadow_only, .lb_written,
		.line_done, .ovr_ev
	);

	mlc_line_buffer u_lb (
		.clk, .reset, .swap(line_start),
		.we(lb_we), .wx(lb_x), .wpen(lb_pen), .wflags(lb_flags), .wshadow_only(lb_shadow_only), .written(lb_written),
		.rx(flip_r ? 9'd319 - hpos : hpos), .rpen, .rwritten, .rflags
	);

	// ---- palette and scan-out: rx at ce_pix, the buffer a clock later, the palette one
	// after, the colour one after that ----
	// true dual port: A the CPU's (a read or a write), B the scan-out's
	logic [15:0] pal [0:2047];
	logic [15:0] pal_q;
	always_ff @(posedge clk) begin
		if (pal_we) pal[pal_addr] <= pal_wdata;
		pal_rdata <= pal[pal_addr];
	end
	always_ff @(posedge clk) pal_q <= pal[rwritten ? rpen : 11'd0];              // v 553

	logic [3:0] vis_d;
	logic [8:0] x_d [0:3];
	logic [8:0] y_d [0:3];
	logic [1:0] fl_d;
	wire vis = ce_pix && !hblank && !vblank;

	function automatic logic [7:0] shade(input logic [4:0] v, input logic [1:0] f);
		logic [7:0] v8;
		v8 = {v, v[4:2]};                                                       // pal5bit
		case (f)
			2'd1:    shade = {1'b0, v8[7:1]};                                   // v 576
			2'd2:    shade = {1'b1, v8[7:1]};                                   // v 578
			default: shade = v8;
		endcase
	endfunction

	always_ff @(posedge clk) begin
		vis_d <= {vis_d[2:0], vis};
		x_d[0] <= hpos; y_d[0] <= vpos;
		for (int i = 1; i < 4; i++) begin x_d[i] <= x_d[i-1]; y_d[i] <= y_d[i-1]; end
		fl_d <= rflags;
		pix_valid <= vis_d[1];
		pix_x     <= x_d[1];
		pix_y     <= y_d[1];
		r <= shade(pal_q[4:0],   fl_d);
		g <= shade(pal_q[9:5],   fl_d);
		b <= shade(pal_q[14:10], fl_d);
	end

endmodule
