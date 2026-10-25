// SPDX-License-Identifier: GPL-3.0-or-later
// MiSTer framework glue for the Data East MLC (MAME deco_mlc.cpp): HPS, the PLL, inputs, the
// .mra's mod byte and EEPROM image, the fast ROM load, and the video output path. The board
// itself is rtl/mlc_top.sv.
//
// Inputs follow deco_mlc.cpp's INPUT_PORTS (lines 373-407): one 32-bit word at 0x400000,
// active low. hps_io's joystick bits: 0 right, 1 left, 2 down, 3 up, 4-9 the .mra's buttons,
// 10 Start, 11 Coin, 12 Pause (the .mra <buttons> list, which governs).
//
// Video: 442 x 274 at 7 MHz from the 84 MHz clk_sys, through CRT Adjust (rtl/video/crt_chain.sv),
// sys/arcade_video.v (scandoubler, gamma, scanline FX) and sys/video_freak.sv (aspect, integer
// scale, crop), with rtl/video/screen_rotate_two.sv tapping the output for HDMI rotation. The
// aspect is 4:3. Flip is the core's own, so every output shows it.
//
// SDRAM_CLK's phase is estimated, not swept (rtl/pll/pll_0002.v, docs/HACKS.md).
module emu
(
	`include "sys/emu_ports.vh"
);

///////// Default values for ports not used in this core /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

// Silent until Phase 3 (the YMZ280B)
assign AUDIO_S   = 1;
assign AUDIO_MIX = status[80:79];

assign LED_DISK = 0;
assign LED_POWER = 0;
assign BUTTONS = 0;

//////////////////////////////////////////////////////////////////

`include "build_id.v"
// The Debug page is shown by the DecoMLC_stp revision only (DEBUG_ISSP), hidden by the release
// build through status_menumask bit 1.
`ifdef DEBUG_ISSP
localparam DEBUG_MENU_HIDE = 1'b0;
`else
localparam DEBUG_MENU_HIDE = 1'b1;
`endif
wire debug_menu_hide = DEBUG_MENU_HIDE;

localparam CONF_STR = {
	"DecoMLC;;",
	"-;",
	"H5O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"H5O[48:47],Orientation,Auto,Off,CW,CCW;",
	"O[49],Flip Screen,Off,On;",
	"H5O[93:91],Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer,HV-Integer;",
	"H5O[94],Vertical crop,Disabled,216p (5x);",
	"H5O[99:95],Crop offset,0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H5O[46:44],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"H3O[78],Autosave Hiscores,Off,On;",
	"O[80:79],Audio Mix,None,25%,50%,Mono;",
	"O[64],CRT Adjust,Off,On;",
	"H2O[71:65],CRT H-Position,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,+32,+33,+34,+35,+36,+37,+38,+39,+40,+41,+42,+43,+44,+45,+46,+47,+48,-48,-47,-46,-45,-44,-43,-42,-41,-40,-39,-38,-37,-36,-35,-34,-33,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H2O[77:72],CRT V-Shift,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H2O[85:81],CRT H-Size,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H2O[89:86],CRT V-Size,0,+1,+2,+3,+4,+5,+6,+7,-7,-6,-5,-4,-3,-2,-1;",
	"H2O[90],CRT V-Size Mode,PVM,Cabinet;",
	"-;",
	"DIP;",
	"-;",
	"H1P1,Debug;",
	"H1P1-;",
	"H1P1O[40],Sprites,On,Off;",
	"-;",
	"R[0],Reset;",
	// Agrees with the .mra <buttons> positions: six button slots, then Start, Coin, Pause
	"J1,Button 1,Button 2,Button 3,Button 4,Button 5,Button 6,Start,Coin,Pause;",
	"V,v",`BUILD_DATE
};

wire         forced_scandoubler;
wire         direct_video;
wire         video_rotated;
wire         ioctl_upload, ioctl_upload_req;
wire  [7:0]  ioctl_din;
wire         vga_de_raw;
wire  [21:0] gamma_bus;
wire  [1:0]  buttons;
wire [127:0] status;
wire  [10:0] ps2_key;
wire [31:0]  joystick_0, joystick_1;

wire         ioctl_download;
wire [15:0]  ioctl_index;
wire         ioctl_wr;
wire [26:0]  ioctl_addr;
wire  [7:0]  ioctl_dout;
wire         ioctl_wait;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(gamma_bus),

	.forced_scandoubler(forced_scandoubler),

	.buttons(buttons),
	.status(status),
	// H1 the Debug page; H2 CRT Adjust's settings while it is off; H3 hiscore autosave unless
	// the .mra carried hiscore data; H5 the HDMI scaler's options under direct video
	.status_menumask({direct_video, 1'b0, ~hs_configured, ~status[64], debug_menu_hide, status[5]}),
	.direct_video(direct_video),
	.video_rotated(video_rotated),

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait),

	// hiscore save and restore (rtl/hiscore.v): index 3 the .mra's config, index 4 the dump
	.ioctl_upload(ioctl_upload),
	.ioctl_upload_req(ioctl_upload_req),
	.ioctl_upload_index(8'd4),
	.ioctl_din(ioctl_din),
	.ioctl_rd(),

	.ps2_key(ps2_key)
);

///////////////////////   CLOCKS   ///////////////////////////////

// clk_sys 84 MHz, SDRAM_CLK the same shifted, clk_cpu 42 MHz (rtl/pll/pll_0002.v;
// docs/ROADMAP.md, Clocks). The SDRAM_CLK pin is driven from the PLL directly; mlc_top's
// SDRAM_CLK output is the simulation placeholder.
wire clk_sys, clk_sdram_shifted, clk_cpu, pll_locked;
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.outclk_1(clk_sdram_shifted),
	.outclk_2(clk_cpu),
	.locked(pll_locked)
);

assign SDRAM_CLK = clk_sdram_shifted;

// The game is held while the ROM arrives and while the loader copies it; the raster and the
// memory backend run from the PLL lock alone (a CRT keeps its sync through a load, and the
// loader writes SDRAM through the backend).
wire reset       = RESET | status[0] | buttons[1] | ~pll_locked | ioctl_download | ldr_busy;
wire video_reset = ~pll_locked;

///////////////////////   INPUTS   ////////////////////////////////

// deco_mlc.cpp INPUT_PORTS_START( mlc ), active low (hence the `~`): P1 up, down, left, right,
// buttons 1-3, start in bits 0-7; P2 in 8-15; coin 1, 2 at 16, 17; service 1 at 18; test at 19;
// coin 3, 4 at 20, 21; service 2 at 22; the EEPROM's DO at 23 (the core supplies it); P1 and
// P2 button 4 at 24 and 27.
// MAME's default keys alongside the pads (rtl/mame_keys.sv).
wire [31:0] key0, key1;
wire [1:0]  svc_coin;
mame_keys #(.BUTTONS(4)) u_mame_keys (
	.clk(clk_sys), .ps2_key(ps2_key), .key0(key0), .key1(key1), .svc_coin(svc_coin)
);
wire [31:0] joy0 = joystick_0 | key0;
wire [31:0] joy1 = joystick_1 | key1;

wire [31:0] inputs_n = {
	4'b1111,                                   // 31-28 unknown
	~joy1[7],                                  // 27 P2 button 4
	2'b11,                                     // 26-25 unknown
	~joy0[7],                                  // 24 P1 button 4
	1'b1,                                      // 23 EEPROM DO (mlc_core)
	~svc_coin[1],                              // 22 service 2
	2'b11,                                     // 21-20 coin 4, 3
	~key0[13],                                 // 19 test (F2)
	~svc_coin[0],                              // 18 service 1
	~joy1[11], ~joy0[11],                      // 17-16 coin 2, 1
	~joy1[10], ~joy1[6], ~joy1[5], ~joy1[4],   // 15-12 P2 start, buttons 3, 2, 1
	~joy1[0], ~joy1[1], ~joy1[2], ~joy1[3],    // 11-8  P2 right, left, down, up
	~joy0[10], ~joy0[6], ~joy0[5], ~joy0[4],   // 7-4   P1 start, buttons 3, 2, 1
	~joy0[0], ~joy0[1], ~joy0[2], ~joy0[3]     // 3-0   P1 right, left, down, up
};

// .mra mod byte, <rom index="1">: bit 0 = a DE156 configuration (0 the SH-2), bits 2:1 =
// orientation. Latched, not reset: MiSTer holds reset through the download.
reg [7:0] mod_byte = 8'd0;
always @(posedge clk_sys) begin
	if (ioctl_wr && (ioctl_index == 16'd1) && (ioctl_addr == 27'd0)) mod_byte <= ioctl_dout;
end

// The factory EEPROM image, <rom index="2">: 128 bytes, big-endian words (ROM_REGION16_BE),
// into the 93C45 through its dump port as the pairs arrive.
reg        ee_we = 1'b0;
reg [5:0]  ee_addr;
reg [15:0] ee_din;
reg [7:0]  ee_hi;
always @(posedge clk_sys) begin
	ee_we <= 1'b0;
	if (ioctl_wr && (ioctl_index == 16'd2) && !ioctl_addr[26:7]) begin
		if (!ioctl_addr[0]) ee_hi <= ioctl_dout;
		else begin
			ee_we   <= 1'b1;
			ee_addr <= ioctl_addr[6:1];
			ee_din  <= {ee_hi, ioctl_dout};
		end
	end
end

// Pause: the .mra's Pause button (bit 12), an edge-triggered toggle. The CPU is also held
// while hiscore touches main RAM (it borrows the CPU's port to write).
wire pause_btn = joy0[12] | joy1[12];
reg  pause_btn_d = 1'b0, pause = 1'b0;
always @(posedge clk_sys) begin
	pause_btn_d <= pause_btn;
	if (reset)                         pause <= 1'b0;
	else if (pause_btn & ~pause_btn_d) pause <= ~pause;
end
wire pause_core = pause | hs_pause;

// DIP switches arrive as an ioctl download with index 254 (mra_loader.cpp arcade_sw_send). The
// board has none; the .mra's only switch is the core's fake Flip Screen, bit 0.
reg [63:0] dip_sw = 64'd0;
always @(posedge clk_sys) begin
	if (ioctl_wr && (ioctl_index == 16'd254) && !ioctl_addr[24:3])
		dip_sw[{ioctl_addr[2:0], 3'b000} +: 8] <= ioctl_dout;
end

// Flip screen: one mechanism in the video block (rtl/video/mlc_video.sv) for every output, from
// the OSD or the fake DIP; both together flip twice.
wire flip_screen = status[49] ^ dip_sw[0];

// ---- MAME hiscore.dat (rtl/hiscore.v) ----
// The .mra carries the entry (main RAM 0x108909, 0x4e bytes) as index 3; index 4 is the dump.
// HS_ADDRESSWIDTH 17: main RAM is 128 KB at 0x100000, so the entry's low 17 bits are the offset.
wire        hs_configured, hs_pause, hs_write, hs_read;
wire [16:0] hs_address;
wire  [7:0] hs_data_in, hs_data_out;
hiscore #(
	.HS_ADDRESSWIDTH(17),
	.HS_SCOREWIDTH(8),
	.CFG_ADDRESSWIDTH(2),
	.CFG_LENGTHWIDTH(1)
) u_hiscore (
	.clk(clk_sys),
	.reset(reset),
	.paused(pause_core),
	.autosave(status[78]),
	.ioctl_upload(ioctl_upload),
	.ioctl_upload_req(ioctl_upload_req),
	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr[24:0]),
	.ioctl_index(ioctl_index[7:0]),
	.OSD_STATUS(OSD_STATUS),
	.data_from_hps(ioctl_dout),
	.data_from_ram(hs_data_out),
	.ram_address(hs_address),
	.data_to_hps(ioctl_din),
	.data_to_ram(hs_data_in),
	.ram_write(hs_write),
	.ram_intent_read(hs_read),
	.ram_intent_write(),
	.pause_cpu(hs_pause),
	.configured(hs_configured)
);



///////////////////////   THE BOARD   ////////////////////////////

wire        ce_pix, hblank, vblank, hsync, vsync, vbl_start, frame_top, line_done, ovr_ev, ldr_busy;
wire [7:0]  r8, g8, b8, volume;

mlc_top mlc_top (
	.clk(clk_sys), .clk_cpu(clk_cpu), .reset(reset), .video_reset(video_reset), .init(~pll_locked),
	.pause(pause_core),

	.SDRAM_A(SDRAM_A), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
	.SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE),
	.SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
	.SDRAM_CLK(),              // the pin is the PLL's shifted clock, above
	.SDRAM_CKE(SDRAM_CKE), .SDRAM_DQ(SDRAM_DQ),

	.ioctl_download(ioctl_download), .ioctl_index(ioctl_index), .ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout), .ioctl_wait(ioctl_wait),

	.DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(ldr_DDRAM_BURSTCNT), .DDRAM_ADDR(ldr_DDRAM_ADDR),
	.DDRAM_DOUT(DDRAM_DOUT), .DDRAM_DOUT_READY(DDRAM_DOUT_READY), .DDRAM_RD(ldr_DDRAM_RD),
	.DDRAM_DIN(ldr_DDRAM_DIN), .DDRAM_BE(ldr_DDRAM_BE), .DDRAM_WE(ldr_DDRAM_WE),
	.ldr_start(ldr_start), .ldr_length(28'h1F80000), .ldr_busy(ldr_busy),   // mlc_video_pkg ROM_END

	.inputs_n(inputs_n), .ee_we(ee_we), .ee_addr(ee_addr), .ee_din(ee_din),
	.flip(flip_screen),
	.hs_addr(hs_address), .hs_din(hs_data_in), .hs_dout(hs_data_out), .hs_we(hs_write),

	.ce_pix(ce_pix), .r(r8), .g(g8), .b(b8), .hblank(hblank), .vblank(vblank), .hs(hsync), .vs(vsync),
	.vbl_start(vbl_start), .frame_top(frame_top), .volume(volume), .snd_l(AUDIO_L), .snd_r(AUDIO_R), .line_done(line_done), .ovr_ev(ovr_ev),
	.dbg_clear(dbg_clear), .dbg(core_dbg),
	.dbg_rom_valid(dbg_rom_valid), .dbg_rom_addr(dbg_rom_addr), .dbg_rom_data(dbg_rom_data)
);
wire        dbg_rom_valid;
wire [19:0] dbg_rom_addr;
wire [31:0] dbg_rom_data;

// ---- the _stp revision's probe (scripts/read_issp.tcl, fields_C) ----
wire [111:0] core_dbg;
wire         dbg_clear;
`ifdef DEBUG_ISSP
wire [7:0] issp_src;
assign dbg_clear = issp_src[0];
issp_probe #(.INSTANCE_ID("C"), .PROBE_W(128), .SOURCE_W(8)) u_issp_core (
	.clk(clk_sys),
	.probe({pll_locked, ldr_busy, ldr_done, dl_seen_wr, ioctl_download, reset, video_reset, pause,
	        mod_byte, core_dbg}),
	.source(issp_src)
);
// instance R: the program fetches as the CPU receives them. issp_src_r selects fetch N (0-255
// after reset); the probe holds N's address and data and the data of fetches 0 and 1
wire [7:0] issp_src_r;
reg  [7:0]  r_n;
reg  [19:0] r_addr;
reg  [31:0] r_data, r_d0, r_d1;
always @(posedge clk_sys) begin
	if (reset) r_n <= 8'd0;
	else if (dbg_rom_valid) begin
		if (r_n == 8'd0) r_d0 <= dbg_rom_data;
		if (r_n == 8'd1) r_d1 <= dbg_rom_data;
		if (r_n == issp_src_r) begin r_addr <= dbg_rom_addr; r_data <= dbg_rom_data; end
		if (~&r_n) r_n <= r_n + 8'd1;
	end
end
issp_probe #(.INSTANCE_ID("R"), .PROBE_W(128), .SOURCE_W(8)) u_issp_rom (
	.clk(clk_sys),
	.probe({4'd0, r_n, r_addr, r_data, r_d1, r_d0}),
	.source(issp_src_r)
);
`else
assign dbg_clear = 1'b0;
`endif


// ---- Fast ROM loading (rtl/memory/rom_loader.sv) ----
// The .mra's <rom index="0"> carries address="0x30000000": the HPS puts the image in DDR3 and
// the core sees ioctl_download assert and deassert with no ioctl_wr for index 0. The copy is
// started when reset is released after such a download, once per download; an .mra that
// streams bytes (dl_seen_wr) has already filled SDRAM through mlc_sdram_top's byte path.
// (Mechanism from srg320/Arcade-PsikyoSH2_MiSTer, by way of the sibling cores.)
reg  dl_seen_wr  = 1'b0;
reg  dl_active_d = 1'b0;
reg  ldr_pending = 1'b0;
reg  ldr_start   = 1'b0;
reg  ldr_done    = 1'b0;
wire dl_index0 = ioctl_download && (ioctl_index == 16'd0);
wire reset_nold = RESET | status[0] | buttons[1] | ~pll_locked | ioctl_download;
always @(posedge clk_sys) begin
	ldr_start   <= 1'b0;
	dl_active_d <= dl_index0;
	if (dl_index0 && !dl_active_d)  dl_seen_wr <= 1'b0;
	else if (dl_index0 && ioctl_wr) dl_seen_wr <= 1'b1;
	if (dl_index0 && !dl_active_d)  ldr_done   <= 1'b0;

	if (reset_nold) begin
		ldr_pending <= 1'b1;
	end else if (ldr_pending && !ioctl_download && !ldr_busy) begin
		ldr_pending <= 1'b0;
		if (!dl_seen_wr && !ldr_done) begin
			ldr_start <= 1'b1;
			ldr_done  <= 1'b1;
		end
	end
end

///////////////////////   VIDEO   ///////////////////////////////

// Orientation "Auto" follows the set's own (mod byte bits 2:1: 0 ROT0, 1 ROT90, 2 ROT270); the
// aspect is 4:3, 3:4 when rotated, whatever the pixel count. ARY 0 means "stretch".
wire [1:0]  game_rot   = mod_byte[2:1];
wire [1:0]  rot_sel    = status[48:47];   // Auto, Off, CW, CCW
wire        rotate_en  = (rot_sel == 2'd0) ? (game_rot != 2'd0) : (rot_sel != 2'd1);
wire        rotate_ccw = (rot_sel == 2'd0) ? (game_rot == 2'd2) : (rot_sel == 2'd3);
wire [1:0]  ar         = status[122:121];
wire [11:0] base_arx   = (!ar) ? (rotate_en ? 12'd3 : 12'd4) : 12'({ar} - 2'd1);
wire [11:0] base_ary   = (!ar) ? (rotate_en ? 12'd4 : 12'd3) : 12'd0;

// ---- CRT Adjust (rtl/video/crt_chain.sv) ----
// Moves the picture inside a line buffer with the sync left native, so a CRT keeps its lock;
// HDMI follows. H-Size and V-Size act at 15 kHz only. The H-Position list has 97 entries, so its
// negative half wraps at 97; V-Shift's 64 are two's complement; V-Size's 15 wrap at 15.
wire crt_adj_on   = status[64];
wire crt_scale_en = ~(forced_scandoubler | |status[46:44]);
wire  [6:0] crt_hpos_idx = status[71:65];
wire signed [8:0] crt_hoffset = (crt_hpos_idx <= 7'd48) ? $signed({2'b00, crt_hpos_idx})
                                                         : $signed({2'b00, crt_hpos_idx}) - 9'sd97;
wire signed [5:0] crt_voffset  = $signed(status[77:72]);
wire signed [4:0] crt_hsize    = $signed(status[85:81]);
wire  [3:0] crt_vsz_idx  = status[89:86];
wire signed [3:0] crt_vsz_step = (crt_vsz_idx <= 4'd7) ? $signed(crt_vsz_idx) : $signed(crt_vsz_idx - 4'd15);

wire       crt_ce;
wire [7:0] crt_r, crt_g, crt_b;
wire       crt_hs, crt_vs, crt_hb, crt_vb;

crt_chain #(.HTOTAL(442), .VTOTAL(274), .ACTIVE_W(320), .RD_BASE(48)) crt_chain   // 12 clk a pixel, x4
(
	.clk(clk_sys),
	.ce_pix(ce_pix),
	.active(crt_adj_on),
	.scale_en(crt_scale_en),
	.hoffset(crt_hoffset),
	.voffset(crt_voffset),
	.hsize(crt_hsize),
	.vsize_step(crt_vsz_step),
	.vsize_cabinet(status[90]),
	.r_in(r8), .g_in(g8), .b_in(b8),
	.hs_in(hsync), .vs_in(vsync), .hb_in(hblank), .vb_in(vblank),
	.ce_out(crt_ce),
	.r_out(crt_r), .g_out(crt_g), .b_out(crt_b),
	.hs_out(crt_hs), .vs_out(crt_vs), .hb_out(crt_hb), .vb_out(crt_vb)
);

arcade_video #(.WIDTH(320), .DW(24), .GAMMA(1)) arcade_video
(
	.clk_video(clk_sys),
	.ce_pix(crt_ce),

	.RGB_in({crt_r, crt_g, crt_b}),
	.HBlank(crt_hb),
	.VBlank(crt_vb),
	.HSync(crt_hs),
	.VSync(crt_vs),

	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.VGA_R(VGA_R),
	.VGA_G(VGA_G),
	.VGA_B(VGA_B),
	.VGA_HS(VGA_HS),
	.VGA_VS(VGA_VS),
	.VGA_DE(vga_de_raw),
	.VGA_SL(VGA_SL),

	.fx(status[46:44]),
	.forced_scandoubler(forced_scandoubler),
	.gamma_bus(gamma_bus)
);

video_freak video_freak
(
	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.VGA_VS(VGA_VS),
	.HDMI_WIDTH(HDMI_WIDTH),
	.HDMI_HEIGHT(HDMI_HEIGHT),
	.VGA_DE(VGA_DE),
	.VIDEO_ARX(VIDEO_ARX),
	.VIDEO_ARY(VIDEO_ARY),

	.VGA_DE_IN(vga_de_raw),
	.ARX(base_arx),
	.ARY(base_ary),
	.CROP_SIZE(status[94] ? 12'd216 : 12'd0),   // 216 of the 240 lines: exactly 5x on 1080
	.CROP_OFF(status[99:95]),
	.SCALE(status[93:91])
);

assign FB_FORCE_BLANK = 0;

// ---- HDMI rotation through the HPS framebuffer (rtl/video/screen_rotate_two.sv) ----
// A tap: VGA_* still drive the analog output; this writes a rotated copy into DDR3 for HDMI.
// It owns DDR3 except while the ROM loader copies (the core in reset, nothing to show); its
// DDRAM_BUSY is held then so it stalls rather than counting phantom writes.
wire        rot_DDRAM_CLK;
wire [7:0]  rot_DDRAM_BURSTCNT, rot_DDRAM_BE;
wire [28:0] rot_DDRAM_ADDR;
wire [63:0] rot_DDRAM_DIN;
wire        rot_DDRAM_WE, rot_DDRAM_RD;
wire [7:0]  ldr_DDRAM_BURSTCNT, ldr_DDRAM_BE;
wire [28:0] ldr_DDRAM_ADDR;
wire [63:0] ldr_DDRAM_DIN;
wire        ldr_DDRAM_WE, ldr_DDRAM_RD;

screen_rotate_two screen_rotate_two
(
	.CLK_VIDEO(CLK_VIDEO), .CE_PIXEL(CE_PIXEL),
	.VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B), .VGA_HS(VGA_HS), .VGA_VS(VGA_VS), .VGA_DE(VGA_DE),
	.rotate_ccw(rotate_ccw), .no_rotate(~rotate_en),
	.flip(1'b0),               // flip is the core's (flip_screen), for every output
	.two_screen(1'b0),
	.video_rotated(video_rotated),
	.FB_EN(FB_EN), .FB_FORMAT(FB_FORMAT), .FB_WIDTH(FB_WIDTH), .FB_HEIGHT(FB_HEIGHT),
	.FB_BASE(FB_BASE), .FB_STRIDE(FB_STRIDE), .FB_VBL(FB_VBL), .FB_LL(FB_LL),
	.DDRAM_CLK(rot_DDRAM_CLK),
	.DDRAM_BUSY(DDRAM_BUSY | ldr_busy),
	.DDRAM_BURSTCNT(rot_DDRAM_BURSTCNT), .DDRAM_ADDR(rot_DDRAM_ADDR), .DDRAM_DIN(rot_DDRAM_DIN),
	.DDRAM_BE(rot_DDRAM_BE), .DDRAM_WE(rot_DDRAM_WE), .DDRAM_RD(rot_DDRAM_RD)
);

assign DDRAM_CLK      = ldr_busy ? clk_sys            : rot_DDRAM_CLK;
assign DDRAM_BURSTCNT = ldr_busy ? ldr_DDRAM_BURSTCNT : rot_DDRAM_BURSTCNT;
assign DDRAM_ADDR     = ldr_busy ? ldr_DDRAM_ADDR     : rot_DDRAM_ADDR;
assign DDRAM_DIN      = ldr_busy ? ldr_DDRAM_DIN      : rot_DDRAM_DIN;
assign DDRAM_BE       = ldr_busy ? ldr_DDRAM_BE       : rot_DDRAM_BE;
assign DDRAM_WE       = ldr_busy ? ldr_DDRAM_WE       : rot_DDRAM_WE;
assign DDRAM_RD       = ldr_busy ? ldr_DDRAM_RD       : rot_DDRAM_RD;

reg  [26:0] act_cnt;
always @(posedge clk_sys) act_cnt <= act_cnt + 1'd1;
assign LED_USER = act_cnt[26] ? act_cnt[25:18] > act_cnt[7:0] : act_cnt[25:18] <= act_cnt[7:0];

endmodule
