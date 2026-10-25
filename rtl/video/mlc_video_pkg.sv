// SPDX-License-Identifier: GPL-3.0-or-later
// Shared constants and the hit record of the MLC sprite engine (docs/phase1_video.md).
package mlc_video_pkg;

	// SDRAM byte addresses (docs/ROADMAP.md, Memory plan); scripts/mlc_layout.py checks its
	// copy against these, and the .mra generator builds the image from mlc_layout
	localparam logic [25:0] MAINCPU_BASE = 26'h0000000;   // 1 MB, the SH-2's program
	localparam logic [25:0] GFX1_BASE    = 26'h0100000;   // 24 MB, 16-byte units of two tiles' rows
	localparam logic [25:0] GFX2_BASE    = 26'h1900000;   // 512 KB, index blocks and tile tables
	localparam logic [25:0] YMZ_BASE     = 26'h1980000;   // 6 MB of samples
	localparam logic [25:0] ROM_END      = 26'h1F80000;
	localparam logic [17:0] GFX1_TILES = 18'h30000;    // gfx->elements(): 196,608

	localparam int SCREEN_W = 320;
	localparam int VIS_TOP  = 8;                        // MAME's first visible line (mlc 567)
	localparam int VIS_BOT  = 247;

	// One entry the scanner found covering the line, as the drawer needs it. The list and
	// block fields are deco_mlc_v.cpp 213-335's, after the raster offsets (v 362-397) and the
	// flip XORs (v 353-354); bby is v 432's.
	typedef struct packed {
		logic [9:0]         bby;        // scanline - (ybase >> 16), 0..1023
		logic [9:0]         yscale;
		logic [9:0]         xscale;
		logic [9:0]         xextra;     // extra_x_scale: 0x100, or the raster set's
		logic signed [11:0] x;          // list x plus the raster set's offset
		logic [7:0]         xoffs;
		logic [4:0]         h;          // 1..16
		logic [4:0]         w;
		logic               fx;
		logic               fy;
		logic [6:0]         color;      // v 265 / v 270
		logic [1:0]         shadow;     // v 263
		logic [2:0]         clipper;
		logic               pair;       // 8bpp: two blocks a pixel (v 164)
		logic [17:0]        sprite;
		logic [17:0]        sprite2;
		logic               is_table;   // v 298-301, 320-323
		logic               table_rom;  // v 328: the table is in gfx2
		logic               tile_fmt;   // v 296, 325: 12-bit tile + 4-bit colour
		logic [3:0]         hibits;     // v 327, as (p2 & 0x3c) >> 2
	} hit_t;

endpackage
