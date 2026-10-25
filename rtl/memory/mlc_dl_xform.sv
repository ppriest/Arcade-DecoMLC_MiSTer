// SPDX-License-Identifier: GPL-3.0-or-later
// The download address transform: the .mra image is MAME's regions in order (maincpu, gfx1,
// gfx2, ymz at the memory plan's bases); gfx1 is rewritten into 16-byte units of two tiles'
// rows (scripts/mlc_layout.py, docs/phase1_video.md "gfx1 layout"). Region byte a of gfx1, with
// h = a >= 0xC00000 and o = a - h * 0xC00000, goes to {o[23:7], o[5:2], o[6], h, o[1:0]}; every
// other byte keeps its address. Combinational; the download path pairs bytes after it, which the
// transform allows since the byte's low two address bits are kept.
module mlc_dl_xform (
	input  logic [25:0] in_addr,     // offset in the .mra image
	output logic [25:0] out_addr     // SDRAM byte address
);
	localparam logic [25:0] GFX1_BASE = 26'h0100000;
	localparam logic [25:0] GFX1_END  = 26'h1900000;
	localparam logic [23:0] HALF      = 24'hC00000;

	wire        in_gfx1 = (in_addr >= GFX1_BASE) && (in_addr < GFX1_END);
	wire [24:0] a       = 25'(in_addr - GFX1_BASE);          // 0 .. 0x17FFFFF
	wire        h       = (a >= {1'b0, HALF});
	wire [23:0] o       = h ? 24'(a - {1'b0, HALF}) : a[23:0];
	wire [24:0] d       = {o[23:7], o[5:2], o[6], h, o[1:0]};

	assign out_addr = in_gfx1 ? (GFX1_BASE + {1'b0, d}) : in_addr;
endmodule
