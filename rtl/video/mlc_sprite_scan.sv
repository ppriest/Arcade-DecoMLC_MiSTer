// SPDX-License-Identifier: GPL-3.0-or-later
// Per-line scanner: walks the frame's candidates in list order, reads each one's entry and
// index block, applies the clip window, flicker, raster offsets and the y test of
// deco_mlc_v.cpp draw_sprites (lines 213-444) and pushes every entry covering the line into the
// hit FIFO (docs/phase1_video.md, "Scanner").
//
// The y test without a multiplier: both products over yscale, |coef_y| * yscale (v 404-410) and
// h * yscale (the bound of v 439-444), are stepped radix-4 over yscale's ten bits in five
// clocks. line_start restarts the walk; a gfx2 read in flight is drained first.
module mlc_sprite_scan
	import mlc_video_pkg::*;
(
	input  logic         clk,
	input  logic         reset,

	input  logic         line_start,
	input  logic         line_valid,       // a visible line follows line_start
	input  logic [8:0]   scanline,         // MAME's number, 8..247
	input  logic [1:0]   layout,           // gfx_layout: 0 4bpp, 1 5bpp, 2 6bpp, 3 acchi (mlc_video_pkg)
	input  logic         parity,           // frame parity for block flicker (v 278, 310)

	// candidate and entry ports (mlc_sprite_list), one-clock reads
	output logic [8:0]   cand_addr,
	input  logic [9:0]   cand_data,
	input  logic [9:0]   cand_count,
	output logic [8:0]   ent_addr,
	input  logic [127:0] ent_data,

	// clip windows (y) and raster sets, registers
	input  logic [79:0]  clip_min_y,       // 8 x 10
	input  logic [79:0]  clip_max_y,
	input  logic [32:0]  ras_y,            // 3 x 11, signed, sets 1-3
	input  logic [32:0]  ras_x,
	input  logic [29:0]  ras_s,            // 3 x 10

	// VRAM block read
	output logic         vr_req,
	output logic [12:0]  vr_addr,          // 16-byte block
	input  logic         vr_ack,           // vr_data valid, request taken
	input  logic [127:0] vr_data,

	// gfx2 read: the 16-byte unit holding the index block (8 B, in the half indx[0] selects)
	output logic         mem_req,          // level, held until mem_take
	output logic [25:0]  mem_addr,
	input  logic         mem_take,         // the request was issued; mem_ack follows
	input  logic         mem_ack,
	input  logic [127:0] mem_rdata,

	// hits
	output logic         hit_push,
	output hit_t         hit,
	input  logic         hit_full,

	output logic         done              // every candidate of the line processed
);

	typedef enum logic [3:0] {
		S_IDLE, S_CAND, S_CANDW, S_ENTW, S_ENT2W, S_TEST, S_BLKW, S_MUL, S_DECIDE, S_BLK2W, S_PUSH, S_NEXT, S_DRAIN
	} state_t;
	state_t state;

	logic [8:0]  ci;                       // candidate index
	logic [8:0]  line_r;                   // scanline, latched at line_start
	logic        pair;
	logic [8:0]  idx;                      // main entry index
	logic        mem_inflight;             // issued, not yet answered
	logic        restart;                  // line_start seen while draining
	logic [2:0]  mstep;

	// the entry (v 213-240)
	logic [14:0] indx;
	logic        fx0, fy0, flick, ras_mode;
	logic [1:0]  ras_sel;
	logic [2:0]  clipper;
	logic [6:0]  color;
	logic [1:0]  shadow;
	logic signed [10:0] y0, x0;
	logic [9:0]  yscale, xscale;
	logic [14:0] indx2;                    // the pair's first entry's index

	// the block (v 274-335)
	logic [4:0]  h, w;
	logic [7:0]  yoffs, xoffs;
	logic        fy1, fx1, tile_fmt, is_table, table_rom, blk_flick;
	logic [17:0] sprite, sprite2;
	logic [3:0]  hibits;

	// after raster offsets
	logic signed [11:0] y_r, x_r;
	logic [9:0]  xextra;

	wire signed [9:0] coef_y = (fy0 ^ fy1) ? ($signed({2'b0, yoffs}) - $signed({1'b0, h, 4'b0}) + 10'sd1)
	                                       : -$signed({2'b0, yoffs});

	// y stepper
	logic        negy;
	logic [7:0]  m1;                       // |coef_y|
	logic [17:0] acc1;
	logic [14:0] acc2;
	logic [9:0]  ysh;
	wire  [9:0]  coef_mag = coef_y[9] ? -coef_y : coef_y;
	wire  [9:0]  m1x3 = {2'b0, m1} + {1'b0, m1, 1'b0};
	wire  [6:0]  hx3  = {2'b0, h} + {1'b0, h, 1'b0};
	logic [9:0]  sel1;
	logic [6:0]  sel2;
	always_comb begin
		case (ysh[9:8])
			2'd0:    begin sel1 = 10'd0;            sel2 = 7'd0;            end
			2'd1:    begin sel1 = {2'b0, m1};       sel2 = {2'b0, h};       end
			2'd2:    begin sel1 = {1'b0, m1, 1'b0}; sel2 = {1'b0, h, 1'b0}; end
			default: begin sel1 = m1x3;             sel2 = hx3;             end
		endcase
	end

	// y result
	wire signed [18:0] p1s = negy ? -$signed({1'b0, acc1}) : $signed({1'b0, acc1});
	wire signed [12:0] ybase_int = $signed({y_r[11], y_r}) + $signed({{2{p1s[18]}}, p1s[18:8]});
	wire signed [13:0] bby = $signed({5'b0, line_r}) - $signed({ybase_int[12], ybase_int});
	wire               y_hit = !bby[13] && (bby[12:10] == 3'b0) && ({bby[9:0], 4'b0} < {1'b0, acc2});

	// word fields of the entry port
	wire [15:0] e_w0 = ent_data[15:0],  e_w1 = ent_data[31:16], e_w2 = ent_data[47:32];
	wire [15:0] e_w3 = ent_data[63:48], e_w4 = ent_data[79:64], e_w5 = ent_data[95:80];

	// block fields from either source
	wire [31:0] p0 = vr_data[31:0], p1 = vr_data[63:32], p2 = vr_data[95:64], p3 = vr_data[127:96];
	logic       blk_half;                  // which 8 bytes of the unit: indx[0] of the request
	wire [63:0] qq = blk_half ? mem_rdata[127:64] : mem_rdata[63:0];
	wire [7:0]  q0 = qq[7:0],   q1 = qq[15:8],  q2 = qq[23:16], q3 = qq[31:24];
	wire [7:0]  q4 = qq[39:32], q5 = qq[47:40], q6 = qq[55:48], q7 = qq[63:56];

	wire [1:0] ras_i = ras_sel - 2'd1;
	wire signed [10:0] ras_y_s = $signed(ras_y[11*ras_i +: 11]);
	wire signed [10:0] ras_x_s = $signed(ras_x[11*ras_i +: 11]);
	wire       use_ras = ras_mode && (ras_sel != 2'd0);

	assign cand_addr = ci;
	assign ent_addr  = (state == S_CANDW) ? cand_data[8:0] : (idx - 9'd1);
	assign done      = (state == S_IDLE);
	wire   cand_end  = ({1'b0, ci} == cand_count);

	// the hit record
	always_comb begin
		hit.bby       = bby[9:0];
		hit.yscale    = yscale;
		hit.xscale    = xscale;
		hit.xextra    = xextra;
		hit.x         = x_r;
		hit.xoffs     = xoffs;
		hit.h         = h;
		hit.w         = w;
		hit.fx        = fx0 ^ fx1;
		hit.fy        = fy0 ^ fy1;
		hit.color     = color;
		hit.shadow    = shadow;
		hit.clipper   = clipper;
		hit.pair      = pair;
		hit.sprite    = sprite;
		hit.sprite2   = sprite2;
		hit.is_table  = is_table;
		hit.table_rom = table_rom;
		hit.tile_fmt  = tile_fmt;
		hit.hibits    = hibits;
	end

	wire blk_indx_rom  = indx[14];
	wire blk2_indx_rom = indx2[14];

	always_ff @(posedge clk) begin
		if (reset) begin
			state        <= S_IDLE;
			ci           <= '0;
			vr_req       <= 1'b0;
			mem_req      <= 1'b0;
			mem_inflight <= 1'b0;
			hit_push     <= 1'b0;
			restart      <= 1'b0;
		end else begin
			hit_push <= 1'b0;
			mstep    <= 3'd0;
			if (mem_take) begin mem_req <= 1'b0; mem_inflight <= 1'b1; end
			if (mem_ack)  mem_inflight <= 1'b0;

			if (line_start) begin
				vr_req  <= 1'b0;
				mem_req <= 1'b0;                 // withdrawn unless taken this clock
				ci      <= '0;
				line_r  <= scanline;
				if (mem_take || (mem_inflight && !mem_ack)) begin
					restart <= line_valid;
					state   <= S_DRAIN;
				end else begin
					restart <= 1'b0;
					state   <= line_valid ? S_CAND : S_IDLE;
				end
			end else begin
				case (state)
					S_IDLE: ;

					S_DRAIN: begin
						if (mem_ack) state <= restart ? S_CAND : S_IDLE;
					end

					S_CAND: begin                          // cand_addr = ci
						if (cand_end) state <= S_IDLE;
						else state <= S_CANDW;
					end

					S_CANDW: begin                         // cand_data valid; ent_addr = its index
						pair  <= cand_data[9];
						idx   <= cand_data[8:0];
						state <= S_ENTW;
					end

					S_ENTW: begin                          // ent_data = entry idx
						indx     <= e_w0[14:0];
						fx0      <= e_w1[15];
						fy0      <= e_w1[14];
						flick    <= e_w1[13];
						ras_mode <= e_w1[10];
						ras_sel  <= e_w1[8:7];
						clipper  <= {e_w1[11], e_w1[8], e_w1[9]};   // v 245-251
						// v 263-265: the two bits above the colour are the shadow mode; the colour has
						// 0x800 / granularity values (video_start, v 20-29)
						case (layout)
							L_6BPP: begin color <= {2'b0, e_w1[4:0]}; shadow <= e_w1[6:5]; end
							L_5BPP, L_ACCHI: begin color <= {1'b0, e_w1[5:0]}; shadow <= e_w1[7:6]; end
							default: begin color <= e_w1[6:0]; shadow <= {1'b0, e_w1[7]}; end   // (color & 0x180) >> 7
						endcase
						y0       <= $signed(e_w2[10:0]);
						x0       <= $signed(e_w3[10:0]);
						yscale   <= e_w4[9:0];
						xscale   <= e_w5[9:0];
						state    <= pair ? S_ENT2W : S_TEST;
					end

					S_ENT2W: begin                         // ent_data = entry idx-1
						color <= e_w1[6:0];                      // v 270
						indx2 <= e_w0[14:0];
						state <= S_TEST;
					end

					S_TEST: begin
						if (line_r < clip_min_y[10*clipper +: 10] || line_r > clip_max_y[10*clipper +: 10]) begin
							state <= S_NEXT;                         // v 256-257
						end else begin
							// raster set (v 362-397), before the block is known
							if (use_ras) begin
								y_r    <= $signed({y0[10], y0}) + $signed({ras_y_s[10], ras_y_s});
								x_r    <= $signed({x0[10], x0}) + $signed({ras_x_s[10], ras_x_s});
								xextra <= ras_s[10*ras_i +: 10];
							end else begin
								y_r    <= $signed({y0[10], y0});
								x_r    <= $signed({x0[10], x0});
								xextra <= 10'h100;
							end
							if (blk_indx_rom) begin
								mem_req  <= 1'b1;
								mem_addr <= GFX2_BASE + {8'b0, indx[14:1], 4'b0};
								blk_half <= indx[0];
							end else begin
								vr_req  <= 1'b1;
								vr_addr <= indx[12:0];
							end
							state <= S_BLKW;
						end
					end

					S_BLKW: begin
						if (blk_indx_rom ? mem_ack : vr_ack) begin
							vr_req <= 1'b0;
							if (blk_indx_rom) begin              // v 276-303
								blk_flick <= q5[0];
								h         <= (q1[3:0] == 4'd0) ? 5'd16 : {1'b0, q1[3:0]};
								w         <= (q3[3:0] == 4'd0) ? 5'd16 : {1'b0, q3[3:0]};
								sprite    <= {q4[1:0], q7, q6};
								yoffs     <= q0;
								xoffs     <= q2;
								fy1       <= q1[4];
								fx1       <= q3[4];
								tile_fmt  <= q4[7];
								is_table  <= |q4[7:6];
								hibits    <= 4'd0;
								table_rom <= 1'b0;
							end else begin                       // v 307-334
								blk_flick <= p2[8];
								h         <= (p0[11:8] == 4'd0) ? 5'd16 : {1'b0, p0[11:8]};
								w         <= (p1[11:8] == 4'd0) ? 5'd16 : {1'b0, p1[11:8]};
								sprite    <= {p2[1:0], p3[15:0]};
								yoffs     <= p0[7:0];
								xoffs     <= p1[7:0];
								fy1       <= p0[12];
								fx1       <= p1[12];
								tile_fmt  <= p2[7];
								is_table  <= |p2[7:6];
								hibits    <= p2[5:2];
								table_rom <= |p2[1:0];
							end
							state <= S_MUL;
						end
					end

					S_MUL: begin
						// first clock: load the stepper; then five digit steps
						if (mstep == 3'd0) begin
							negy  <= coef_y[9];
							m1    <= coef_mag[7:0];
							acc1  <= '0;
							acc2  <= '0;
							ysh   <= yscale;
							mstep <= 3'd1;
							if (blk_flick && parity) state <= S_NEXT;   // v 278, 310
						end else begin
							acc1  <= {acc1[15:0], 2'b0} + {8'b0, sel1};
							acc2  <= {acc2[12:0], 2'b0} + {8'b0, sel2};
							ysh   <= {ysh[7:0], 2'b0};
							mstep <= mstep + 3'd1;
							if (mstep == 3'd5) state <= S_DECIDE;
						end
					end

					S_DECIDE: begin
						if (!y_hit) state <= S_NEXT;
						else if (pair) begin
							if (blk2_indx_rom) begin
								mem_req  <= 1'b1;
								mem_addr <= GFX2_BASE + {8'b0, indx2[14:1], 4'b0};
								blk_half <= indx2[0];
							end else begin
								vr_req  <= 1'b1;
								vr_addr <= indx2[12:0];
							end
							state <= S_BLK2W;
						end else begin
							sprite2 <= '0;
							state   <= S_PUSH;
						end
					end

					S_BLK2W: begin                         // v 337-351
						if (blk2_indx_rom ? mem_ack : vr_ack) begin
							vr_req  <= 1'b0;
							sprite2 <= blk2_indx_rom ? {2'b0, q7, q6} : {p2[1:0], p3[15:0]};
							state   <= S_PUSH;
						end
					end

					S_PUSH: begin
						if (!hit_full) begin
							hit_push <= 1'b1;
							state    <= S_NEXT;
						end
					end

					S_NEXT: begin
						ci    <= ci + 9'd1;
						state <= S_CAND;
					end

					default: state <= S_IDLE;
				endcase
			end
		end
	end

endmodule
