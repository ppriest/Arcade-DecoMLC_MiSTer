// SPDX-License-Identifier: GPL-3.0-or-later
// Draws the hits of one line into the line buffer: deco_mlc_v.cpp draw_sprites' per-block setup
// (lines 399-450), its row loop (452-531) and drawgfxzoomline (42-141), as three overlapping
// stages (docs/phase1_video.md, "Setup", "Row loop"):
//
//   S  per hit: srcline by an eight-step restoring divider, xs, xbase and the row's first tile
//      count by radix-4 steppers, and the source step ceil(2^32 / xs) by a bit-serial divider
//      when xs is neither 1.0 nor the last hit's; hands a job to R.
//   R  per tile row: the table lookup, then the 16-byte unit holding the row of the tile and
//      its pair (scripts/mlc_layout.py), and for the 5bpp, 6bpp and acchi layouts the unit
//      holding planes 4-5 of that row and three neighbours': a unit equal to the stream's last
//      one is reused, any other is requested through the engine's slots, which keep two fetches
//      in flight; the row's descriptor goes to a queue for E, its data to the engine's row FIFO
//      in issue order (A, A's planes 4-5, then the 8bpp pair's B and B's).
//   E  per row from the queue: takes the row's new unit(s) from the row FIFO, then one pixel a
//      clock while the source position is in the row's tile: the pen, the clip and the written
//      test, the line-buffer write. One source accumulator and one screen x run across all the
//      tiles of a hit, from source 0 at floor(xbase): MAME instead restarts each tile with its
//      own step (docs/MAME_KLUDGES.md, "Zoom"). A tile left of the window is walked unfetched.
//
// No multiply or divide operator (docs/WORKFLOW.md section 14).
module mlc_sprite_draw
	import mlc_video_pkg::*;
(
	input  logic         clk,
	input  logic         reset,

	input  logic         line_start,       // abort everything in progress
	input  logic [1:0]   layout,           // gfx_layout (mlc_video_pkg L_*)
	input  logic         tiles128k,        // 5bpp/6bpp/acchi: gfx->elements() is 0x20000, else 0x10000
	input  logic         alpha_on,         // IRQ word 1 bits 7:6 (v 47, 101)
	input  logic [79:0]  clip_min_x,       // 8 x 10-bit signed, clamped to 0..320
	input  logic [79:0]  clip_max_x,       // 8 x 10-bit signed, clamped to -1..319

	// hit FIFO head
	input  logic         hit_empty,
	input  hit_t         hit,
	output logic         hit_pop,

	// VRAM word read (tile tables)
	output logic         vr_req,
	output logic [14:0]  vr_addr,          // 32-bit word
	input  logic         vr_ack,
	input  logic [127:0] vr_data,          // the block; lane vr_addr[1:0]

	// gfx2 table unit: a level request until taken, the answer on tab_ack
	output logic         tab_req,
	output logic [25:0]  tab_addr,
	input  logic         tab_take,
	input  logic         tab_ack,
	input  logic [127:0] tab_rdata,

	// gfx1 row unit: a level request until taken; the data arrives in the row FIFO, in order
	output logic         row_req,
	output logic [25:0]  row_addr,
	input  logic         row_take,
	input  logic         row_dv,           // the row FIFO's head is valid
	input  logic [127:0] row_data,
	output logic         row_pop,

	// line buffer
	output logic         lb_we,
	output logic [8:0]   lb_x,
	output logic [10:0]  lb_pen,
	output logic [1:0]   lb_flags,
	output logic         lb_shadow_only,
	input  logic [319:0] lb_written,

	output logic         busy
);

	// ------------------------------------------------------------------ stage S: setup
	typedef enum logic [2:0] {S_IDLE, S_DIV, S_XB, S_CNT, S_STEP, S_HAND} sstate_t;
	sstate_t sstate;
	hit_t hs;
	logic [3:0]  sstep;

	// divider: {bby, 8'b0} / yscale, quotient below 256 (the hit test, v 439-444)
	logic [17:0] rem;
	logic [16:0] dsh;
	logic [7:0]  q;
	wire         ge = (rem >= {1'b0, dsh});

	// xs = xscale * xextra, radix-4 over xextra (v 402)
	logic [19:0] xs;
	logic [9:0]  xsh;
	wire  [11:0] xscale_x3 = {2'b0, hs.xscale} + {1'b0, hs.xscale, 1'b0};
	logic [11:0] xsel;
	always_comb case (xsh[9:8])
		2'd0:    xsel = 12'd0;
		2'd1:    xsel = {2'b0, hs.xscale};
		2'd2:    xsel = {1'b0, hs.xscale, 1'b0};
		default: xsel = xscale_x3;
	endcase

	// xbase = (x << 16) + coef_x * xs, radix-4 over |coef_x| (v 412-418)
	wire signed [9:0] coef_x = hs.fx ? ($signed({2'b0, hs.xoffs}) - $signed({1'b0, hs.w, 4'b0}) + 10'sd1)
	                                 : -$signed({2'b0, hs.xoffs});
	wire  [9:0]  coef_x_mag = coef_x[9] ? -coef_x : coef_x;
	logic        negx;
	logic [7:0]  csh;
	logic [27:0] pacc;
	wire  [21:0] xs_x3 = {2'b0, xs} + {1'b0, xs, 1'b0};
	logic [21:0] psel;
	always_comb case (csh[7:6])
		2'd0:    psel = 22'd0;
		2'd1:    psel = {2'b0, xs};
		2'd2:    psel = {1'b0, xs, 1'b0};
		default: psel = xs_x3;
	endcase

	// step = ceil(2^32 / xs) = floor((2^32 + xs - 1) / xs), 33 restoring steps; the last hit's
	// is kept, and 1.0 needs none. Above 0x7fffffff (xs below 2) nothing is drawn.
	logic [32:0] st_n, st_q;
	logic [20:0] st_r;
	logic [5:0]  st_i;
	logic [19:0] st_last_xs;
	logic        st_last_v;
	logic [30:0] step;
	logic        step_ok;
	wire  [20:0] st_r2 = {st_r[19:0], st_n[32]};
	wire         st_ge = (st_r2 >= {1'b0, xs});

	// count0 = byrow * w, radix-4 over byrow (v 456-469)
	logic [3:0]  by, srcline, byrow;
	logic [3:0]  bsh;
	logic [8:0]  cacc;
	wire  [6:0]  w_x3 = {2'b0, hs.w} + {1'b0, hs.w, 1'b0};
	logic [6:0]  csel;
	always_comb case (bsh[3:2])
		2'd0:    csel = 7'd0;
		2'd1:    csel = {2'b0, hs.w};
		2'd2:    csel = {1'b0, hs.w, 1'b0};
		default: csel = w_x3;
	endcase

	// the job handed to R
	logic               job_v;
	logic signed [31:0] j_xbase;
	logic [23:0]        j_xinc;
	logic [19:0]        j_xs;
	logic [30:0]        j_step;
	logic [4:0]         j_w;
	logic               j_fx, j_pair, j_is_table, j_table_rom, j_tile_fmt;
	logic [3:0]         j_srcline, j_hibits;
	logic [8:0]         j_cnt0;
	logic [17:0]        j_sprite, j_sprite2;
	logic [6:0]         j_color;
	logic [1:0]         j_shadow;
	logic [2:0]         j_clipper;

	// ------------------------------------------------------------------ stage R: rows
	typedef enum logic [3:0] {
		R_IDLE, R_ROW, R_TABW, R_TAB2, R_TAB2W, R_UNIT, R_ISSA, R_ISSXA, R_ISSB, R_ISSXB, R_PUSH, R_WALK,
		R_DRAIN
	} rstate_t;
	rstate_t rstate;
	logic        tab_inflight;

	// R's copy of the job: S may hand the next one as soon as this one is taken
	logic [23:0]        r_xinc;
	logic [19:0]        r_xs;
	logic [30:0]        r_step;
	logic signed [15:0] r_first;
	logic [4:0]         r_w;
	logic               r_fx, r_pair, r_is_table, r_table_rom, r_tile_fmt;
	logic [3:0]         r_srcline, r_hibits;
	logic [17:0]        r_sprite, r_sprite2;
	logic [6:0]         r_color;
	logic [1:0]         r_shadow;
	logic [2:0]         r_clipper;

	logic [4:0]         bx;
	logic signed [31:0] realx;
	logic [8:0]         cnt;
	logic [18:0]        code, code2;            // tile index, then the gfx code after a table
	logic [3:0]         coloff;

	// held gfx2 table units, one per tile stream (v 478-484): eight entries each
	logic        holdA_v, holdB_v;
	logic [25:0] holdA_a, holdB_a;
	logic [127:0] holdA_d, holdB_d;

	// the last gfx1 unit used by each stream; a row in the same unit reuses E's copy
	logic        lastA_v, lastB_v, lastXA_v, lastXB_v;
	logic [25:0] lastA_a, lastB_a, lastXA_a, lastXB_a;
	logic        newA, newB, newXA, newXB;
	logic [25:0] unitA, unitB, unitXA, unitXB;
	wire         deep = (layout != L_4BPP);          // planes 4-5 in their own units

	wire [18:0] tile_idx  = {1'b0, r_sprite}  + {10'b0, cnt};
	wire [18:0] tile2_idx = {1'b0, r_sprite2} + {10'b0, cnt};
	wire [24:0] wsum      = {1'b0, r_xs, 4'b0} + {9'b0, realx[15:0]};
	wire [8:0]  width_c   = wsum[24:16];

	// MAME's span of the tile, [sx_c, ex_c), is within two pixels of the accumulator's (the step
	// rounded up by under 2^-16 a pixel, over at most 256 source columns): a tile two pixels clear
	// of the window is not fetched, walked if left of it, the hit ended if right of it
	wire signed [9:0]  row_cl = $signed(clip_min_x[10*r_clipper +: 10]);
	wire signed [9:0]  row_cr = $signed(clip_max_x[10*r_clipper +: 10]);
	wire signed [16:0] sx_c   = $signed({realx[31], realx[31:16]});
	wire signed [16:0] ex_c   = sx_c + $signed({8'b0, width_c});
	wire               off_r  = (sx_c - 17'sd2 > $signed({{7{row_cr[9]}}, row_cr}));
	wire               off_l  = (ex_c + 17'sd2 <= $signed({{7{row_cl[9]}}, row_cl}));

	wire [25:0] tabA_addr = GFX2_BASE + {6'b0, tile_idx[18:3], 4'b0};
	wire [25:0] tabB_addr = GFX2_BASE + {6'b0, tile2_idx[18:3], 4'b0};
	wire        tabA_hit  = holdA_v && (holdA_a == tabA_addr);
	wire        tabB_hit  = holdB_v && (holdB_a == tabB_addr);
	wire [15:0] tabA_held = holdA_d[16*tile_idx[2:0] +: 16];
	wire [15:0] tabB_held = holdB_d[16*tile2_idx[2:0] +: 16];
	wire [15:0] tabA_new  = tab_rdata[16*tile_idx[2:0] +: 16];
	wire [15:0] tabB_new  = tab_rdata[16*tile2_idx[2:0] +: 16];

	// a table entry applied to a code (v 491-502, 509-519)
	function automatic logic [18:0] apply_tab(input logic [15:0] t, input logic fmt, input logic [3:0] hb);
		if (fmt) apply_tab = {3'b0, hb, t[11:0]};
		else     apply_tab = {1'b0, hb, 14'b0} | {3'b0, t};
	endfunction

	// code % elements (v 96): 0x30000 at 4bpp, a power of two otherwise
	function automatic logic [17:0] wrap(input logic [17:0] c);
		if (!deep)          wrap = (c >= GFX1_TILES) ? c - GFX1_TILES : c;
		else if (tiles128k) wrap = {1'b0, c[16:0]};
		else                wrap = {2'b0, c[15:0]};
	endfunction
	wire [17:0] code_w   = wrap(code[17:0]);
	wire [17:0] code2_w  = wrap(code2[17:0]);
	wire [25:0] unitA_c  = GFX1_BASE + {1'b0, code_w[17:1],  r_srcline, 4'b0};    // mlc_layout.gfx1_unit
	wire [25:0] unitB_c  = GFX1_BASE + {1'b0, code2_w[17:1], r_srcline, 4'b0};
	wire [25:0] unitXA_c = GFX1_EXT + {3'b0, code_w[16:2],  r_srcline, 4'b0};    // mlc_layout.gfx1_ext_unit
	wire [25:0] unitXB_c = GFX1_EXT + {3'b0, code2_w[16:2], r_srcline, 4'b0};

	// the row descriptor queue, R to E
	typedef struct packed {
		logic               start;       // the hit's first tile: E restarts its accumulator
		logic               walk;        // left of the window: no data, nothing written
		logic [3:0]         t;           // the tile's column as drawn
		logic signed [15:0] first;       // floor(xbase)
		logic [30:0]        step;
		logic               fx;
		logic               pair;
		logic [11:0]        cb;
		logic [1:0]         shadow;
		logic               shadow_only;
		logic signed [9:0]  cl;
		logic signed [9:0]  cr;
		logic               newA;
		logic               halfA;
		logic               newB;
		logic               halfB;
		logic               newXA;
		logic [1:0]         slotXA;
		logic               newXB;
		logic [1:0]         slotXB;
	} row_t;
	row_t  rq_in, rq_out;
	logic  rq_push, rq_pop, rq_full, rq_empty;
	logic [2:0] rq_count;
	mlc_fifo #(.W($bits(row_t)), .AW(2)) u_rq (
		.clk, .reset, .flush(line_start), .push(rq_push), .din(rq_in), .full(rq_full),
		.pop(rq_pop), .dout(rq_out), .empty(rq_empty), .count(rq_count)
	);
	wire [7:0] colsum = {1'b0, r_color} + {4'b0, coloff};
	// granularity * ((color + offset) % colors()): 16 x 256, 32 x 128, 64 x 64; acchi 32 x 64
	wire [11:0] cb_c = (layout == L_5BPP)  ? {colsum[6:0], 5'b0} :
	                   (layout == L_6BPP)  ? {colsum[5:0], 6'b0} :
	                   (layout == L_ACCHI) ? {1'b0, colsum[5:0], 5'b0} : {colsum, 4'b0};

	// ------------------------------------------------------------------ stage E: pixels
	typedef enum logic [2:0] {E_IDLE, E_GETA, E_GETXA, E_GETB, E_GETXB, E_RUN} estate_t;
	estate_t estate;
	logic               e_active, v1;
	logic [31:0]        e_s;                 // the hit's source position, 16.16
	logic [30:0]        e_step;
	logic [3:0]         e_t;
	logic               e_walk;
	logic signed [15:0] e_d, x1;             // the hit's screen x
	logic               e_fx, e_pair, e_shadow_only, e_halfA, e_halfB, e_newB, e_newXA, e_newXB;
	logic [1:0]         e_slotXA, e_slotXB;
	logic [127:0]       curA, curB, curXA, curXB;
	logic [11:0]        e_cb;
	logic [1:0]         e_shadow;
	logic signed [9:0]  e_cl, e_cr;
	logic [3:0]         src1;
	wire  [31:0]        e_s_next = e_s + {1'b0, e_step};
	// a walked tile goes eight pixels a clock while eight fit in it
	wire  [34:0]        e_s_8    = {3'b0, e_s} + {1'b0, e_step, 3'b0};
	wire                walk8    = e_walk && (e_s_8[34:20] == {11'b0, e_t});
	// at a row's start: is the accumulator inside its tile (a tile may hold no pixel)
	wire  [31:0]        s_at     = rq_out.start ? 32'd0 : e_s;
	wire                in_new   = (s_at[31:20] == {8'b0, rq_out.t});
	wire                in_cur   = (e_s[31:20] == {8'b0, e_t});
	wire  [63:0]        e_data  = e_halfA ? curA[127:64] : curA[63:0];
	wire  [63:0]        e_data2 = e_halfB ? curB[127:64] : curB[63:0];
	wire  [31:0]        e_ext   = curXA[32*e_slotXA +: 32];
	wire  [31:0]        e_ext2  = curXB[32*e_slotXB +: 32];

	function automatic logic [3:0] pix4(input logic [63:0] g, input logic [3:0] x);
		logic [2:0] b;
		b = x[2:0];
		pix4[0] = x[3] ? g[b]      : g[8 + b];     // {a0,a1}[x]
		pix4[1] = x[3] ? g[16 + b] : g[24 + b];    // {a2,a3}[x]
		pix4[2] = x[3] ? g[32 + b] : g[40 + b];    // {b0,b1}[x]
		pix4[3] = x[3] ? g[48 + b] : g[56 + b];    // {b2,b3}[x]
	endfunction

	// planes 4-5 from the extra unit's word, bit 4 from its bytes 0-1, bit 5 from 2-3; 4bpp has
	// neither, 5bpp and acchi only bit 4
	function automatic logic [5:0] pix6(input logic [63:0] g, input logic [31:0] e, input logic [3:0] x);
		logic [2:0] b;
		b = x[2:0];
		pix6[3:0] = pix4(g, x);
		pix6[4]   = (layout != L_4BPP) && (x[3] ? e[b]      : e[8 + b]);
		pix6[5]   = (layout == L_6BPP) && (x[3] ? e[16 + b] : e[24 + b]);
	endfunction

	// an 8bpp pair: (c1 << 4) | c2, whatever the depth (v 110-112)
	wire [5:0]  pa    = pix6(e_data,  e_ext,  src1);
	wire [5:0]  pb    = pix6(e_data2, e_ext2, src1);
	wire [9:0]  pen2  = e_pair ? ({pa, 4'b0} | {4'b0, pb}) : {4'b0, pa};
	wire        inclip = (x1 >= $signed({{6{e_cl[9]}}, e_cl})) && (x1 <= $signed({{6{e_cr[9]}}, e_cr}));
	wire [11:0] pen12 = e_cb + {2'b0, pen2};

	assign busy = (sstate != S_IDLE) || (rstate != R_IDLE) || (estate != E_IDLE) || v1 || job_v || lb_we || !rq_empty;

	assign tab_req  = ((rstate == R_TABW && r_table_rom) || rstate == R_TAB2W) && !tab_inflight;
	assign tab_addr = (rstate == R_TAB2W) ? tabB_addr : tabA_addr;
	assign row_req  = (rstate == R_ISSA && newA) || (rstate == R_ISSB) || (rstate == R_ISSXA) || (rstate == R_ISSXB);
	assign row_addr = (rstate == R_ISSB) ? unitB : (rstate == R_ISSXA) ? unitXA : (rstate == R_ISSXB) ? unitXB : unitA;

	always_ff @(posedge clk) begin
		if (reset) begin
			sstate <= S_IDLE; rstate <= R_IDLE; estate <= E_IDLE;
			hit_pop <= 1'b0; job_v <= 1'b0;
			vr_req <= 1'b0; tab_inflight <= 1'b0;
			holdA_v <= 1'b0; holdB_v <= 1'b0; lastA_v <= 1'b0; lastB_v <= 1'b0;
			lastXA_v <= 1'b0; lastXB_v <= 1'b0;
			e_active <= 1'b0; v1 <= 1'b0;
			lb_we <= 1'b0; rq_push <= 1'b0; rq_pop <= 1'b0; row_pop <= 1'b0;
			sstep <= '0;
			st_last_v <= 1'b0; step_ok <= 1'b0;
		end else begin
			hit_pop <= 1'b0;
			lb_we   <= 1'b0;
			rq_push <= 1'b0;
			rq_pop  <= 1'b0;
			row_pop <= 1'b0;
			if (tab_take) tab_inflight <= 1'b1;
			if (tab_ack)  tab_inflight <= 1'b0;

			// ---------------- E2: the pixel evaluated last clock; none lands after the swap
			if (v1 && inclip && (pen2 != 10'd0) && !lb_written[x1[8:0]] && !line_start) begin
				lb_we          <= 1'b1;
				lb_x           <= x1[8:0];
				lb_pen         <= pen12[10:0];
				lb_flags       <= e_shadow;
				lb_shadow_only <= e_shadow_only;
			end
			// ---------------- E1
			v1 <= 1'b0;
			if (e_active) begin
				v1   <= !e_walk;
				x1   <= e_d;
				src1 <= e_fx ? ~e_s[19:16] : e_s[19:16];
				if (walk8) begin
					e_d <= e_d + 16'sd8;
					e_s <= e_s_8[31:0];
				end else begin
					e_d <= e_d + 16'sd1;
					e_s <= e_s_next;
					if (e_s_next[31:20] != {8'b0, e_t}) e_active <= 1'b0;
				end
			end

			if (line_start) begin
				// abort: S drops its hit, R drains a table fetch in flight, E stops; the
				// engine discards row fetches in flight and flushes the row FIFO
				sstate   <= S_IDLE;
				job_v    <= 1'b0;
				vr_req   <= 1'b0;
				estate   <= E_IDLE;
				e_active <= 1'b0;
				v1       <= 1'b0;
				lastA_v  <= 1'b0;
				lastB_v  <= 1'b0;
				lastXA_v <= 1'b0;
				lastXB_v <= 1'b0;
				rstate   <= (tab_take || (tab_inflight && !tab_ack)) ? R_DRAIN : R_IDLE;
			end else begin
				// ---------------- S
				case (sstate)
					S_IDLE: begin
						if (!hit_empty && !job_v) begin
							hs      <= hit;
							hit_pop <= 1'b1;
							rem   <= {hit.bby, 8'b0};
							dsh   <= {hit.yscale, 7'b0};
							xs    <= '0;
							xsh   <= hit.xextra;
							sstep <= '0;
							sstate <= S_DIV;
						end
					end

					S_DIV: begin
						q   <= {q[6:0], ge};
						rem <= ge ? rem - {1'b0, dsh} : rem;
						dsh <= {1'b0, dsh[16:1]};
						if (sstep < 4'd5) begin
							xs  <= {xs[17:0], 2'b0} + {8'b0, xsel};
							xsh <= {xsh[7:0], 2'b0};
						end
						if (sstep == 4'd7) begin
							sstep  <= '0;
							negx   <= coef_x[9];
							csh    <= coef_x_mag[7:0];
							pacc   <= '0;
							sstate <= S_XB;
						end else sstep <= sstep + 4'd1;
					end

					S_XB: begin
						pacc <= {pacc[25:0], 2'b0} + {6'b0, psel};
						csh  <= {csh[5:0], 2'b0};
						if (sstep == 4'd3) begin
							sstep   <= '0;
							by      <= q[7:4];
							srcline <= hs.fy ? ~q[3:0] : q[3:0];
							byrow   <= hs.fy ? (hs.h[3:0] - 4'd1 - q[7:4]) : q[7:4];
							cacc    <= '0;
							sstate  <= S_CNT;
						end else sstep <= sstep + 4'd1;
					end

					S_CNT: begin
						if (sstep == 4'd0) begin
							bsh   <= byrow;
							sstep <= 4'd1;
						end else begin
							cacc <= {cacc[6:0], 2'b0} + {2'b0, csel};
							bsh  <= {bsh[1:0], 2'b0};
							if (sstep == 4'd2) begin
								sstep <= '0;
								if (xs == 20'h10000) begin
									step <= 31'h10000; step_ok <= 1'b1; st_last_v <= 1'b1; st_last_xs <= xs; sstate <= S_HAND;
								end else if (st_last_v && xs == st_last_xs) begin
									sstate <= S_HAND;
								end else begin
									st_n   <= {1'b1, 32'b0} + {13'b0, xs} - 33'd1;
									st_r   <= '0;
									st_q   <= '0;
									st_i   <= '0;
									sstate <= S_STEP;
								end
							end else sstep <= sstep + 4'd1;
						end
					end

					S_STEP: begin
						st_r <= st_ge ? st_r2 - {1'b0, xs} : st_r2;
						st_q <= {st_q[31:0], st_ge};
						st_n <= {st_n[31:0], 1'b0};
						st_i <= st_i + 6'd1;
						if (st_i == 6'd32) begin
							st_last_v  <= 1'b1;
							st_last_xs <= xs;
							step       <= {st_q[29:0], st_ge};
							step_ok    <= (xs != 20'd0) && (st_q[31:30] == 2'b00);
							sstate     <= S_HAND;
						end
					end

					S_HAND: begin
						if (!step_ok) begin
							sstate <= S_IDLE;                        // v 46: nothing drawn
						end else if (!job_v) begin
							j_xbase     <= $signed({{4{hs.x[11]}}, hs.x, 16'b0}) + (negx ? -$signed({4'b0, pacc}) : $signed({4'b0, pacc}));
							j_xinc      <= {xs, 4'b0};
							j_xs        <= xs;
							j_step      <= step;
							j_w         <= hs.w;
							j_fx        <= hs.fx;
							j_srcline   <= srcline;
							j_cnt0      <= cacc;
							j_sprite    <= hs.sprite;
							j_sprite2   <= hs.sprite2;
							j_is_table  <= hs.is_table;
							j_table_rom <= hs.table_rom;
							j_tile_fmt  <= hs.tile_fmt;
							j_hibits    <= hs.hibits;
							j_color     <= hs.color;
							j_shadow    <= hs.shadow;
							j_clipper   <= hs.clipper;
							j_pair      <= hs.pair;
							job_v       <= 1'b1;
							sstate      <= S_IDLE;
						end
					end

					default: sstate <= S_IDLE;
				endcase

				// ---------------- R
				case (rstate)
					R_IDLE: begin
						if (job_v) begin
							job_v       <= 1'b0;
							bx          <= '0;
							realx       <= j_xbase;
							cnt         <= j_fx ? j_cnt0 + {4'b0, j_w} - 9'd1 : j_cnt0;
							r_xinc      <= j_xinc;
							r_xs        <= j_xs;
							r_step      <= j_step;
							r_first     <= j_xbase[31:16];
							r_w         <= j_w;
							r_fx        <= j_fx;
							r_srcline   <= j_srcline;
							r_sprite    <= j_sprite;
							r_sprite2   <= j_sprite2;
							r_is_table  <= j_is_table;
							r_table_rom <= j_table_rom;
							r_tile_fmt  <= j_tile_fmt;
							r_hibits    <= j_hibits;
							r_color     <= j_color;
							r_shadow    <= j_shadow;
							r_clipper   <= j_clipper;
							r_pair      <= j_pair;
							rstate      <= R_ROW;
						end
					end

					R_DRAIN: begin
						if (tab_ack) rstate <= R_IDLE;
					end

					R_ROW: begin
						if (bx == r_w || off_r) begin
							rstate <= R_IDLE;
						end else if (off_l) begin
							rstate <= R_WALK;
						end else begin
							coloff <= 4'd0;
							if (!r_is_table) begin
								code   <= tile_idx;
								code2  <= tile2_idx;
								rstate <= R_UNIT;
							end else if (r_table_rom) begin
								if (tabA_hit) begin
									code   <= apply_tab(tabA_held, r_tile_fmt, r_hibits);
									coloff <= r_tile_fmt ? tabA_held[15:12] : 4'd0;
									rstate <= r_pair ? R_TAB2 : R_UNIT;
								end else begin
									rstate <= R_TABW;               // tab_req rises there
								end
							end else begin
								vr_req  <= 1'b1;
								vr_addr <= tile_idx[14:0];
								rstate  <= R_TABW;
							end
						end
					end

					R_TABW: begin
						if (r_table_rom) begin
							if (tab_ack) begin
								holdA_v <= 1'b1; holdA_a <= tabA_addr; holdA_d <= tab_rdata;
								code    <= apply_tab(tabA_new, r_tile_fmt, r_hibits);
								coloff  <= r_tile_fmt ? tabA_new[15:12] : 4'd0;
								rstate  <= r_pair ? R_TAB2 : R_UNIT;
							end
						end else if (vr_ack) begin
							vr_req <= 1'b0;
							code   <= apply_tab(vr_data[32*tile_idx[1:0] +: 16], r_tile_fmt, r_hibits);
							coloff <= r_tile_fmt ? vr_data[32*tile_idx[1:0] + 12 +: 4] : 4'd0;
							code2  <= '0;                                    // v 520
							rstate <= R_UNIT;
						end
					end

					R_TAB2: begin                                            // v 481-485
						if (tabB_hit) begin
							code2  <= apply_tab(tabB_held, r_tile_fmt, r_hibits);
							rstate <= R_UNIT;
						end else begin
							rstate <= R_TAB2W;
						end
					end

					R_TAB2W: begin
						if (tab_ack) begin
							holdB_v <= 1'b1; holdB_a <= tabB_addr; holdB_d <= tab_rdata;
							code2   <= apply_tab(tabB_new, r_tile_fmt, r_hibits);
							rstate  <= R_UNIT;
						end
					end

					R_UNIT: begin
						unitA  <= unitA_c;
						unitB  <= unitB_c;
						unitXA <= unitXA_c;
						unitXB <= unitXB_c;
						newA   <= !(lastA_v && lastA_a == unitA_c);
						newB   <= r_pair && !(lastB_v && lastB_a == unitB_c);
						newXA  <= deep && !(lastXA_v && lastXA_a == unitXA_c);
						newXB  <= deep && r_pair && !(lastXB_v && lastXB_a == unitXB_c);
						rstate <= R_ISSA;
					end

					// the unit order is the row FIFO's, and E's: A, XA, B, XB
					R_ISSA: begin
						if (!newA) rstate <= newXA ? R_ISSXA : newB ? R_ISSB : newXB ? R_ISSXB : R_PUSH;
						else if (row_take) begin
							lastA_v <= 1'b1; lastA_a <= unitA;
							rstate  <= newXA ? R_ISSXA : newB ? R_ISSB : newXB ? R_ISSXB : R_PUSH;
						end
					end

					R_ISSXA: begin
						if (row_take) begin
							lastXA_v <= 1'b1; lastXA_a <= unitXA;
							rstate   <= newB ? R_ISSB : newXB ? R_ISSXB : R_PUSH;
						end
					end

					R_ISSB: begin
						if (row_take) begin
							lastB_v <= 1'b1; lastB_a <= unitB;
							rstate  <= newXB ? R_ISSXB : R_PUSH;
						end
					end

					R_ISSXB: begin
						if (row_take) begin
							lastXB_v <= 1'b1; lastXB_a <= unitXB;
							rstate   <= R_PUSH;
						end
					end

					R_PUSH: begin
						if (!rq_full) begin
							rq_in.start       <= (bx == 5'd0);
							rq_in.walk        <= 1'b0;
							rq_in.t           <= bx[3:0];
							rq_in.first       <= r_first;
							rq_in.step        <= r_step;
							rq_in.fx          <= r_fx;
							rq_in.pair        <= r_pair;
							rq_in.cb          <= cb_c;
							rq_in.shadow      <= r_shadow;
							rq_in.shadow_only <= (r_shadow != 2'd0) && alpha_on;
							rq_in.cl          <= row_cl;
							rq_in.cr          <= row_cr;
							rq_in.newA        <= newA;
							rq_in.halfA       <= code_w[0];
							rq_in.newB        <= newB;
							rq_in.halfB       <= code2_w[0];
							rq_in.newXA       <= newXA;
							rq_in.slotXA      <= code_w[1:0];
							rq_in.newXB       <= newXB;
							rq_in.slotXB      <= code2_w[1:0];
							rq_push           <= 1'b1;
							bx                <= bx + 5'd1;
							realx             <= realx + $signed({8'b0, r_xinc});
							cnt               <= r_fx ? cnt - 9'd1 : cnt + 9'd1;
							rstate            <= R_ROW;
						end
					end

					R_WALK: begin
						if (!rq_full) begin
							rq_in             <= '0;
							rq_in.start       <= (bx == 5'd0);
							rq_in.walk        <= 1'b1;
							rq_in.t           <= bx[3:0];
							rq_in.first       <= r_first;
							rq_in.step        <= r_step;
							rq_push           <= 1'b1;
							bx                <= bx + 5'd1;
							realx             <= realx + $signed({8'b0, r_xinc});
							cnt               <= r_fx ? cnt - 9'd1 : cnt + 9'd1;
							rstate            <= R_ROW;
						end
					end

					default: rstate <= R_IDLE;
				endcase

				// ---------------- E
				case (estate)
					E_IDLE: begin
						if (!rq_empty && !rq_pop) begin
							e_step        <= rq_out.step;
							e_t           <= rq_out.t;
							e_walk        <= rq_out.walk;
							if (rq_out.start) begin
								e_s <= '0;
								e_d <= rq_out.first;
							end
							e_fx          <= rq_out.fx;
							e_pair        <= rq_out.pair;
							e_cb          <= rq_out.cb;
							e_shadow      <= rq_out.shadow;
							e_shadow_only <= rq_out.shadow_only;
							e_cl          <= rq_out.cl;
							e_cr          <= rq_out.cr;
							e_halfA       <= rq_out.halfA;
							e_halfB       <= rq_out.halfB;
							e_newB        <= rq_out.newB;
							e_newXA       <= rq_out.newXA;
							e_newXB       <= rq_out.newXB;
							e_slotXA      <= rq_out.slotXA;
							e_slotXB      <= rq_out.slotXB;
							rq_pop        <= 1'b1;
							estate        <= rq_out.newA ? E_GETA : rq_out.newXA ? E_GETXA :
							                 rq_out.newB ? E_GETB : rq_out.newXB ? E_GETXB : E_RUN;
							if (!rq_out.newA && !rq_out.newXA && !rq_out.newB && !rq_out.newXB)
								e_active <= in_new;
						end
					end

					E_GETA: begin
						if (row_dv && !row_pop) begin
							curA    <= row_data;
							row_pop <= 1'b1;
							if (e_newXA) estate <= E_GETXA;
							else if (e_newB) estate <= E_GETB;
							else if (e_newXB) estate <= E_GETXB;
							else begin
								e_active <= in_cur;
								estate <= E_RUN;
							end
						end
					end

					E_GETXA: begin
						if (row_dv && !row_pop) begin
							curXA   <= row_data;
							row_pop <= 1'b1;
							if (e_newB) estate <= E_GETB;
							else if (e_newXB) estate <= E_GETXB;
							else begin
								e_active <= in_cur;
								estate <= E_RUN;
							end
						end
					end

					E_GETB: begin
						if (row_dv && !row_pop) begin
							curB    <= row_data;
							row_pop <= 1'b1;
							if (e_newXB) estate <= E_GETXB;
							else begin
								e_active <= in_cur;
								estate <= E_RUN;
							end
						end
					end

					E_GETXB: begin
						if (row_dv && !row_pop) begin
							curXB   <= row_data;
							row_pop <= 1'b1;
							e_active <= in_cur;
							estate  <= E_RUN;
						end
					end

					E_RUN: begin
						if (!e_active) estate <= E_IDLE;
					end

					default: estate <= E_IDLE;
				endcase
			end
		end
	end

endmodule
