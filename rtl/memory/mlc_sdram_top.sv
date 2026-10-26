// SPDX-License-Identifier: GPL-3.0-or-later
// The SDRAM backend: one chip (rtl/memory/sdram/sdram.sv at burst 8, 16-byte units) on its own
// 126 MHz clock, its three ports reached from the 84 MHz side through sdram_port_cdc's queues
// (requests in, answers back, in order) with mlc_port_arbiter keeping each port's clients'
// reads in flight, so the controller runs units back to back. Port 0: the sprite engine's two slots and the ROM download's
// writes. Port 1: the SH-2's program ROM through a 32-bit bridge (one unit is a cache line).
// Port 2: the YMZ280B's samples, 16-byte units for its unit buffer (rtl/sound/mlc_ymz_mem.sv).
// The image arrives as MAME's regions at scripts/mlc_layout.py's bases, by ioctl bytes or by
// the DDR3 copy (rom_loader); both pass mlc_dl_xform, which moves gfx1 into its unit layout.
module mlc_sdram_top
	import mlc_video_pkg::*;
#(
	parameter bit CPU_LE = 1'b0       // the program as the region's little-endian words (the DE156)
)
(
	input  logic         clk,
	input  logic         reset,
	input  logic         clk_sdram,       // 126 MHz, the controller's (the same PLL, constrained as asynchronous)
	input  logic         init,

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

	// HPS download, hps_io's ioctl_* (index 0 only)
	input  logic         ioctl_download,
	input  logic [15:0]  ioctl_index,
	input  logic         ioctl_wr,
	input  logic [26:0]  ioctl_addr,
	input  logic [7:0]   ioctl_dout,
	output logic         ioctl_wait,

	// fast load from DDR3 (rom_loader): the HPS put the image at 0x30000000
	input  logic         DDRAM_BUSY,
	output logic [7:0]   DDRAM_BURSTCNT,
	output logic [28:0]  DDRAM_ADDR,
	input  logic [63:0]  DDRAM_DOUT,
	input  logic         DDRAM_DOUT_READY,
	output logic         DDRAM_RD,
	output logic [63:0]  DDRAM_DIN,
	output logic [7:0]   DDRAM_BE,
	output logic         DDRAM_WE,
	input  logic         ldr_start,       // pulse: copy ldr_length bytes
	input  logic [27:0]  ldr_length,
	output logic         ldr_busy,        // hold the core in reset while high

	// sprite engine: two arbiter clients (mlc_sprite_engine)
	input  logic [1:0]   spr_req,
	input  logic [51:0]  spr_addr,
	output logic [1:0]   spr_valid,
	output logic [127:0] spr_rdata,

	// SH-2 program ROM: 32-bit words, big-endian as the region is, byte address in the 1 MB
	input  logic         cpu_rom_req,     // pulse; hold addr until valid
	input  logic [19:0]  cpu_rom_addr,
	output logic         cpu_rom_valid,
	output logic [31:0]  cpu_rom_data,

	// YMZ280B sample ROM: units (a pulse, the SDRAM byte address held until valid)
	input  logic         ymz_req,
	input  logic [25:0]  ymz_addr,
	output logic         ymz_valid,
	output logic [127:0] ymz_rdata,

	// the gfx1 layout, for the download's transform (mlc_dl_xform)
	input  logic [1:0]   gfx_layout,
	input  logic         gfx_frac8
);

	localparam int GB = 16;

	// ---- the chip, three ports ----
	logic [25:1]      p0_addr, p1_addr, p2_addr;
	logic             p0_wrl, p0_wrh, p1_wrl, p1_wrh, p2_wrl, p2_wrh;
	logic [15:0]      p0_din, p1_din, p2_din;
	logic [8*GB-1:0]  p0_dout, p1_dout, p2_dout;
	logic             p0_req, p1_req, p2_req, p0_ack, p1_ack, p2_ack;

	// clk_sdram's reset and init: two registers each
	logic [1:0] rst_s, init_s;
	always_ff @(posedge clk_sdram) begin
		rst_s  <= {rst_s[0], reset};
		init_s <= {init_s[0], init};
	end
	wire reset_sdram = rst_s[1];

	sdram #(.BL8(1), .RFS_CYCLES(980), .RCD(3), .CL(3)) u_sdram (   // 980 / 126 MHz = 7.78 us
		.SDRAM_DQ, .SDRAM_A, .SDRAM_DQML, .SDRAM_DQMH, .SDRAM_BA, .SDRAM_nCS, .SDRAM_nWE,
		.SDRAM_nRAS, .SDRAM_nCAS, .SDRAM_CLK, .SDRAM_CKE,
		.init(init_s[1]), .clk(clk_sdram),
		.addr0(p0_addr), .wrl0(p0_wrl), .wrh0(p0_wrh), .din0(p0_din), .dout0(p0_dout), .req0(p0_req), .ack0(p0_ack),
		.addr1(p1_addr), .wrl1(p1_wrl), .wrh1(p1_wrh), .din1(p1_din), .dout1(p1_dout), .req1(p1_req), .ack1(p1_ack),
		.addr2(p2_addr), .wrl2(p2_wrl), .wrh2(p2_wrh), .din2(p2_din), .dout2(p2_dout), .req2(p2_req), .ack2(p2_ack)
	);

	// ---- port 0: sprites and the download writes ----
	logic             a0_req, a0_we, a0_we16, a0_busy, a0_valid;
	logic [25:0]      a0_addr;
	logic [15:0]      a0_wdata;
	logic [8*GB-1:0]  a0_rdata;

	sdram_port_cdc #(.GB(GB)) u_phy0 (
		.clk, .reset, .clk_sdram, .reset_sdram,
		.port_addr(p0_addr), .port_wrl(p0_wrl), .port_wrh(p0_wrh), .port_din(p0_din), .port_dout(p0_dout),
		.port_req(p0_req), .port_ack(p0_ack),
		.req(a0_req), .we(a0_we), .we16(a0_we16), .addr(a0_addr), .wdata(a0_wdata),
		.busy(a0_busy), .valid(a0_valid), .rdata(a0_rdata)
	);

	logic         dl_req, dl_busy, dl_we16;
	logic [25:0]  dl_addr;
	logic [15:0]  dl_data;

	mlc_port_arbiter #(.N(2), .GB(GB)) u_arb0 (
		.clk, .reset,
		.phy_req(a0_req), .phy_we(a0_we), .phy_we16(a0_we16), .phy_addr(a0_addr), .phy_wdata(a0_wdata),
		.phy_busy(a0_busy), .phy_valid(a0_valid), .phy_rdata(a0_rdata),
		.c_req(spr_req), .c_addr(spr_addr), .c_valid(spr_valid), .c_rdata(spr_rdata),
		.dl_req, .dl_addr, .dl_data, .dl_we16, .dl_busy
	);

	// ---- port 1: the SH-2's program ----
	logic             a1_req, a1_busy, a1_valid;
	logic [25:0]      a1_addr;
	logic [8*GB-1:0]  a1_rdata;
	logic             c1_req, c1_valid;
	logic [25:0]      c1_addr;
	logic [8*GB-1:0]  c1_rdata;
	logic [31:0]      cpu_rom_le;

	sdram_port_cdc #(.GB(GB)) u_phy1 (
		.clk, .reset, .clk_sdram, .reset_sdram,
		.port_addr(p1_addr), .port_wrl(p1_wrl), .port_wrh(p1_wrh), .port_din(p1_din), .port_dout(p1_dout),
		.port_req(p1_req), .port_ack(p1_ack),
		.req(a1_req), .we(1'b0), .we16(1'b0), .addr(a1_addr), .wdata(16'd0),
		.busy(a1_busy), .valid(a1_valid), .rdata(a1_rdata)
	);
	mlc_port_arbiter #(.N(1), .GB(GB)) u_arb1 (
		.clk, .reset,
		.phy_req(a1_req), .phy_we(), .phy_we16(), .phy_addr(a1_addr), .phy_wdata(),
		.phy_busy(a1_busy), .phy_valid(a1_valid), .phy_rdata(a1_rdata),
		.c_req(c1_req), .c_addr(c1_addr), .c_valid(c1_valid), .c_rdata(c1_rdata),
		.dl_req(1'b0), .dl_addr('0), .dl_data('0), .dl_we16(1'b0), .dl_busy()
	);
	// the bridge packs little-endian words; the SH-2's region is big-endian: byte 0 is the MSB.
	// The DE156 has no cache of its own here: an 8 KB one in front of the port (mlc_rom_cache)
	generate if (CPU_LE) begin : g_rom_cache
		mlc_rom_cache #(.LINES(512)) u_cpu_cache (
			.clk, .reset, .inval(ioctl_download || ldr_busy),
			.req(cpu_rom_req), .addr(MAINCPU_BASE + {6'd0, cpu_rom_addr}),
			.valid(cpu_rom_valid), .data(cpu_rom_le),
			.g_req(c1_req), .g_addr(c1_addr), .g_valid(c1_valid), .g_data(c1_rdata)
		);
	end else begin : g_rom_bridge
		sdram_narrow_bridge #(.WORD_BYTES(4), .GB(GB)) u_cpu_bridge (
			.clk, .reset, .inval(ioctl_download || ldr_busy),
			.req(cpu_rom_req), .addr(MAINCPU_BASE + {6'd0, cpu_rom_addr}),
			.valid(cpu_rom_valid), .data(cpu_rom_le),
			.g_req(c1_req), .g_addr(c1_addr), .g_valid(c1_valid), .g_data(c1_rdata)
		);
	end endgenerate
	assign cpu_rom_data = CPU_LE ? cpu_rom_le : {cpu_rom_le[7:0], cpu_rom_le[15:8], cpu_rom_le[23:16], cpu_rom_le[31:24]};

	// ---- port 2: the YMZ280B's samples ----
	logic             a2_req, a2_busy, a2_valid;
	logic [25:0]      a2_addr;
	logic [8*GB-1:0]  a2_rdata;

	sdram_port_cdc #(.GB(GB)) u_phy2 (
		.clk, .reset, .clk_sdram, .reset_sdram,
		.port_addr(p2_addr), .port_wrl(p2_wrl), .port_wrh(p2_wrh), .port_din(p2_din), .port_dout(p2_dout),
		.port_req(p2_req), .port_ack(p2_ack),
		.req(a2_req), .we(1'b0), .we16(1'b0), .addr(a2_addr), .wdata(16'd0),
		.busy(a2_busy), .valid(a2_valid), .rdata(a2_rdata)
	);
	mlc_port_arbiter #(.N(1), .GB(GB)) u_arb2 (
		.clk, .reset,
		.phy_req(a2_req), .phy_we(), .phy_we16(), .phy_addr(a2_addr), .phy_wdata(),
		.phy_busy(a2_busy), .phy_valid(a2_valid), .phy_rdata(a2_rdata),
		.c_req(ymz_req), .c_addr(ymz_addr), .c_valid(ymz_valid), .c_rdata(ymz_rdata),
		.dl_req(1'b0), .dl_addr('0), .dl_data('0), .dl_we16(1'b0), .dl_busy()
	);

	// ---- the download: ioctl bytes, or the DDR3 copy; gfx1 moved into its unit layout ----
	logic [25:0]  io_xf_addr;
	mlc_dl_xform u_xf_io (.layout(gfx_layout), .frac8(gfx_frac8), .de156(CPU_LE), .in_addr(ioctl_addr[25:0]), .out_addr(io_xf_addr));

	logic         io_req, io_we16, io_busy;
	logic [25:0]  io_addr;
	logic [15:0]  io_data;
	sdram_download u_download (
		.clk, .reset,
		.ioctl_download, .ioctl_index, .ioctl_wr, .ioctl_addr({1'b0, io_xf_addr}), .ioctl_dout,
		.ioctl_wait,
		.dl_req(io_req), .dl_addr(io_addr), .dl_data(io_data), .dl_we16(io_we16), .dl_busy(io_busy)
	);

	logic         ddr_req, ddr_busy, ddr_valid;
	logic [27:0]  ddr_addr;
	logic [63:0]  ddr_rdata;
	logic [25:0]  raw_addr, xf_addr, ld_addr;
	logic [15:0]  raw_word, ld_data;
	logic         ld_req, ld_we16, ld_busy;

	ddram_phy u_ddr (
		.clk, .reset,
		.DDRAM_BUSY, .DDRAM_BURSTCNT, .DDRAM_ADDR, .DDRAM_DOUT, .DDRAM_DOUT_READY, .DDRAM_RD, .DDRAM_DIN, .DDRAM_BE, .DDRAM_WE,
		.req(ddr_req), .we(1'b0), .addr(ddr_addr), .wdata(8'd0), .busy(ddr_busy), .valid(ddr_valid), .rdata(ddr_rdata)
	);
	mlc_dl_xform u_xf_ld (.layout(gfx_layout), .frac8(gfx_frac8), .de156(CPU_LE), .in_addr(raw_addr), .out_addr(xf_addr));
	rom_loader u_loader (
		.clk, .reset, .length(ldr_length), .start(ldr_start), .busy(ldr_busy),
		.ddr_req, .ddr_addr, .ddr_busy, .ddr_valid, .ddr_rdata,
		.raw_addr, .raw_word, .xf_addr, .xf_data(raw_word),
		.dl_req(ld_req), .dl_addr(ld_addr), .dl_data(ld_data), .dl_we16(ld_we16), .dl_busy(ld_busy)
	);

	// the loader has the write port while it runs; the byte path otherwise
	assign dl_req  = ldr_busy ? ld_req  : io_req;
	assign dl_addr = ldr_busy ? ld_addr : io_addr;
	assign dl_data = ldr_busy ? ld_data : io_data;
	assign dl_we16 = ldr_busy ? ld_we16 : io_we16;
	assign io_busy = ldr_busy ? 1'b0 : dl_busy;
	assign ld_busy = ldr_busy ? dl_busy : 1'b0;

endmodule
