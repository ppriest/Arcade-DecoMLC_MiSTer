// SPDX-License-Identifier: GPL-3.0-or-later
// The MLC board: mlc_core (the SH7604 or, with DE156, the ARM; its bus, the video) on
// mlc_sdram_top (the program ROM, the sprite units, the samples, the download). The MiSTer
// framework's glue is in DecoMLC.sv: HPS, PLL, inputs, the video output path.
module mlc_top #(
	parameter bit DE156 = 1'b0
) (
	input  logic         clk,             // 84 MHz clk_sys
	input  logic         clk_cpu,         // 42 MHz, the same PLL
	input  logic         clk_sdram,       // 126 MHz: the SDRAM controller (mlc_sdram_top)
	input  logic         reset,           // the game (held through the download)
	input  logic         video_reset,     // the raster
	input  logic         init,            // the SDRAM controller's init (PLL lock)
	input  logic         pause,           // holds the CPU

	output logic [12:0]  SDRAM_A,
	output logic         SDRAM_DQML,
	output logic         SDRAM_DQMH,
	output logic [1:0]   SDRAM_BA,
	output logic         SDRAM_nCS,
	output logic         SDRAM_nWE,
	output logic         SDRAM_nRAS,
	output logic         SDRAM_nCAS,
	output logic         SDRAM_CLK,       // simulation only: the pin is driven from the PLL (DecoMLC.sv)
	output logic         SDRAM_CKE,
	inout  wire  [15:0]  SDRAM_DQ,

	input  logic         ioctl_download,
	input  logic [15:0]  ioctl_index,
	input  logic         ioctl_wr,
	input  logic [26:0]  ioctl_addr,
	input  logic [7:0]   ioctl_dout,
	output logic         ioctl_wait,

	input  logic         DDRAM_BUSY,
	output logic [7:0]   DDRAM_BURSTCNT,
	output logic [28:0]  DDRAM_ADDR,
	input  logic [63:0]  DDRAM_DOUT,
	input  logic         DDRAM_DOUT_READY,
	output logic         DDRAM_RD,
	output logic [63:0]  DDRAM_DIN,
	output logic [7:0]   DDRAM_BE,
	output logic         DDRAM_WE,
	// fast ROM load, DDR3 to SDRAM (rtl/memory/rom_loader.sv)
	input  logic         ldr_start,
	input  logic [27:0]  ldr_length,      // bytes
	output logic         ldr_busy,

	input  logic [31:0]  inputs_n,        // the 0x400000 word, active low
	input  logic         has146,          // the set has the DECO 146 (the .mra mod byte)
	input  logic [1:0]   gfx_layout,      // the gfx_layout (the .mra mod byte): the engine and the download
	input  logic         gfx_frac8,       // a third of gfx1 is 8 MB (stadhr96)
	// the factory EEPROM image, 64 words
	input  logic         ee_we,
	input  logic [5:0]   ee_addr,
	input  logic [15:0]  ee_din,
	input  logic         flip,            // flip screen (OSD or the .mra's fake DIP)
	// hiscore (rtl/hiscore.v): a byte address in main RAM; writes only with the CPU paused
	input  logic [16:0]  hs_addr,
	input  logic [7:0]   hs_din,
	output logic [7:0]   hs_dout,
	input  logic         hs_we,

	output logic         ce_pix,
	output logic [7:0]   r, g, b,
	output logic         hblank, vblank, hs, vs,
	output logic         vbl_start,
	output logic         frame_top,
	output logic [7:0]   volume,          // the master volume byte (0x500000)
	output logic [15:0]  snd_l, snd_r,   // signed
	output logic         line_done,       // the sprite engine has nothing left to do for the line
	output logic         ovr_ev,          // pulse: a line started with the previous one unfinished
	// the _stp revision's probe bus (mlc_core)
	input  logic         dbg_clear,
	output logic [111:0] dbg,
	// the program fetches as the CPU receives them, for the _stp probe
	output logic         dbg_rom_valid,
	output logic [19:0]  dbg_rom_addr,
	output logic [31:0]  dbg_rom_data
);

	// The game starts as MAME's does: its reset is released at the first clock of line 0 (MAME
	// runs the CPU from line 0 of frame 0), and the frame parity for the auto-flicker sprites
	// (deco_mlc_v.cpp 170) toggles at each vblank from a fixed start. The start value is measured:
	// with a start of 1, an effect sprite MAME draws on even attract frames only matched the
	// board on odd frames (2805, 2377; scripts/match_frame.py, debug/hw/).
	logic game_run = 1'b0, parity = 1'b0;
	wire  game_reset = reset | ~game_run;
	always_ff @(posedge clk) begin
		if (reset)          game_run <= 1'b0;
		else if (frame_top) game_run <= 1'b1;
		if (game_reset)     parity <= 1'b0;
		else if (vbl_start) parity <= ~parity;
	end

	logic         cpu_rom_req, cpu_rom_valid;
	logic [19:0]  cpu_rom_addr;
	logic [31:0]  cpu_rom_data;
	logic [1:0]   spr_req, spr_valid;
	logic [51:0]  spr_addr;
	logic [127:0] spr_rdata;
	logic         ymz_req, ymz_valid;
	logic [25:0]  ymz_addr;
	logic [127:0] ymz_rdata;
	assign dbg_rom_valid = cpu_rom_valid;
	assign dbg_rom_addr  = cpu_rom_addr;
	assign dbg_rom_data  = cpu_rom_data;

	mlc_core #(.DE156(DE156)) u_core (
		.clk, .clk_cpu, .reset(game_reset), .video_reset, .pause,
		.cpu_rom_req, .cpu_rom_addr, .cpu_rom_valid, .cpu_rom_data,
		.spr_req, .spr_addr, .spr_valid, .spr_rdata,
		.ymz_req, .ymz_addr, .ymz_valid, .ymz_rdata,
		.inputs_n, .has146, .gfx_layout, .gfx_frac8, .ee_we, .ee_addr, .ee_din, .parity_in(parity), .flip, .hs_addr, .hs_din, .hs_dout, .hs_we,
		.ce_pix, .r, .g, .b, .hblank, .vblank, .hs, .vs, .vbl_start, .frame_top,
		.volume, .snd_l, .snd_r, .line_done, .ovr_ev, .dbg_clear, .dbg
	);

	mlc_sdram_top #(.CPU_LE(DE156)) u_mem (
		.clk, .reset(video_reset), .clk_sdram, .init,
		.SDRAM_A, .SDRAM_DQML, .SDRAM_DQMH, .SDRAM_BA, .SDRAM_nCS, .SDRAM_nWE, .SDRAM_nRAS, .SDRAM_nCAS,
		.SDRAM_CLK, .SDRAM_CKE, .SDRAM_DQ,
		.ioctl_download, .ioctl_index, .ioctl_wr, .ioctl_addr, .ioctl_dout, .ioctl_wait,
		.DDRAM_BUSY, .DDRAM_BURSTCNT, .DDRAM_ADDR, .DDRAM_DOUT, .DDRAM_DOUT_READY, .DDRAM_RD, .DDRAM_DIN, .DDRAM_BE, .DDRAM_WE,
		.ldr_start, .ldr_length, .ldr_busy,
		.spr_req, .spr_addr, .spr_valid, .spr_rdata,
		.cpu_rom_req, .cpu_rom_addr, .cpu_rom_valid, .cpu_rom_data,
		.ymz_req, .ymz_addr, .ymz_valid, .ymz_rdata,
		.gfx_layout, .gfx_frac8
	);

endmodule
