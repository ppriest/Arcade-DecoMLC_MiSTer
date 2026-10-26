// SPDX-License-Identifier: GPL-3.0-or-later
// The sprite engine against a MAME capture (docs/phase1_video.md, "Bench"). Loads the capture
// through mlc_video's CPU-side ports, runs one frame of the real line cadence and writes the
// scan-out to <capture>/rtl.rgb (320 x 240 x RGB8) for render_model.py --rtl. Per line:
// clocks from line_start to line_done, units fetched, pixel writes, overrun.
//
// The engine's two SDRAM slots are served either by a behavioural model answering 16-byte
// units from the 32 MB image debug/<set>_sdram.bin that `mlc_layout.py --set <set> --image`
// writes, in request order, +ROMLAT clocks each (+SDRAM=0, the default), or by the real path
// (+SDRAM=1): the arbiter, the phy, sdram.sv with BL8 and the command-decoding chip model,
// loaded from the same image.
//
// +LAYOUT=n +FRAC8=1 give the set's gfx_layout (the .mra mod byte bits 5:4 and 6; mlc_layout.py
// set_gfx). A capture with linelog.txt (a set that rewrites the IRQ block or clip RAM mid-frame,
// stadhr96) starts from its _prev register dumps and replays each logged write during the line
// it was made on; IRQ word 1 comes from reg_irqregs(_prev).bin, since it reads back 0xffffffff.
//
//   scripts/run_verilator.sh sprite_tb +CAPTURE=debug/avengrgs-attract2400 [+SET=s] [+PARITY=n] [+ROMLAT=n] [+SDRAM=1]
//
// RUN FROM THE REPOSITORY ROOT.
`timescale 1ns/1ps
module tb_sprite;
	import mlc_video_pkg::*;

	localparam real HALF = 5.9524;          // 84 MHz
	logic clk = 0;
	always #(HALF) clk = ~clk;
	logic clk_sdram = 0;                    // 126 MHz, the SDRAM controller's (+SDRAM=1)
	always #(3.9683) clk_sdram = ~clk_sdram;
	logic rst = 1;

	string cap = "debug/avengrgs-attract2400";
	string set = "avengrgs";
	int romlat = 18, parity_arg = -1, frame_no = 0, use_sdram = 0, flip_arg = 0;
	logic parity = 0;

	// ---- ROM images ----
	logic [7:0] sdimg [0:(1 << 25) - 1];                  // the SDRAM image
	logic [1:0] gfx_layout = 0;
	logic       gfx_frac8 = 0;
	logic        reg_we_log = 0;
	logic [5:0]  reg_addr_log;
	logic [31:0] reg_wdata_log;

	// ---- DUT ----
	logic         list_we, vram_we, pal_we, reg_we;
	logic [11:0]  list_addr;
	logic [15:0]  list_wdata, pal_wdata;
	logic [14:0]  vram_addr;
	logic [31:0]  vram_wdata, reg_wdata;
	logic [3:0]   vram_be;
	logic [10:0]  pal_addr;
	logic [5:0]   reg_addr;
	logic [1:0]   mem_req, mem_valid;
	logic [51:0]  mem_addr;
	logic [127:0] mem_rdata;
	logic         ce_pix, hblank, vblank, hs, vs, pix_valid;
	logic [7:0]   r, g, b;
	logic [8:0]   pix_x, pix_y, render_line;
	logic         line_start, line_valid, line_done, ovr_ev, list_busy;

	mlc_video dut (
		.clk, .reset(rst), .video_reset(rst),
		.list_we, .list_addr, .list_wdata,
		.vram_we, .vram_addr, .vram_wdata, .vram_be,
		.pal_we, .pal_addr, .pal_wdata,
		.reg_we(reg_we || reg_we_log), .reg_addr(reg_we_log ? reg_addr_log : reg_addr),
		.reg_wdata(reg_we_log ? reg_wdata_log : reg_wdata),
		.parity, .flip(flip_arg[0]), .gfx_layout, .gfx_frac8,
		.mem_req, .mem_addr, .mem_valid, .mem_rdata,
		.ce_pix, .r, .g, .b, .hblank, .vblank, .hs, .vs, .pix_valid, .pix_x, .pix_y,
		.line_start, .line_valid, .render_line, .line_done, .ovr_ev, .list_busy
	);

	// ---- a 16-byte unit of the SDRAM image ----
	function automatic logic [127:0] unit_of(input logic [25:0] a);
		logic [127:0] d;
		if (!(a >= GFX1_BASE && a < GFX2_BASE + 26'h80000)) $display("SDRAM: request outside gfx1/gfx2 at %07X", a);
		for (int k = 0; k < 16; k++) d[8*k +: 8] = sdimg[int'(a) + k];
		return d;
	endfunction

	// ---- behavioural: requests queued in arrival order, ROMLAT clocks each ----
	logic [1:0]  bq_slot [0:3];
	logic [25:0] bq_addr [0:3];
	logic [2:0]  bq_wp = 0, bq_rp = 0;
	wire  [2:0]  bq_n = bq_wp - bq_rp;
	int          lat = -1;
	logic [1:0]  b_valid;
	logic [127:0] b_rdata;
	always_ff @(posedge clk) begin
		b_valid <= 2'b0;
		if (rst) begin lat <= -1; bq_wp <= 0; bq_rp <= 0; end
		else begin
			if (mem_req[0] && mem_req[1]) $display("SDRAM: two requests in one clock");
			if ((mem_req[0] || mem_req[1]) && !use_sdram) begin
				bq_slot[bq_wp[1:0]] <= mem_req[1] ? 2'd1 : 2'd0;
				bq_addr[bq_wp[1:0]] <= mem_req[1] ? mem_addr[51:26] : mem_addr[25:0];
				bq_wp <= bq_wp + 3'd1;
				if (bq_n >= 3'd2) $display("SDRAM: more than two requests queued");
			end
			if (lat < 0) begin
				if (bq_n != 0) lat <= romlat;
			end else if (lat > 0) begin
				lat <= lat - 1;
			end else begin
				b_rdata <= unit_of(bq_addr[bq_rp[1:0]]);
				b_valid[bq_slot[bq_rp[1:0]]] <= 1'b1;
				bq_rp <= bq_rp + 3'd1;
				lat <= -1;
			end
		end
	end

	// ---- the real path: arbiter, phy, sdram.sv (BL8), the chip model ----
	wire  [15:0] SDRAM_DQ;
	wire  [12:0] SDRAM_A;
	wire   [1:0] SDRAM_BA;
	wire         SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS, SDRAM_DQML, SDRAM_DQMH, SDRAM_CLK, SDRAM_CKE;
	logic        sd_init = 1;
	logic [25:1] p_addr;
	logic        p_wrl, p_wrh, p_req, p_ack;
	logic [15:0] p_din;
	logic [127:0] p_dout;
	logic        phy_req, phy_we, phy_we16, phy_busy, phy_valid;
	logic [25:0] phy_addr;
	logic [15:0] phy_wdata;
	logic [127:0] phy_rdata;
	logic [1:0]  a_valid;
	logic [127:0] a_rdata;

	sdram_chip_model_wide u_chip (
		.clk(clk_sdram), .SDRAM_DQ, .SDRAM_A, .SDRAM_BA, .SDRAM_nCS, .SDRAM_nWE, .SDRAM_nRAS, .SDRAM_nCAS
	);
	// the controller on its own 126 MHz clock, as mlc_sdram_top runs it
	logic [1:0] rst_s;
	always_ff @(posedge clk_sdram) rst_s <= {rst_s[0], rst};
	sdram #(.BL8(1), .RFS_CYCLES(980), .RCD(3), .CL(3)) u_sdram (
		.SDRAM_DQ, .SDRAM_A, .SDRAM_DQML, .SDRAM_DQMH, .SDRAM_BA, .SDRAM_nCS, .SDRAM_nWE, .SDRAM_nRAS, .SDRAM_nCAS,
		.SDRAM_CLK, .SDRAM_CKE, .init(sd_init), .clk(clk_sdram),
		.addr0(p_addr), .wrl0(p_wrl), .wrh0(p_wrh), .din0(p_din), .dout0(p_dout), .req0(p_req), .ack0(p_ack),
		.addr1('0), .wrl1(1'b0), .wrh1(1'b0), .din1('0), .dout1(), .req1(1'b0), .ack1(),
		.addr2('0), .wrl2(1'b0), .wrh2(1'b0), .din2('0), .dout2(), .req2(1'b0), .ack2()
	);
	sdram_port_cdc #(.GB(16)) u_phy (
		.clk, .reset(rst), .clk_sdram, .reset_sdram(rst_s[1]),
		.port_addr(p_addr), .port_wrl(p_wrl), .port_wrh(p_wrh), .port_din(p_din), .port_dout(p_dout),
		.port_req(p_req), .port_ack(p_ack),
		.req(phy_req), .we(phy_we), .we16(phy_we16), .addr(phy_addr), .wdata(phy_wdata),
		.busy(phy_busy), .valid(phy_valid), .rdata(phy_rdata)
	);
	mlc_port_arbiter #(.N(2), .GB(16)) u_arb (
		.clk, .reset(rst),
		.phy_req, .phy_we, .phy_we16, .phy_addr, .phy_wdata, .phy_busy, .phy_valid, .phy_rdata,
		.c_req(mem_req), .c_addr(mem_addr), .c_valid(a_valid), .c_rdata(a_rdata),
		.dl_req(1'b0), .dl_addr('0), .dl_data('0), .dl_we16(1'b0), .dl_busy()
	);

	assign mem_valid = use_sdram ? a_valid : b_valid;
	assign mem_rdata = use_sdram ? a_rdata : b_rdata;

	// ---- the line buffer's pens as scanned out, for the pen-level comparison ----
	logic [15:0] pens [0:240*320-1];
	always_ff @(posedge clk) if (dut.vis_d[0] && dut.y_d[0] >= 8 && dut.y_d[0] <= 247 && dut.x_d[0] < 320)
		pens[(dut.y_d[0] - 8) * 320 + dut.x_d[0]] <= {dut.rwritten, 2'b0, dut.rflags, dut.rpen};

	// ---- the frame ----
	logic [7:0] frame [0:240*320*3-1];
	int npix = 0;
	always_ff @(posedge clk) if (pix_valid && pix_y >= 8 && pix_y <= 247 && pix_x < 320) begin
		frame[((pix_y - 8) * 320 + pix_x) * 3 + 0] <= r;
		frame[((pix_y - 8) * 320 + pix_x) * 3 + 1] <= g;
		frame[((pix_y - 8) * 320 + pix_x) * 3 + 2] <= b;
		npix <= npix + 1;
	end

	// the period of line 248 begins a frame; the second one ends the rendered frame
	int nframe = 0;
	always_ff @(posedge clk) if (!rst && line_start && render_line == 9'd249) nframe <= nframe + 1;

	// ---- +DBG=1: the scanner's path per line, for the first lines ----
	int dbg = 0, c_test = 0, c_blk = 0, c_mul = 0, c_hit = 0, c_pop = 0, c_rows = 0;
	always_ff @(posedge clk) if (!rst && dbg) begin
		if (line_start) begin
			if (l_open && l_line >= 8 && l_line <= 12 && nframe == 2) begin
				$display("line %0d: cand %0d test %0d blk %0d mul %0d hits %0d pops %0d rows %0d clocks %0d",
				         l_line, dut.u_list.cand_count, c_test, c_blk, c_mul, c_hit, c_pop, c_rows, l_clk);
				$display("   at the end: scan %s draw S %s R %s E %s e_active %0d job_v %0d slots %b fifo_empty %0d rows %0d bx %0d w %0d",
				         dut.u_engine.u_scan.state.name, dut.u_engine.u_draw.sstate.name, dut.u_engine.u_draw.rstate.name,
				         dut.u_engine.u_draw.estate.name, dut.u_engine.u_draw.e_active, dut.u_engine.u_draw.job_v,
				         dut.u_engine.slot_busy, dut.u_engine.hit_empty, dut.u_engine.rf_count, dut.u_engine.u_draw.bx, dut.u_engine.u_draw.r_w);
			end
			c_test = 0; c_blk = 0; c_mul = 0; c_hit = 0; c_pop = 0; c_rows = 0;
		end
		if (dut.u_engine.u_scan.state == dut.u_engine.u_scan.S_TEST) c_test++;
		if (dut.u_engine.u_scan.state == dut.u_engine.u_scan.S_BLKW) c_blk++;
		if (dut.u_engine.u_scan.state == dut.u_engine.u_scan.S_DECIDE) c_mul++;
		if (dut.u_engine.u_scan.hit_push) c_hit++;
		if (dut.u_engine.u_draw.hit_pop) c_pop++;
		if (dut.u_engine.u_draw.rq_push) c_rows++;
	end

	// ---- +DBG=2 +TRACE=line: every hit and row of one line ----
	int trace_line = -1;
	always_ff @(posedge clk) if (!rst && dbg == 2 && nframe == 2 && l_line == trace_line) begin
		if (dut.u_engine.u_scan.hit_push)
			$display("HIT entry %0d pair %0d bby %0d y %0d x %0d yoffs %0d xoffs %0d coef_y %0d m1 %0d negy %0d acc1 %0d ybase_int %0d h %0d w %0d fx %0d fy %0d xscale %0x xextra %0x yscale %0x sprite %0x sprite2 %0x tbl %0d rom %0d fmt %0d hib %0x color %0x shadow %0d",
			         dut.u_engine.u_scan.idx, dut.u_engine.u_scan.hit.pair, dut.u_engine.u_scan.hit.bby, dut.u_engine.u_scan.y_r, dut.u_engine.u_scan.x_r,
			         dut.u_engine.u_scan.yoffs, dut.u_engine.u_scan.xoffs, dut.u_engine.u_scan.coef_y, dut.u_engine.u_scan.m1, dut.u_engine.u_scan.negy,
			         dut.u_engine.u_scan.acc1, dut.u_engine.u_scan.ybase_int,
			         dut.u_engine.u_scan.hit.h, dut.u_engine.u_scan.hit.w, dut.u_engine.u_scan.hit.fx, dut.u_engine.u_scan.hit.fy,
			         dut.u_engine.u_scan.hit.xscale, dut.u_engine.u_scan.hit.xextra, dut.u_engine.u_scan.hit.yscale,
			         dut.u_engine.u_scan.hit.sprite, dut.u_engine.u_scan.hit.sprite2, dut.u_engine.u_scan.hit.is_table,
			         dut.u_engine.u_scan.hit.table_rom, dut.u_engine.u_scan.hit.tile_fmt, dut.u_engine.u_scan.hit.hibits,
			         dut.u_engine.u_scan.hit.color, dut.u_engine.u_scan.hit.shadow);
		if (dut.u_engine.u_draw.sstate == dut.u_engine.u_draw.S_HAND && !dut.u_engine.u_draw.job_v)
			$display("   SETUP sprite %0x bby %0d yscale %0x q %0x srcline %0d by %0d xs %0x xbase %0x cnt0 %0d",
			         dut.u_engine.u_draw.hs.sprite, dut.u_engine.u_draw.hs.bby, dut.u_engine.u_draw.hs.yscale, dut.u_engine.u_draw.q,
			         dut.u_engine.u_draw.srcline, dut.u_engine.u_draw.by, dut.u_engine.u_draw.xs,
			         $signed({{4{dut.u_engine.u_draw.hs.x[11]}}, dut.u_engine.u_draw.hs.x, 16'b0}) + (dut.u_engine.u_draw.negx ? -$signed({4'b0, dut.u_engine.u_draw.pacc}) : $signed({4'b0, dut.u_engine.u_draw.pacc})),
			         dut.u_engine.u_draw.cacc);
		if (dut.u_engine.u_draw.rq_push)
			$display("   ROW bx %0d tile %0x tile2 %0x coloff %0d t %0d walk %0d  [newA %0d newB %0d]", dut.u_engine.u_draw.bx - 1, dut.u_engine.u_draw.code_w,
			         dut.u_engine.u_draw.code2_w, dut.u_engine.u_draw.coloff, dut.u_engine.u_draw.rq_in.t, dut.u_engine.u_draw.rq_in.walk,
			         dut.u_engine.u_draw.newA, dut.u_engine.u_draw.newB);
		if (dut.u_engine.u_draw.rstate == dut.u_engine.u_draw.R_IDLE && dut.u_engine.u_draw.job_v)
			$display("   JOB sprite %0x w %0d", dut.u_engine.u_draw.j_sprite, dut.u_engine.u_draw.j_w);
		if (dut.u_engine.row_take) $display("      ISSUE row unit %07x slot %0d", dut.u_engine.row_addr, dut.u_engine.use1);
		if (dut.u_engine.tab_take) $display("      ISSUE tab unit %07x slot %0d", dut.u_engine.tab_addr, dut.u_engine.use1);
		if (dut.u_engine.rf_push) $display("      UNIT in  %032x", dut.u_engine.rf_din);
		if (dut.u_engine.u_draw.row_pop) $display("      UNIT pop %032x into %s", dut.u_engine.row_data, dut.u_engine.u_draw.estate.name);
	end

	// ---- per-line statistics ----
	int l_clk, l_gran, l_pix, l_line, l_open;
	int l_e, l_rwe, l_rwm, l_s, l_scan, l_hits;
	int st_clk [0:255], st_gran [0:255], st_pix [0:255], st_ovr [0:255];
	int st_e [0:255], st_rwe [0:255], st_rwm [0:255], st_s [0:255], st_scan [0:255], st_hits [0:255];
	int total_ovr = 0, nlines = 0;
	logic done_seen;
	always_ff @(posedge clk) if (!rst) begin
		if (line_start) begin
			if (l_open) begin
				// the line just ended
				st_gran[l_line] = l_gran; st_pix[l_line] = l_pix;
				st_e[l_line] = l_e; st_rwe[l_line] = l_rwe; st_rwm[l_line] = l_rwm; st_s[l_line] = l_s;
				st_scan[l_line] = l_scan; st_hits[l_line] = l_hits;
				if (!done_seen) st_clk[l_line] = l_clk;        // ran into the deadline
			end
			l_open    = line_valid;
			l_line    = render_line;
			l_clk     = 0; l_gran = 0; l_pix = 0;
			l_e = 0; l_rwe = 0; l_rwm = 0; l_s = 0; l_scan = 0; l_hits = 0;
			done_seen = 0;
		end else if (l_open) begin
			l_clk++;
			if (!done_seen && line_done) begin done_seen = 1; st_clk[l_line] = l_clk; end
			if (dut.u_engine.u_draw.e_active) l_e++;
			if (dut.u_engine.u_draw.rstate == dut.u_engine.u_draw.R_PUSH && dut.u_engine.u_draw.rq_full) l_rwe++;
			if (dut.u_engine.u_draw.rstate == dut.u_engine.u_draw.R_TABW || dut.u_engine.u_draw.rstate == dut.u_engine.u_draw.R_TAB2W ||
			    dut.u_engine.u_draw.rstate == dut.u_engine.u_draw.R_ISSA || dut.u_engine.u_draw.rstate == dut.u_engine.u_draw.R_ISSB ||
			    dut.u_engine.u_draw.estate == dut.u_engine.u_draw.E_GETA || dut.u_engine.u_draw.estate == dut.u_engine.u_draw.E_GETB) l_rwm++;
			if (dut.u_engine.u_draw.sstate != dut.u_engine.u_draw.S_IDLE) l_s++;
			if (dut.u_engine.u_scan.state != dut.u_engine.u_scan.S_IDLE) l_scan++;
			if (dut.u_engine.u_scan.hit_push) l_hits++;
		end
		if (ovr_ev) begin total_ovr++; st_ovr[l_line] = 1; end
		if (mem_req[0]) l_gran++;
		if (mem_req[1]) l_gran++;
		if (dut.lb_we) l_pix++;
	end

	// ---- loading ----
	logic [7:0] fbuf [0:131071];
	int n;

	// ---- the line log: write k is made during line log_line[k] of the captured frame (lines
	// 248-255 as -8..-1, the previous frame's vblank) on the register port; the capture's lines
	// 8-247 are rendered while nframe == 2, lines 248..255 before them while nframe is 1 (248) and
	// 2 (249-255) ----
	int    log_line [0:8191];
	int    log_off  [0:8191];
	int    log_data [0:8191];
	int    log_mask [0:8191];
	int    n_log = 0, log_i = 0;
	logic  has_log = 0;
	logic  log_go = 0;
	int    log_cur = -1000;
	logic  log_frame = 0;
	always_ff @(posedge clk) if (!rst && has_log && line_start) begin
		if (!log_frame) begin
			if (nframe == 1 && render_line == 9'd248) begin log_frame <= 1'b1; log_cur <= -8; end
		end else if (render_line == 9'd248) begin
			log_frame <= 1'b0; log_cur <= -1000;
		end else if (render_line >= 9'd249 && render_line <= 9'd255) log_cur <= int'(render_line) - 256;
		else if (render_line <= 9'd247) log_cur <= int'(render_line);
	end

	task automatic load_file(input string name, output int nread);
		int fd;
		fd = $fopen({cap, "/", name}, "rb");
		if (fd == 0) begin $display("cannot open %s/%s", cap, name); $finish; end
		nread = $fread(fbuf, fd);
		$fclose(fd);
	endtask

	task automatic write_list();
		for (int i = 0; i < 3072; i++) begin
			@(posedge clk);
			list_we <= 1'b1; list_addr <= i[11:0]; list_wdata <= {fbuf[4*i + 2], fbuf[4*i + 3]};
		end
		@(posedge clk); list_we <= 1'b0;
	endtask

	task automatic write_vram();
		for (int i = 0; i < 32768; i++) begin
			@(posedge clk);
			vram_we <= 1'b1; vram_addr <= i[14:0]; vram_be <= 4'hf;
			vram_wdata <= {fbuf[4*i], fbuf[4*i + 1], fbuf[4*i + 2], fbuf[4*i + 3]};
		end
		@(posedge clk); vram_we <= 1'b0;
	endtask

	task automatic write_pal();
		for (int i = 0; i < 2048; i++) begin
			@(posedge clk);
			pal_we <= 1'b1; pal_addr <= i[10:0]; pal_wdata <= {fbuf[4*i + 2], fbuf[4*i + 3]};
		end
		@(posedge clk); pal_we <= 1'b0;
	endtask

	// the logged writes of the current line, after its line_start latch, one a clock
	always @(posedge clk) if (!rst && has_log && log_cur > -1000 && log_i < n_log && log_line[log_i] <= log_cur && !reg_we) begin
		if (log_mask[log_i] != 32'hffffffff) $display("line log: a %08x-masked write to %06x applied whole", log_mask[log_i], log_off[log_i]);
		reg_we_log   <= 1'b1;
		reg_addr_log <= (log_off[log_i] >= 32'h200080) ? 6'(32 + ((log_off[log_i] - 32'h200080) >> 2)) : 6'((log_off[log_i] - 32'h200000) >> 2);
		reg_wdata_log <= log_data[log_i];
		log_i <= log_i + 1;
	end else reg_we_log <= 1'b0;

	task automatic write_regs(input int base);
		for (int i = 0; i < 32; i++) begin
			@(posedge clk);
			reg_we <= 1'b1; reg_addr <= 6'(base + i);
			reg_wdata <= {fbuf[4*i], fbuf[4*i + 1], fbuf[4*i + 2], fbuf[4*i + 3]};
		end
		@(posedge clk); reg_we <= 1'b0;
	endtask

	initial begin
		int fd, worst_clk, worst_gran, worst_pix, wl_clk, wl_gran, wl_pix;
		string line;
		void'($value$plusargs("CAPTURE=%s", cap));
		void'($value$plusargs("SET=%s", set));
		void'($value$plusargs("ROMLAT=%d", romlat));
		void'($value$plusargs("PARITY=%d", parity_arg));
		void'($value$plusargs("DBG=%d", dbg));
		void'($value$plusargs("TRACE=%d", trace_line));
		void'($value$plusargs("SDRAM=%d", use_sdram));
		void'($value$plusargs("FLIP=%d", flip_arg));

		// the manifest's frame number sets the parity unless +PARITY says otherwise
		fd = $fopen({cap, "/manifest.txt"}, "r");
		if (fd != 0) begin
			while ($fgets(line, fd)) void'($sscanf(line, "frame %d", frame_no));
			$fclose(fd);
		end
		parity = (parity_arg >= 0) ? parity_arg[0] : frame_no[0];

		begin int lay = 0, f8 = 0; void'($value$plusargs("LAYOUT=%d", lay)); void'($value$plusargs("FRAC8=%d", f8));
			gfx_layout = 2'(lay); gfx_frac8 = f8 != 0; end
		fd = $fopen({"debug/", set, "_sdram.bin"}, "rb");
		if (fd == 0) begin $display("cannot open debug/%s_sdram.bin (scripts/mlc_layout.py --set %s --image)", set, set); $finish; end
		n = $fread(sdimg, fd); $fclose(fd);
		$display("sdram image: %0d bytes, layout %0d frac8 %0d", n, gfx_layout, gfx_frac8);
		if (use_sdram) begin
			// word w = bytes 2w (low) and 2w+1; the chip model's index for the low 32 MB is the
			// word address (sdram.sv: bank = a[24:23], row a[22:10], col a[9:1])
			for (int w = 0; w < (1 << 24); w++) u_chip.mem[w] = {sdimg[2*w + 1], sdimg[2*w]};
		end
		list_we = 0; vram_we = 0; pal_we = 0; reg_we = 0;
		l_open = 0;
		repeat (4) @(posedge clk);
		sd_init <= 0;
		// the DUT runs while it is loaded (its registers reset, its RAMs do not): the first
		// frame draws an empty list, the second one the capture
		rst <= 0;
		repeat (4) @(posedge clk);

		load_file("spritebuf.bin", n);
		if (n != 12288) begin $display("spritebuf.bin: %0d bytes", n); $finish; end
		write_list();
		load_file("vram.bin", n);
		write_vram();
		load_file("palette.bin", n);
		write_pal();
		// with a line log: the registers as the previous frame left them, then the log's writes
		fd = $fopen({cap, "/linelog.txt"}, "r");
		has_log = (fd != 0);
		if (has_log) begin
			int ln, off, d, m;
			while ($fscanf(fd, "%h %h %h %h", ln, off, d, m) == 4) begin
				log_line[n_log] = (ln >= 248) ? ln - 256 : ln;
				log_off[n_log] = off; log_data[n_log] = d; log_mask[n_log] = m;
				n_log++;
			end
			$fclose(fd);
		end
		load_file(has_log ? "clipram_prev.bin" : "clipram.bin", n);
		write_regs(32);
		load_file(has_log ? "irqram_prev.bin" : "irqram.bin", n);
		// IRQ word 1 as written (it reads back 0xffffffff)
		begin
			int fr;
			fr = $fopen({cap, has_log ? "/reg_irqregs_prev.bin" : "/reg_irqregs.bin"}, "rb");
			if (fr != 0) begin
				logic [7:0] rb [0:127];
				void'($fread(rb, fr)); $fclose(fr);
				for (int k = 4; k < 8; k++) fbuf[k] = rb[k];
			end
		end
		write_regs(0);
		$display("line log: %0d writes", n_log);

		$display("capture %s, frame %0d, parity %0d, romlat %0d", cap, frame_no, parity, romlat);
		if (dbg) $display("clip_min_y %h clip_max_y %h clip_min_x %h clip_max_x %h alpha %0d",
		                  dut.clip_min_y, dut.clip_max_y, dut.clip_min_x, dut.clip_max_x, dut.alpha_on);
		while (nframe < 3) @(posedge clk);
		@(posedge clk);

		// ---- report ----
		worst_clk = 0; worst_gran = 0; worst_pix = 0; wl_clk = 0; wl_gran = 0; wl_pix = 0;
		fd = $fopen({cap, "/rtl_lines.txt"}, "w");
		$fwrite(fd, "line clocks units pixels overrun emit r_wait_queue wait_mem setup scan hits\n");
		for (int l = 8; l <= 247; l++) begin
			$fwrite(fd, "%0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d\n", l, st_clk[l], st_gran[l], st_pix[l], st_ovr[l],
			        st_e[l], st_rwe[l], st_rwm[l], st_s[l], st_scan[l], st_hits[l]);
			if (st_clk[l]  > worst_clk)  begin worst_clk  = st_clk[l];  wl_clk  = l; end
			if (st_gran[l] > worst_gran) begin worst_gran = st_gran[l]; wl_gran = l; end
			if (st_pix[l]  > worst_pix)  begin worst_pix  = st_pix[l];  wl_pix  = l; end
		end
		$fclose(fd);
		$display("pixels captured: %0d of 76800; overruns: %0d", npix, total_ovr);
		$display("worst line: %0d clocks of 5304 (line %0d); %0d units (line %0d); %0d pixel writes (line %0d)",
		         worst_clk, wl_clk, worst_gran, wl_gran, worst_pix, wl_pix);

		fd = $fopen({cap, "/rtl.rgb"}, "wb");
		for (int i = 0; i < 240*320*3; i++) $fwrite(fd, "%c", frame[i]);
		$fclose(fd);
		fd = $fopen({cap, "/rtl_pens.bin"}, "wb");
		for (int i = 0; i < 240*320; i++) $fwrite(fd, "%c%c", pens[i][15:8], pens[i][7:0]);
		$fclose(fd);
		$display("wrote %s/rtl.rgb", cap);
		$finish;
	end

endmodule
