// SPDX-License-Identifier: GPL-3.0-or-later
// The download address transform: the .mra image is MAME's regions in order (maincpu, gfx1,
// gfx2, ymz at the memory plan's bases); gfx1 is rewritten into 16-byte units (scripts/
// mlc_layout.py gfx1_dest, docs/phase1_video.md "gfx1 layout"), every other byte keeps its
// address. Combinational; the download path pairs bytes after it, which the transform allows
// since a byte's lowest address bit is kept.
//
// The base area, from gfx1's start: a unit is row r of tiles 2k and 2k+1, each tile's row as
// 4 bytes of pen bits 0-1 then 4 of pen bits 2-3. The extra area, 16 MB in, for the deeper
// layouts: a unit is row r of tiles 4k..4k+3, 4 bytes each, pen bits 4 (bytes 0-1) and 5 (2-3).
//   4bpp  (avengrgs): halves of 12 MB; region byte a, h = a >= 12 MB, o = a - 12 MB * h:
//         {o[23:7], o[5:2], o[6], h, o[1:0]}
//   5bpp, 6bpp: thirds of 4 MB, or 8 MB with frac8 (stadhr96); third T, offset o: T = 0, 1 are
//         the base area's halves as above, T = 2 goes to the extra area at
//         {o[22:8], o[5:2], o[7:6], o[1:0]}
//   acchi: fifths of 4 MB, one plane each, 16-bit rows, the first the pen's MSB: fifth 4 is pen
//         bit 0 and goes where 4bpp's bytes 0-1 go, 3 bytes 2-3, 2 and 1 the second half's, 0
//         the extra area's bytes 0-1
// The DE156 program (de156): MAME's descramble reads raw word AddrScramble(a) for ARM word a
// (deco156.cpp; rtl/cpu/de156), a linear map on the low 16 bits of the word address. The
// download stores raw word r at a = AddrScramble^-1(r), so the ARM's consecutive words are
// consecutive in SDRAM and share a unit; the data descramble, which needs only a, stays at
// fetch. The inverse: a[i] = ^((r ^ 0x92c6) & m[i]) (derived and checked over every address
// when it was written).
// A region shorter than the window (5bpp and 6bpp with 4 MB thirds: 12 MB; acchi 20 MB) is
// followed in the image by the .mra's zero padding up to gfx2; those bytes go to the spare
// space past the last region (ROM_END), not onto the transformed tiles.
module mlc_dl_xform
	import mlc_video_pkg::*;
(
	input  logic [1:0]  layout,      // mlc_video_pkg L_*
	input  logic        frac8,
	input  logic        de156,       // the program is the DE156's (the DecoMLC156 build)
	input  logic [25:0] in_addr,     // offset in the .mra image
	output logic [25:0] out_addr     // SDRAM byte address
);
	localparam logic [25:0] GFX1_END = 26'h1900000;
	localparam logic [24:0] EXT      = 25'h1000000;      // GFX1_EXT - GFX1_BASE
	localparam logic [23:0] HALF     = 24'hC00000;

	wire        in_gfx1 = (in_addr >= GFX1_BASE) && (in_addr < GFX1_END);
	wire [24:0] a       = 25'(in_addr - GFX1_BASE);          // 0 .. 0x17FFFFF

	// 4bpp
	wire        h4 = (a >= {1'b0, HALF});
	wire [23:0] o4 = h4 ? 24'(a - {1'b0, HALF}) : a[23:0];
	wire [24:0] d4 = {o4[23:7], o4[5:2], o4[6], h4, o4[1:0]};

	// 5bpp, 6bpp
	wire [1:0]  t3 = frac8 ? a[24:23] : a[23:22];
	wire [22:0] o3 = frac8 ? a[22:0]  : {1'b0, a[21:0]};
	wire [24:0] d3 = (t3 == 2'd2) ? EXT + {2'b0, o3[22:8], o3[5:2], o3[7:6], o3[1:0]}
	                              : {1'b0, o3[22:7], o3[5:2], o3[6], t3[0], o3[1:0]};

	// acchi
	wire [2:0]  p5 = a[24:22];
	wire [21:0] o5 = a[21:0];
	wire        h5 = (p5 == 3'd1) || (p5 == 3'd2);
	wire        b5 = (p5 == 3'd1) || (p5 == 3'd3);
	wire [24:0] d5 = (p5 == 3'd0) ? EXT + {2'b0, o5[21:7], o5[4:1], o5[6:5], 1'b0, o5[0]}
	                              : {1'b0, o5[21:6], o5[4:1], o5[5], h5, b5, o5[0]};

	wire        pad = (layout == L_ACCHI) ? (p5 > 3'd4)
	                : (layout != L_4BPP && !frac8) ? (a[24] || a[23:22] == 2'd3) : 1'b0;
	wire [24:0] d = (layout == L_4BPP) ? d4 : (layout == L_ACCHI) ? d5 : d3;

	// the DE156 program
	wire        in_prog = de156 && (in_addr < MAINCPU_BASE + 26'h0100000);
	wire [15:0] prog_x  = in_addr[17:2] ^ 16'h92c6;
	logic [15:0] prog_a;
	assign prog_a[ 0] = ^(prog_x & 16'h6f0d);
	assign prog_a[ 1] = ^(prog_x & 16'h8a5b);
	assign prog_a[ 2] = ^(prog_x & 16'h82dd);
	assign prog_a[ 3] = ^(prog_x & 16'h08db);
	assign prog_a[ 4] = ^(prog_x & 16'h1db4);
	assign prog_a[ 5] = ^(prog_x & 16'h29b7);
	assign prog_a[ 6] = ^(prog_x & 16'h61b6);
	assign prog_a[ 7] = ^(prog_x & 16'h5d86);
	assign prog_a[ 8] = ^(prog_x & 16'he9a2);
	assign prog_a[ 9] = ^(prog_x & 16'habb3);
	assign prog_a[10] = ^(prog_x & 16'h8ab9);
	assign prog_a[11] = ^(prog_x & 16'h9abd);
	assign prog_a[12] = ^(prog_x & 16'heb15);
	assign prog_a[13] = ^(prog_x & 16'h699a);
	assign prog_a[14] = ^(prog_x & 16'hb009);
	assign prog_a[15] = ^(prog_x & 16'h13f1);
	wire [25:0] prog_o  = {6'd0, in_addr[19:18], prog_a, in_addr[1:0]};

	assign out_addr = in_prog ? prog_o : !in_gfx1 ? in_addr : pad ? (ROM_END + {25'd0, in_addr[0]}) : (GFX1_BASE + {1'b0, d});
endmodule
