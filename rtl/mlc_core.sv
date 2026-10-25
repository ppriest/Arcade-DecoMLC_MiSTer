// SPDX-License-Identifier: GPL-3.0-or-later
// The MLC board without its memory backend: the SH7604 on its own 42 MHz clock behind
// jtsh7604's req/ack seam, the bus glue decoding deco_mlc.cpp's avengrgs_map (lines 304-325)
// onto main RAM, the video block's RAMs and registers, the inputs, the 93C45 and the volume
// byte, the scanline interrupt, the video block, and the YMZ280B with its unit buffer. The
// program ROM, the sprite units and the sample units come through mlc_sdram_top's ports
// (rtl/mlc_top.sv). docs/HARDWARE_NOTES.md has every
// address with its driver line.
module mlc_core
	import mlc_video_pkg::*;
(
	input  logic         clk,             // 84 MHz: everything but the CPU
	input  logic         clk_cpu,         // 42 MHz, the same PLL: the SH7604 at CE 1 in 2
	input  logic         reset,           // the game: CPU, RAMs' owners, registers
	input  logic         video_reset,     // the raster alone, so sync runs through a load
	input  logic         pause,           // holds the CPU (its DMAC with it)

	// program ROM (mlc_sdram_top: a pulse, the address held until valid, big-endian words)
	output logic         cpu_rom_req,
	output logic [19:0]  cpu_rom_addr,
	input  logic         cpu_rom_valid,
	input  logic [31:0]  cpu_rom_data,

	// sprite units (mlc_sdram_top's two slots)
	output logic [1:0]   spr_req,
	output logic [51:0]  spr_addr,
	input  logic [1:0]   spr_valid,
	input  logic [127:0] spr_rdata,

	// YMZ280B sample units (mlc_sdram_top port 2)
	output logic         ymz_req,
	output logic [25:0]  ymz_addr,
	input  logic         ymz_valid,
	input  logic [127:0] ymz_rdata,

	// the 0x400000 word as the board reads it, active low, without bit 23 (the EEPROM's DO)
	input  logic [31:0]  inputs_n,

	// the factory EEPROM image, 64 words
	input  logic         ee_we,
	input  logic [5:0]   ee_addr,
	input  logic [15:0]  ee_din,

	input  logic         parity_in,       // frame parity for auto-flicker, from the top
	input  logic         flip,            // flip screen (OSD or the .mra's fake DIP)

	// hiscore (rtl/hiscore.v): a byte address in main RAM. Reads use port B; writes borrow
	// the CPU's port A, which hiscore does only with the CPU paused
	input  logic [16:0]  hs_addr,
	input  logic [7:0]   hs_din,
	output logic [7:0]   hs_dout,
	input  logic         hs_we,

	// video
	output logic         ce_pix,
	output logic [7:0]   r, g, b,
	output logic         hblank, vblank, hs, vs,
	output logic         vbl_start,
	output logic         frame_top,       // the first clock of line 0: where MAME starts the CPU

	output logic [7:0]   volume,          // the master volume byte (0x500000, bits 7:0)
	output logic [15:0]  snd_l, snd_r,    // signed, after the volume byte (mlc 189-193)
	output logic         line_done,
	output logic         ovr_ev,

	// probe bus for the _stp revision's ISSP (DecoMLC.sv, read_issp.tcl fields_C); counters
	// saturate, dbg_clear zeroes them
	input  logic         dbg_clear,
	output logic [111:0] dbg
);

	// ------------------------------------------------------------------ the CPU, 42 MHz
	logic        cec = 1'b0;
	always_ff @(posedge clk_cpu) cec <= ~cec;
	wire ce_r = (cec == 1'b0) && !pause;
	wire ce_f = (cec == 1'b1) && !pause;

	logic [26:0] A;
	logic [31:0] cpu_dout, cpu_din;
	logic        BS_N, CS0_N, CS1_N, CS2_N, CS3_N, RD_WR_N, CE_N, OE_N, RD_N, IVECF_N, RFS, BGR_N, WAIT_N;
	logic [3:0]  WE_N;
	logic        cache_cs, cache_we, cache_rd, cache_wr, cache_ok;
	logic [26:1] cache_addr;
	logic [31:0] cache_din;
	logic [3:0]  cache_dsn;
	logic        irq_pending;
	wire  [3:0]  irl_n = irq_pending ? 4'b1110 : 4'b1111;   // IRL level 1 (mlc 1048)

	jtsh7604 #(
		.UBC_DISABLE(1'b1), .SCI_DISABLE(1'b1), .WDT_DISABLE(1'b1),
		.BUS_AREA_TIMIMG(4'h0), .BUS_SIZE_BYTE_DISABLE(1'b0), .BUS_SIZE_WORD_DISABLE(1'b0),
		.MD_CFG(6'b010100)
	) u_cpu (
		.rst(reset), .clk(clk_cpu), .ce_r(ce_r), .ce_f(ce_f),
		.nmi_n(1'b1), .irl_n(irl_n), .cpu_din(cpu_din),
		.cps3_key1(32'd0), .cps3_key2(32'd0), .cps3_crypt_mode(3'b010), .cps3_region(3'd0),
		.cps3_region_redearth(1'b0), .cache_ok(cache_ok),
		.A(A), .cpu_dout(cpu_dout), .BS_N(BS_N), .CS0_N(CS0_N), .CS1_N(CS1_N), .CS2_N(CS2_N),
		.CS3_N(CS3_N), .RD_WR_N(RD_WR_N), .CE_N(CE_N), .OE_N(OE_N), .WE_N(WE_N), .RD_N(RD_N),
		.IVECF_N(IVECF_N), .RFS(RFS), .BGR_N(BGR_N), .WAIT_N(WAIT_N),
		.cache_cs(cache_cs), .cache_we(cache_we), .cache_rd(cache_rd), .cache_wr(cache_wr),
		.cache_addr(cache_addr), .cache_din(cache_din), .cache_dsn(cache_dsn)
	);

	// ------------------------------------------------------------------ the bus, 84 MHz
	// The wrapper's request (cache_cs with cache_rd/cache_wr, address, data and lane strobes)
	// is registered on the 42 MHz side and held until cache_ok; the glue answers with a level
	// that stays up until the request drops. The board's bus controller decodes A[23:0]; the
	// area bits carry only wait states (HARDWARE_NOTES, Memory map).
	wire [23:0] a24   = {cache_addr[23:2], 2'b00};
	wire [3:0]  be    = ~cache_dsn;                           // be[3] = bits 31:24 = byte 0
	wire is_rom  = (a24 < 24'h100000);
	wire is_ram  = (a24 >= 24'h100000) && (a24 < 24'h120000);
	wire is_irq  = (a24 >= 24'h200000) && (a24 < 24'h200080);
	wire is_clip = (a24 >= 24'h200080) && (a24 < 24'h200100);
	wire is_spr  = (a24 >= 24'h204000) && (a24 < 24'h207000);
	wire is_vram = (a24 >= 24'h280000) && (a24 < 24'h2a0000);
	wire is_pal  = (a24 >= 24'h300000) && (a24 < 24'h308000);
	wire is_in   = (a24 == 24'h400000);
	wire is_in2  = (a24 == 24'h440000) || (a24 == 24'h440004) || (a24 == 24'h440008) || (a24 == 24'h44001c);
	wire is_ee   = (a24 == 24'h500000);
	wire is_ymz  = (a24 == 24'h600000) || (a24 == 24'h600004);

	typedef enum logic [2:0] {B_IDLE, B_ROM, B_READ1, B_YMZ, B_DONE} bstate_t;
	bstate_t bstate;
	logic        served;
	logic [31:0] rdata;
	logic        vbl_toggle;                                   // 0x200070 (mlc 145-152)
	logic [31:0] irq_ram  [0:31];
	logic [31:0] clip_ram [0:31];
	logic [31:0] line_reg;                                     // IRQ word 5
	logic        line_armed;
	logic [7:0]  ee_port;                                      // 0x500000 bits 15:8
	logic        ee_do;
	logic        hpos_zero;                                    // the video block's line start
	assign frame_top = ce_pix && hpos_zero && (vpos == 9'd0);

	assign cache_ok = served && cache_cs;
	logic served_d;                                            // the bench's trace: served's rise
	always_ff @(posedge clk) served_d <= served;

	logic [31:0] d_nacc;
	logic [15:0] d_nirq, d_nrom, d_nframe;
	logic [23:0] d_last;
	logic        irq_pending_d;
	always_ff @(posedge clk) begin
		irq_pending_d <= irq_pending;
		if (dbg_clear) begin
			d_nacc <= '0; d_nirq <= '0; d_nrom <= '0; d_nframe <= '0;
		end else begin
			if (served && !served_d && ~&d_nacc) begin d_nacc <= d_nacc + 1'd1; d_last <= a24; end
			if (irq_pending && !irq_pending_d && ~&d_nirq) d_nirq <= d_nirq + 1'd1;
			if (cpu_rom_valid && ~&d_nrom) d_nrom <= d_nrom + 1'd1;
			if (vbl_start && ~&d_nframe) d_nframe <= d_nframe + 1'd1;
		end
	end
	assign dbg = {reset, cache_cs, served, irq_pending, 1'b0, bstate,   // 111:104
	              d_nframe, d_nrom, d_nirq, d_last, d_nacc};             // 103:0

	// main RAM, 128 KB: four byte RAMs for the lanes; port B free (hiscore, state)
	logic [31:0] ram_q, ram_qb;
	wire         ram_we = (bstate == B_IDLE) && cache_cs && !served && cache_wr && is_ram;
	// big-endian: byte offset k of a word is lane 3 - k
	wire  [1:0]  hs_lane = 2'd3 - hs_addr[1:0];
	logic [1:0]  hs_lane_d;
	always_ff @(posedge clk) hs_lane_d <= hs_lane;
	assign hs_dout = ram_qb[8*hs_lane_d +: 8];
	genvar gk;
	generate
		for (gk = 0; gk < 4; gk++) begin : ram_lane
			mlc_ram #(.W(8), .AW(15)) u_ram (
				.clk,
				.we_a  (hs_we ? (hs_lane == gk[1:0]) : (ram_we && be[gk])),
				.addr_a(hs_we ? hs_addr[16:2] : a24[16:2]),
				.d_a   (hs_we ? hs_din : cache_din[8*gk +: 8]),
				.q_a(ram_q[8*gk +: 8]), .addr_b(hs_addr[16:2]), .q_b(ram_qb[8*gk +: 8])
			);
		end
	endgenerate

	// the video block's CPU-side ports; reg_we comes a clock after the registers above, with
	// the merged word
	logic         list_we, vram_we, pal_we, reg_we;
	logic [31:0]  vram_rdata, reg_word;
	logic [5:0]   reg_addr_r;
	logic [15:0]  list_rdata, pal_rdata;
	logic [8:0]   vpos;

	// ------------------------------------------------------------------ the YMZ280B, 14 MHz
	// 42 MHz / 3 (mlc 579): 1 in 6 of clk, held by pause and while a sample read waits for its
	// unit (mlc_ymz_mem)
	logic        y_a, y_rd, y_cs_n, y_wr_n, y_rd_n;
	logic [7:0]  y_di, ymz_do;
	logic [1:0]  y_ph;
	logic [3:0]  y_cnt;
	logic [2:0]  ymz_div = 3'd0;
	always_ff @(posedge clk) ymz_div <= (ymz_div == 3'd5) ? 3'd0 : ymz_div + 3'd1;
	wire         ymz_ce_raw = (ymz_div == 3'd0);
	logic        ymz_ce, ymz_stall, ymz_moe_n;
	logic [23:0] ymz_ma;
	logic [7:0]  ymz_mdi;
	logic [15:0] ymz_l, ymz_r;

	YMZ280B u_ymz (
		.CLK(clk), .RST_N(!reset), .EN(1'b1), .CE(ymz_ce),
		.A(y_a), .DI(y_di), .DO(ymz_do), .RD_N(y_rd_n), .WR_N(y_wr_n), .CS_N(y_cs_n), .IC_N(!reset),
		.IRQ_N(), .MA(ymz_ma), .MDI(ymz_mdi), .MDO(), .MOE_N(ymz_moe_n), .MWR_N(), .MCE_N(),
		.OUT_L(ymz_l), .OUT_R(ymz_r), .SND_EN(3'b111)
	);

	mlc_ymz_mem u_ymz_mem (
		.clk, .reset, .inval(1'b0),
		.ce_in(ymz_ce_raw && !pause), .ce_out(ymz_ce), .stall(ymz_stall),
		.ma(ymz_ma), .moe_n(ymz_moe_n), .mdi(ymz_mdi),
		.mem_req(ymz_req), .mem_addr(ymz_addr), .mem_valid(ymz_valid), .mem_rdata(ymz_rdata)
	);

	// the volume byte: gain (255 - v) / 255 (mlc 191-192), taken as g * 256/255 ~ (g + g[7]) / 256
	// (docs/HACKS.md)
	wire  [7:0]  vol_g  = 8'd255 - volume;
	wire  [8:0]  vol_g9 = {1'b0, vol_g} + {8'd0, vol_g[7]};
	logic signed [25:0] snd_lm, snd_rm;
	always_ff @(posedge clk) begin
		snd_lm <= $signed(ymz_l) * $signed({1'b0, vol_g9});
		snd_rm <= $signed(ymz_r) * $signed({1'b0, vol_g9});
		snd_l  <= snd_lm[23:8];
		snd_r  <= snd_rm[23:8];
	end

	// DO is pulled up while the chip is not selected (eepromser.cpp 288-291)
	wire  [31:0]  inputs_word = {inputs_n[31:24], ee_port[2] ? ee_do : 1'b1, inputs_n[22:0]};
	wire          start = (bstate == B_IDLE) && cache_cs && !served;

	always_ff @(posedge clk) begin
		if (reset) begin
			bstate      <= B_IDLE;
			served      <= 1'b0;
			cpu_rom_req <= 1'b0;
			vbl_toggle  <= 1'b0;                                   // the first read returns 0 (mlc 145-152)
			line_reg    <= 32'hffffffff;
			line_armed  <= 1'b0;
			irq_pending <= 1'b0;
			ee_port     <= 8'd0;
			volume      <= 8'd0;
			y_cs_n <= 1'b1; y_wr_n <= 1'b1; y_rd_n <= 1'b1;
			list_we <= 1'b0; vram_we <= 1'b0; pal_we <= 1'b0; reg_we <= 1'b0;
		end else begin
			cpu_rom_req <= 1'b0;
			list_we <= 1'b0; vram_we <= 1'b0; pal_we <= 1'b0; reg_we <= 1'b0;
			if (!cache_cs) served <= 1'b0;

			// the scanline interrupt: armed by a write to IRQ word 5, fires at that line's
			// start, held until the CPU takes it (its vector read) or the game acknowledges
			if (line_armed && ce_pix && hpos_zero && (vpos == line_reg[8:0])) begin
				irq_pending <= 1'b1;
				line_armed  <= 1'b0;
			end

			case (bstate)
				B_IDLE: if (start) begin
					if (cache_wr) begin
						// writes complete now (the RAM lanes above, the video ports below)
						if (is_vram) vram_we <= 1'b1;
						if (is_spr)  list_we <= 1'b1;
						if (is_pal)  pal_we  <= 1'b1;
						// synthesis translate_off
						if ((is_spr || is_pal) && be[1:0] != 2'b11)
							$display("mlc_core: a narrower than 16-bit write to %06x (lanes %b) is not supported", a24, be);
						// synthesis translate_on
						if (is_irq) begin
							irq_ram[a24[6:2]] <= merged(irq_ram[a24[6:2]]);
							reg_word          <= merged(irq_ram[a24[6:2]]);
							reg_addr_r        <= {1'b0, a24[6:2]};
							if (a24[6:2] == 5'd4) irq_pending <= 1'b0;                        // mlc 234-236
							if (a24[6:2] == 5'd5) begin                                      // mlc 237-243
								line_reg   <= merged(irq_ram[a24[6:2]]);
								line_armed <= (merged(irq_ram[a24[6:2]]) != 32'hffffffff);
							end
							reg_we <= 1'b1;
						end
						if (is_clip) begin
							clip_ram[a24[6:2]] <= merged(clip_ram[a24[6:2]]);
							reg_word           <= merged(clip_ram[a24[6:2]]);
							reg_addr_r         <= {1'b1, a24[6:2]};
							reg_we <= 1'b1;
						end
						if (is_ee) begin                                                    // mlc 176-196
							if (be[1]) ee_port <= cache_din[15:8];
							if (be[0]) volume  <= cache_din[7:0];
						end
						if (is_ymz && be[3]) begin                                          // mlc 361: lane 31:24
							y_a <= a24[2]; y_di <= cache_din[31:24]; y_rd <= 1'b0; y_ph <= 2'd0;
							bstate <= B_YMZ;
						end else begin
							served <= 1'b1;
							bstate <= B_DONE;
						end
					end else begin
						if (is_rom) begin
							cpu_rom_req  <= 1'b1;
							cpu_rom_addr <= a24[19:0];
							if (a24 == 24'h000100) irq_pending <= 1'b0;   // vector 64 taken (HARDWARE_NOTES, Interrupts)
							bstate <= B_ROM;
						end else if (is_ram || is_vram || is_spr || is_pal) begin
							bstate <= B_READ1;                                           // one clock of RAM latency
						end else if (is_ymz) begin
							y_a <= a24[2]; y_rd <= 1'b1; y_ph <= 2'd0;
							bstate <= B_YMZ;
						end else begin
							// the I/O words answer at once (mlc 123-173, 318-324)
							if (is_irq) begin
								case (a24[6:2])
									5'd0, 5'd1, 5'd31: rdata <= 32'hffffffff;
									5'd28: begin rdata <= vbl_toggle ? 32'hffffffff : 32'h0; vbl_toggle <= ~vbl_toggle; end
									5'd29: rdata <= {23'd0, vpos};
									default: rdata <= irq_ram[a24[6:2]];
								endcase
							end else if (is_clip) rdata <= clip_ram[a24[6:2]];
							else if (is_in)       rdata <= inputs_word;
							else if (is_in2)      rdata <= 32'hffffffff;
							else                  rdata <= 32'h0;
							served <= 1'b1;
							bstate <= B_DONE;
						end
					end
				end

				B_ROM: if (cpu_rom_valid) begin
					rdata  <= cpu_rom_data;
					served <= 1'b1;
					bstate <= B_DONE;
				end

				B_READ1: begin
					if (is_ram)       rdata <= ram_q;
					else if (is_vram) rdata <= vram_rdata;
					else if (is_spr)  rdata <= {16'hffff, list_rdata};                     // mlc 254-280
					else              rdata <= {16'h0000, pal_rdata};
					served <= 1'b1;
					bstate <= B_DONE;
				end

				// the chip's bus: the strobe falls on the clock after a chip enable and stays low for
				// two chip clocks, then high for two before the CPU goes on. An edge on an enable
				// clock is lost (YMZ280B.sv, REG_WR); sim/ymz_tb drives the chip the same way.
				B_YMZ: case (y_ph)
					2'd0: if (ymz_ce_raw) begin
						y_cs_n <= 1'b0; y_wr_n <= y_rd; y_rd_n <= !y_rd; y_cnt <= 4'd0; y_ph <= 2'd1;
					end
					2'd1: begin
						y_cnt <= y_cnt + 4'd1;
						if (y_cnt == 4'd11) begin
							rdata  <= {ymz_do, 24'hffffff};
							y_cs_n <= 1'b1; y_wr_n <= 1'b1; y_rd_n <= 1'b1; y_cnt <= 4'd0; y_ph <= 2'd2;
						end
					end
					default: begin
						y_cnt <= y_cnt + 4'd1;
						if (y_cnt == 4'd11) begin
							served <= 1'b1;
							bstate <= B_DONE;
						end
					end
				endcase

				B_DONE: if (!cache_cs) bstate <= B_IDLE;                                  // the request drops after cache_ok
				default: bstate <= B_IDLE;
			endcase
		end
	end
	assign cpu_din = rdata;

	// COMBINE_DATA: the write's lanes over the register's word
	function automatic logic [31:0] merged(input logic [31:0] old);
		for (int k = 0; k < 4; k++) merged[8*k +: 8] = be[k] ? cache_din[8*k +: 8] : old[8*k +: 8];
	endfunction

	// ------------------------------------------------------------------ the EEPROM, 93C45
	jt9346 #(.AW(6), .DW(16)) u_eeprom (
		.rst(reset), .clk(clk),
		.sclk(ee_port[1]), .sdi(ee_port[0]), .sdo(ee_do), .scs(ee_port[2]),
		.dump_clk(clk), .dump_addr(ee_addr), .dump_we(ee_we), .dump_din(ee_din), .dump_dout(),
		.dump_clr(1'b0), .dump_flag()
	);

	// ------------------------------------------------------------------ video
	mlc_video u_video (
		.clk, .reset, .video_reset,
		.list_we, .list_addr(a24[13:2]), .list_wdata(cache_din[15:0]), .list_rdata,
		.vram_we, .vram_addr(a24[16:2]), .vram_wdata(cache_din), .vram_be(be), .vram_rdata,
		.pal_we, .pal_addr(a24[12:2]), .pal_wdata(cache_din[15:0]), .pal_rdata,
		.reg_we, .reg_addr(reg_addr_r), .reg_wdata(reg_word),
		.parity(parity_in), .flip,
		.mem_req(spr_req), .mem_addr(spr_addr), .mem_valid(spr_valid), .mem_rdata(spr_rdata),
		.ce_pix, .r, .g, .b, .hblank, .vblank, .hs, .vs,
		.pix_valid(), .pix_x(), .pix_y(),
		.vpos, .hpos_zero,
		.line_start(), .line_valid(), .render_line(), .line_done, .ovr_ev, .list_busy(), .vbl_start
	);

endmodule
