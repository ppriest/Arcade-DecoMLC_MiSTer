// SPDX-License-Identifier: GPL-3.0-or-later
// The MLC board: mlc_core (the SH7604, its bus, the video) on mlc_sdram_top (the program ROM,
// the sprite units, the samples, the download). What is left above this is the MiSTer
// framework's glue in DecoMLC.sv: HPS, PLL, inputs, the video output path.
module mlc_top (
	input  logic         clk,
	input  logic         clk_cpu,
	input  logic         reset,           // the game (held through the download)
	input  logic         video_reset,     // the raster
	input  logic         init,            // the SDRAM controller's init (PLL lock)
	input  logic         pause,

	output logic [12:0]  SDRAM_A,
	output logic         SDRAM_DQML,
	output logic         SDRAM_DQMH,
	output logic [1:0]   SDRAM_BA,
	output logic         SDRAM_nCS,
	output logic         SDRAM_nWE,
	output logic         SDRAM_nRAS,
	output logic         SDRAM_nCAS,
	output logic         SDRAM_CLK,
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
	input  logic         ldr_start,
	input  logic [27:0]  ldr_length,
	output logic         ldr_busy,

	input  logic [31:0]  inputs_n,
	input  logic         ee_we,
	input  logic [5:0]   ee_addr,
	input  logic [15:0]  ee_din,
	input  logic         flip,
	input  logic [16:0]  hs_addr,
	input  logic [7:0]   hs_din,
	output logic [7:0]   hs_dout,
	input  logic         hs_we,

	output logic         ce_pix,
	output logic [7:0]   r, g, b,
	output logic         hblank, vblank, hs, vs,
	output logic         vbl_start,
	output logic         frame_top,
	output logic [7:0]   volume,
	output logic [15:0]  snd_l, snd_r,   // signed
	output logic         line_done,
	output logic         ovr_ev,
	input  logic         dbg_clear,
	output logic [111:0] dbg,
	// the program fetches as the CPU receives them, for the _stp probe
	output logic         dbg_rom_valid,
	output logic [19:0]  dbg_rom_addr,
	output logic [31:0]  dbg_rom_data
);

	// The game starts as MAME's does: its reset is released at the first clock of line 0 (MAME
	// runs the CPU from line 0 of frame 0), and the frame parity for the auto-flicker sprites
	// (deco_mlc_v.cpp 170) toggles at each vblank from a fixed start. The start value is set by
	// measurement: an effect sprite MAME draws on even attract frames only showed on the board's
	// match for odd frames 2805 and then 2377 with a start of 1 (scripts/match_frame.py, debug/hw/).
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

	mlc_core u_core (
		.clk, .clk_cpu, .reset(game_reset), .video_reset, .pause,
		.cpu_rom_req, .cpu_rom_addr, .cpu_rom_valid, .cpu_rom_data,
		.spr_req, .spr_addr, .spr_valid, .spr_rdata,
		.ymz_req, .ymz_addr, .ymz_valid, .ymz_rdata,
		.inputs_n, .ee_we, .ee_addr, .ee_din, .parity_in(parity), .flip, .hs_addr, .hs_din, .hs_dout, .hs_we,
		.ce_pix, .r, .g, .b, .hblank, .vblank, .hs, .vs, .vbl_start, .frame_top,
		.volume, .snd_l, .snd_r, .line_done, .ovr_ev, .dbg_clear, .dbg
	);

	mlc_sdram_top u_mem (
		.clk, .reset(video_reset), .init,
		.SDRAM_A, .SDRAM_DQML, .SDRAM_DQMH, .SDRAM_BA, .SDRAM_nCS, .SDRAM_nWE, .SDRAM_nRAS, .SDRAM_nCAS,
		.SDRAM_CLK, .SDRAM_CKE, .SDRAM_DQ,
		.ioctl_download, .ioctl_index, .ioctl_wr, .ioctl_addr, .ioctl_dout, .ioctl_wait,
		.DDRAM_BUSY, .DDRAM_BURSTCNT, .DDRAM_ADDR, .DDRAM_DOUT, .DDRAM_DOUT_READY, .DDRAM_RD, .DDRAM_DIN, .DDRAM_BE, .DDRAM_WE,
		.ldr_start, .ldr_length, .ldr_busy,
		.spr_req, .spr_addr, .spr_valid, .spr_rdata,
		.cpu_rom_req, .cpu_rom_addr, .cpu_rom_valid, .cpu_rom_data,
		.ymz_req, .ymz_addr, .ymz_valid, .ymz_rdata
	);

endmodule
