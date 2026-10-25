// SPDX-License-Identifier: GPL-3.0-or-later
// Draws the hits of one line into the line buffer: deco_mlc_v.cpp draw_sprites' per-block setup
// (lines 399-450), its row loop (452-531) and drawgfxzoomline (42-141), as three overlapping
// stages (docs/phase1_video.md, "Setup", "Row loop"):
//
//   S  per hit: srcline by an eight-step restoring divider, xs, xbase and the row's first tile
//      count by radix-4 steppers; hands a job to R.
//   R  per tile row: the table lookup, then the 16-byte unit holding the row of the tile and
//      its pair (scripts/mlc_layout.py): a unit equal to the stream's last one is reused, any
//      other is requested through the engine's slots, which keep two fetches in flight; the
//      row's descriptor goes to a queue for E, its data to the engine's row FIFO in issue order.
//   E  per row from the queue: takes the row's new unit(s) from the row FIFO, then one pixel a
//      clock: source column by accumulating dx, screen x by stepping, the pen, the clip and the
//      written test, the line-buffer write.
//
// No multiply or divide operator (docs/WORKFLOW.md section 14).
module mlc_sprite_draw
	import mlc_video_pkg::*;
(
	input  logic         clk,
	input  logic         reset,

	input  logic         line_start,       // abort everything in progress
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
	typedef enum logic [2:0] {S_IDLE, S_DIV, S_XB, S_CNT, S_HAND} sstate_t;
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
		R_IDLE, R_ROW, R_TABW, R_TAB2, R_TAB2W, R_UNIT, R_ISSA, R_ISSB, R_PUSH, R_DRAIN
	} rstate_t;
	rstate_t rstate;
	logic        tab_inflight;

	// R's copy of the job: S may hand the next one as soon as this one is taken
	logic [23:0]        r_xinc;
	logic [19:0]        r_xs;
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
	logic [8:0]         width;
	logic [20:0]        dx;
	logic signed [15:0] sx;

	// held gfx2 table units, one per tile stream (v 478-484): eight entries each
	logic        holdA_v, holdB_v;
	logic [25:0] holdA_a, holdB_a;
	logic [127:0] holdA_d, holdB_d;

	// the last gfx1 unit used by each stream; a row in the same unit reuses E's copy
	logic        lastA_v, lastB_v;
	logic [25:0] lastA_a, lastB_a;
	logic        newA, newB;
	logic [25:0] unitA, unitB;

	wire [18:0] tile_idx  = {1'b0, r_sprite}  + {10'b0, cnt};
	wire [18:0] tile2_idx = {1'b0, r_sprite2} + {10'b0, cnt};
	wire [24:0] wsum      = {1'b0, r_xs, 4'b0} + {9'b0, realx[15:0]};
	wire [8:0]  width_c   = wsum[24:16];
	logic [20:0] dx_c;
	mlc_recip_table u_recip (.width(width_c), .dx(dx_c));

	// a row entirely outside the window is neither fetched nor drawn (v 78-93)
	wire signed [9:0]  row_cl = $signed(clip_min_x[10*r_clipper +: 10]);
	wire signed [9:0]  row_cr = $signed(clip_max_x[10*r_clipper +: 10]);
	wire signed [16:0] sx_c   = $signed({realx[31], realx[31:16]});
	wire signed [16:0] ex_c   = sx_c + $signed({8'b0, width_c});
	wire               row_off = (sx_c > $signed({{7{row_cr[9]}}, row_cr})) || (ex_c <= $signed({{7{row_cl[9]}}, row_cl}));

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

	wire [17:0] code_w  = (code[17:0]  >= GFX1_TILES) ? code[17:0]  - GFX1_TILES : code[17:0];   // v 96
	wire [17:0] code2_w = (code2[17:0] >= GFX1_TILES) ? code2[17:0] - GFX1_TILES : code2[17:0];
	wire [25:0] unitA_c = GFX1_BASE + {1'b0, code_w[17:1],  r_srcline, 4'b0};    // mlc_layout.gfx1_unit
	wire [25:0] unitB_c = GFX1_BASE + {1'b0, code2_w[17:1], r_srcline, 4'b0};

	// the row descriptor queue, R to E
	typedef struct packed {
		logic signed [15:0] sx;
		logic [8:0]         width;
		logic [20:0]        dx;
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
	} row_t;
	row_t  rq_in, rq_out;
	logic  rq_push, rq_pop, rq_full, rq_empty;
	logic [2:0] rq_count;
	mlc_fifo #(.W($bits(row_t)), .AW(2)) u_rq (
		.clk, .reset, .flush(line_start), .push(rq_push), .din(rq_in), .full(rq_full),
		.pop(rq_pop), .dout(rq_out), .empty(rq_empty), .count(rq_count)
	);
	wire [7:0] colsum = {1'b0, r_color} + {4'b0, coloff};

	// ------------------------------------------------------------------ stage E: pixels
	typedef enum logic [2:0] {E_IDLE, E_GETA, E_GETB, E_RUN} estate_t;
	estate_t estate;
	logic               e_active, v1;
	logic [8:0]         e_j, e_width;
	logic [19:0]        e_acc;
	logic signed [15:0] e_xr, x1;
	logic               e_fx, e_pair, e_shadow_only, e_halfA, e_halfB, e_newB;
	logic [127:0]       curA, curB;
	logic [11:0]        e_cb;
	logic [1:0]         e_shadow;
	logic signed [9:0]  e_cl, e_cr;
	logic [3:0]         src1;
	logic [20:0]        dx_e;
	wire  [63:0]        e_data  = e_halfA ? curA[127:64] : curA[63:0];
	wire  [63:0]        e_data2 = e_halfB ? curB[127:64] : curB[63:0];

	function automatic logic [3:0] pix4(input logic [63:0] g, input logic [3:0] x);
		logic [2:0] b;
		b = x[2:0];
		pix4[0] = x[3] ? g[b]      : g[8 + b];     // {a0,a1}[x]
		pix4[1] = x[3] ? g[16 + b] : g[24 + b];    // {a2,a3}[x]
		pix4[2] = x[3] ? g[32 + b] : g[40 + b];    // {b0,b1}[x]
		pix4[3] = x[3] ? g[48 + b] : g[56 + b];    // {b2,b3}[x]
	endfunction

	wire [7:0]  pen2  = e_pair ? {pix4(e_data, src1), pix4(e_data2, src1)} : {4'b0, pix4(e_data, src1)};
	wire        inclip = (x1 >= $signed({{6{e_cl[9]}}, e_cl})) && (x1 <= $signed({{6{e_cr[9]}}, e_cr}));
	wire [11:0] pen12 = e_cb + {4'b0, pen2};

	assign busy = (sstate != S_IDLE) || (rstate != R_IDLE) || (estate != E_IDLE) || v1 || job_v || lb_we || !rq_empty;

	assign tab_req  = ((rstate == R_TABW && r_table_rom) || rstate == R_TAB2W) && !tab_inflight;
	assign tab_addr = (rstate == R_TAB2W) ? tabB_addr : tabA_addr;
	assign row_req  = (rstate == R_ISSA && newA) || (rstate == R_ISSB);
	assign row_addr = (rstate == R_ISSB) ? unitB : unitA;

	always_ff @(posedge clk) begin
		if (reset) begin
			sstate <= S_IDLE; rstate <= R_IDLE; estate <= E_IDLE;
			hit_pop <= 1'b0; job_v <= 1'b0;
			vr_req <= 1'b0; tab_inflight <= 1'b0;
			holdA_v <= 1'b0; holdB_v <= 1'b0; lastA_v <= 1'b0; lastB_v <= 1'b0;
			e_active <= 1'b0; v1 <= 1'b0;
			lb_we <= 1'b0; rq_push <= 1'b0; rq_pop <= 1'b0; row_pop <= 1'b0;
			sstep <= '0;
		end else begin
			hit_pop <= 1'b0;
			lb_we   <= 1'b0;
			rq_push <= 1'b0;
			rq_pop  <= 1'b0;
			row_pop <= 1'b0;
			if (tab_take) tab_inflight <= 1'b1;
			if (tab_ack)  tab_inflight <= 1'b0;

			// ---------------- E2: the pixel evaluated last clock; none lands after the swap
			if (v1 && inclip && (pen2 != 8'd0) && !lb_written[x1[8:0]] && !line_start) begin
				lb_we          <= 1'b1;
				lb_x           <= x1[8:0];
				lb_pen         <= pen12[10:0];
				lb_flags       <= e_shadow;
				lb_shadow_only <= e_shadow_only;
			end
			// ---------------- E1
			v1 <= 1'b0;
			if (e_active) begin
				v1    <= 1'b1;
				x1    <= e_xr;
				src1  <= e_acc[19:16];
				e_xr  <= e_fx ? e_xr - 16'sd1 : e_xr + 16'sd1;
				e_acc <= e_acc + dx_e;
				e_j   <= e_j + 9'd1;
				if (e_j == e_width - 9'd1) e_active <= 1'b0;
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
							if (sstep == 4'd2) begin sstep <= '0; sstate <= S_HAND; end
							else sstep <= sstep + 4'd1;
						end
					end

					S_HAND: begin
						if (!job_v) begin
							j_xbase     <= $signed({{4{hs.x[11]}}, hs.x, 16'b0}) + (negx ? -$signed({4'b0, pacc}) : $signed({4'b0, pacc}));
							j_xinc      <= {xs, 4'b0};
							j_xs        <= xs;
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
						if (bx == r_w) begin
							rstate <= R_IDLE;
						end else if (r_xs == 20'd0 || width_c == 9'd0 || row_off) begin
							// v 46, 59, 93: nothing drawn, nothing fetched
							bx    <= bx + 5'd1;
							realx <= realx + $signed({8'b0, r_xinc});
							cnt   <= r_fx ? cnt - 9'd1 : cnt + 9'd1;
						end else begin
							width  <= width_c;
							dx     <= dx_c;
							sx     <= realx[31:16];
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
						newA   <= !(lastA_v && lastA_a == unitA_c);
						newB   <= r_pair && !(lastB_v && lastB_a == unitB_c);
						rstate <= R_ISSA;
					end

					R_ISSA: begin
						if (!newA) rstate <= newB ? R_ISSB : R_PUSH;
						else if (row_take) begin
							lastA_v <= 1'b1; lastA_a <= unitA;
							rstate  <= newB ? R_ISSB : R_PUSH;
						end
					end

					R_ISSB: begin
						if (row_take) begin
							lastB_v <= 1'b1; lastB_a <= unitB;
							rstate  <= R_PUSH;
						end
					end

					R_PUSH: begin
						if (!rq_full) begin
							rq_in.sx          <= sx;
							rq_in.width       <= width;
							rq_in.dx          <= dx;
							rq_in.fx          <= r_fx;
							rq_in.pair        <= r_pair;
							rq_in.cb          <= {colsum, 4'b0};
							rq_in.shadow      <= r_shadow;
							rq_in.shadow_only <= (r_shadow != 2'd0) && alpha_on;
							rq_in.cl          <= row_cl;
							rq_in.cr          <= row_cr;
							rq_in.newA        <= newA;
							rq_in.halfA       <= code_w[0];
							rq_in.newB        <= newB;
							rq_in.halfB       <= code2_w[0];
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
							e_width       <= rq_out.width;
							dx_e          <= rq_out.dx;
							e_fx          <= rq_out.fx;
							e_xr          <= rq_out.fx ? rq_out.sx + $signed({7'b0, rq_out.width}) - 16'sd1 : rq_out.sx;
							e_pair        <= rq_out.pair;
							e_cb          <= rq_out.cb;
							e_shadow      <= rq_out.shadow;
							e_shadow_only <= rq_out.shadow_only;
							e_cl          <= rq_out.cl;
							e_cr          <= rq_out.cr;
							e_halfA       <= rq_out.halfA;
							e_halfB       <= rq_out.halfB;
							e_newB        <= rq_out.newB;
							rq_pop        <= 1'b1;
							estate        <= rq_out.newA ? E_GETA : (rq_out.newB ? E_GETB : E_RUN);
							if (!rq_out.newA && !rq_out.newB) begin
								e_j <= '0; e_acc <= '0; e_active <= 1'b1;
							end
						end
					end

					E_GETA: begin
						if (row_dv && !row_pop) begin
							curA    <= row_data;
							row_pop <= 1'b1;
							if (e_newB) estate <= E_GETB;
							else begin
								e_j <= '0; e_acc <= '0; e_active <= 1'b1;
								estate <= E_RUN;
							end
						end
					end

					E_GETB: begin
						if (row_dv && !row_pop) begin
							curB    <= row_data;
							row_pop <= 1'b1;
							e_j <= '0; e_acc <= '0; e_active <= 1'b1;
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
