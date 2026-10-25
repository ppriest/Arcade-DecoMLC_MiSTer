// SPDX-License-Identifier: GPL-3.0-or-later
// Avengers' boot on the SH7604, against MAME. Phase 0 exit criteria 2 and 3 (docs/ROADMAP.md).
//
// The CPU is jtsh7604 at 84 MHz with ce_r/ce_f one clock in four (21 MHz). Around it the MLC
// memory map of deco_mlc.cpp avengrgs_map (lines 304-325), decoded on A[23:0] as the board's
// bus controller does (the chip-select bits A[26:24] carry only wait states): the program ROM
// from debug/avengrgs_maincpu.bin, main RAM, VRAM, the sprite list (16-bit in 32-bit slots),
// the palette, the clip and IRQ blocks as arrays. Two modes:
//
//   +MODE=replay (default)  every I/O read is answered from MAME's own reads, in order
//                           (debug/<set>-boot/<set>_replay.txt, scripts/compare_boot_trace.py
//                           replay), and the scanline interrupt is raised at the write count
//                           where MAME took it (<set>_irq.txt). Every bus access is written to
//                           debug/<set>-boot/<set>_rtl.trace in MAME's "seq rw addr mask data"
//                           form for `compare_boot_trace.py compare`.
//   +MODE=hw                the I/O is modelled (the 0xFFFFFFFF ports, the 0x200070 toggle, the
//                           scanline counter, EEPROM DO high) and the interrupt comes from a
//                           442 x 274 raster at 7 MHz when the line register matches, as the
//                           core will do it. For the CPI measurement: instructions committed,
//                           CPU cycles, cycles waited on the bus.
//
// +ROMLAT=n adds n clocks to every ROM access (an uncontended SDRAM granule is about 11 at
// 84 MHz); RAM answers in one. +MAXACC=n stops after n bus accesses, +MS=n after n ms of
// simulated time. RUN FROM THE REPOSITORY ROOT: scripts/run_verilator.sh boot_tb [+plusargs]
`timescale 1ns/1ps
module tb_boot;
	localparam real HALF = 5.9524;          // 84 MHz
	logic clk = 0;
	always #(HALF) clk = ~clk;
	logic rst = 1;

	// ---- plusargs ----
	string mode = "replay", set = "avengrgs", trace_sfx = "";
	int maxacc = 2000000, ms = 500, romlat = 0, ramlat = 0;   // +RAMLAT: clocks added to every non-ROM access
	longint clk_limit;

	// ---- clock enables: ce_r 1 in 4, ce_f two clocks later (rtl/cpu/sh7604/README.md) ----
	logic [1:0] cec = 0;
	always_ff @(posedge clk) cec <= cec + 2'd1;
	wire ce_r = (cec == 2'd0);
	wire ce_f = (cec == 2'd2);

	// ---- raster, hw mode: 442 x 12 = 5304 clk a line, 274 lines, MAME's line numbers ----
	int hc = 0, vc = 0;
	always_ff @(posedge clk) if (!rst) begin
		if (hc == 5303) begin hc <= 0; vc <= (vc == 273) ? 0 : vc + 1; end
		else hc <= hc + 1;
	end

	// ---- memories ----
	logic [7:0]  rom  [0:1048575];
	logic [7:0]  ram  [0:131071];
	logic [7:0]  vram [0:131071];
	logic [15:0] spr  [0:3071];
	logic [15:0] pal  [0:8191];
	logic [31:0] clipr [0:31];
	logic [31:0] irqr  [0:31];

	// ---- CPU ----
	wire [26:0] A;
	wire [31:0] cpu_dout;
	wire        BS_N, CS0_N, CS1_N, CS2_N, CS3_N, RD_WR_N, CE_N, OE_N, RD_N, IVECF_N, RFS, BGR_N, WAIT_N;
	wire [3:0]  WE_N;
	wire        cache_cs, cache_we, cache_rd, cache_wr;
	wire [26:1] cache_addr;
	wire [31:0] cache_din;
	wire [3:0]  cache_dsn;
	logic [31:0] cpu_din = 0;
	logic        cache_ok = 0;
	logic        irq_pending = 0;
	wire  [3:0]  irl_n = irq_pending ? 4'b1110 : 4'b1111;   // IRL level 1

	jtsh7604 #(
		.UBC_DISABLE(1'b1), .SCI_DISABLE(1'b1), .WDT_DISABLE(1'b1),
		.BUS_AREA_TIMIMG(4'h0), .BUS_SIZE_BYTE_DISABLE(1'b0), .BUS_SIZE_WORD_DISABLE(1'b0),
		.MD_CFG(6'b010100)
	) u_cpu (
		.rst(rst), .clk(clk), .ce_r(ce_r), .ce_f(ce_f),
		.nmi_n(1'b1), .irl_n(irl_n), .cpu_din(cpu_din),
		.cps3_key1(32'd0), .cps3_key2(32'd0), .cps3_crypt_mode(3'b010), .cps3_region(3'd0),
		.cps3_region_redearth(1'b0), .cache_ok(cache_ok),
		.A(A), .cpu_dout(cpu_dout), .BS_N(BS_N), .CS0_N(CS0_N), .CS1_N(CS1_N), .CS2_N(CS2_N),
		.CS3_N(CS3_N), .RD_WR_N(RD_WR_N), .CE_N(CE_N), .OE_N(OE_N), .WE_N(WE_N), .RD_N(RD_N),
		.IVECF_N(IVECF_N), .RFS(RFS), .BGR_N(BGR_N), .WAIT_N(WAIT_N),
		.cache_cs(cache_cs), .cache_we(cache_we), .cache_rd(cache_rd), .cache_wr(cache_wr),
		.cache_addr(cache_addr), .cache_din(cache_din), .cache_dsn(cache_dsn)
	);

	// ---- bus service ----
	wire [26:0] ba   = {cache_addr, 1'b0};
	wire [23:0] a24  = {ba[23:2], 2'b00};   // the bus is 32 bits wide: lanes select the bytes
	wire [31:0] wmask = {{8{~cache_dsn[3]}}, {8{~cache_dsn[2]}}, {8{~cache_dsn[1]}}, {8{~cache_dsn[0]}}};
	wire is_rom  = a24 < 24'h100000;
	wire is_ram  = a24 >= 24'h100000 && a24 < 24'h120000;
	wire is_irq  = a24 >= 24'h200000 && a24 < 24'h200080;
	wire is_clip = a24 >= 24'h200080 && a24 < 24'h200100;
	wire is_spr  = a24 >= 24'h204000 && a24 < 24'h207000;
	wire is_vram = a24 >= 24'h280000 && a24 < 24'h2a0000;
	wire is_pal  = a24 >= 24'h300000 && a24 < 24'h308000;
	wire is_io   = !(is_rom || is_ram || is_clip || is_spr || is_vram || is_pal);  // the IRQ block's reads included

	int   fd_trace = 0, fd_replay = 0, fd_irq = 0;
	int   nacc = 0, nwrites = 0, nio = 0, nio_bad = 0, nirq = 0, nack = 0;
	int   irq_target = -1;
	logic vbl_toggle = 1'b1;
	logic [31:0] rdata;
	int   lat = -1;
	logic served = 0;

	function automatic logic [31:0] mem_read(input logic [23:0] a);
		logic [31:0] v;
		if (is_rom)       v = {rom[a], rom[a+1], rom[a+2], rom[a+3]};
		else if (is_ram)  v = {ram[a-24'h100000], ram[a-24'h100000+1], ram[a-24'h100000+2], ram[a-24'h100000+3]};
		else if (is_vram) v = {vram[a-24'h280000], vram[a-24'h280000+1], vram[a-24'h280000+2], vram[a-24'h280000+3]};
		else if (is_clip) v = clipr[a[6:2]];
		else if (is_spr)  v = {16'hffff, spr[(a-24'h204000) >> 2]};
		else if (is_pal)  v = {16'h0000, pal[(a-24'h300000) >> 2]};
		else              v = 32'h0;
		return v;
	endfunction

	// hw-mode I/O model: deco_mlc.cpp 123-173, 318-324
	function automatic logic [31:0] io_model(input logic [23:0] a);
		logic [31:0] v;
		case (a)
			24'h200070: v = vbl_toggle ? 32'hffffffff : 32'h0;
			24'h200074: v = vc;
			24'h200000, 24'h200004, 24'h20007c: v = 32'hffffffff;
			24'h400000: v = 32'hffffffff;        // inputs idle, EEPROM DO high
			24'h440000, 24'h440004, 24'h440008, 24'h44001c: v = 32'hffffffff;
			default: v = 32'h0;
		endcase
		return v;
	endfunction

	task automatic mem_write(input logic [23:0] a, input logic [31:0] d, input logic [31:0] m);
		int i;
		if (is_ram) begin
			for (i = 0; i < 4; i++) if (m[31-8*i -: 8] != 0) ram[a-24'h100000+i] = d[31-8*i -: 8];
		end else if (is_vram) begin
			for (i = 0; i < 4; i++) if (m[31-8*i -: 8] != 0) vram[a-24'h280000+i] = d[31-8*i -: 8];
		end else if (is_spr) begin
			if (m[15:8] != 0) spr[(a-24'h204000) >> 2][15:8] = d[15:8];
			if (m[7:0]  != 0) spr[(a-24'h204000) >> 2][7:0]  = d[7:0];
		end else if (is_pal) begin
			if (m[15:8] != 0) pal[(a-24'h300000) >> 2][15:8] = d[15:8];
			if (m[7:0]  != 0) pal[(a-24'h300000) >> 2][7:0]  = d[7:0];
		end else if (is_clip) begin
			clipr[a[6:2]] = (clipr[a[6:2]] & ~m) | (d & m);
		end else if (is_irq) begin
			irqr[a[6:2]] = (irqr[a[6:2]] & ~m) | (d & m);
			if (a[6:2] == 5'd4) begin irq_pending = 0; nack++; end      // 0x200010: acknowledge
		end
		// ROM, 0x500000 (EEPROM, volume), 0x600000 (YMZ280B): no effect here
	endtask

	// The acknowledge follows the upstream async-memory test's model: cache_ok is registered
	// from the request and stays up while the request does (the wrapper drops cache_cs the
	// clock after it sees cache_ok), so with no added latency it answers the clock after the
	// request. +ROMLAT delays ROM answers by that many clocks.
	always @(posedge clk) begin
		cache_ok <= served & cache_cs;
		if (rst) begin
			lat <= -1; served <= 0;
		end else if (cache_cs && (cache_rd || cache_wr) && !served) begin
			if (lat < 0 && (is_rom ? romlat : ramlat) > 0) lat <= (is_rom ? romlat : ramlat) - 1;
			else if (lat > 0) lat <= lat - 1;
			else begin
				// the access completes now
				logic [31:0] d, m;
				int r_a, r_m, r_d;
				if (cache_wr) begin
					m = wmask; d = cache_din & m;
					mem_write(a24, cache_din, m);
					nwrites++;
				end else begin
					m = 32'hffffffff;
					if (is_io) begin
						nio++;
						if (mode == "replay") begin
							if ($fscanf(fd_replay, "%h %h %h", r_a, r_m, r_d) == 3) begin
								if (r_a != ba) begin
									nio_bad++;
									if (nio_bad <= 8) $display("replay: I/O read %0d at %07X, MAME's was %07X (%08X)", nio, ba, r_a, r_d);
								end
								d = r_d;
							end else begin
								$display("replay exhausted at I/O read %0d (%07X)", nio, ba);
								d = io_model(a24);
								done_reason = "replay exhausted"; done = 1;
							end
						end else d = io_model(a24);
						if (a24 == 24'h200070) vbl_toggle = ~vbl_toggle;
					end else d = mem_read(a24);
					cpu_din <= d;
				end
				cache_ok <= 1'b1;
				served <= 1;
				lat <= -1;
				nacc++;
				if (fd_trace != 0 && (maxacc == 0 || nacc <= maxacc))   // +MAXACC=0: no cap
					$fwrite(fd_trace, "%0d\t%s\t%08X\t%08X\t%08X\n", nacc, cache_wr ? "w" : "r", {ba[26:2], 2'b00}, m, d);
				if (nacc == maxacc) begin done_reason = "MAXACC reached"; done = 1; end
				// replay mode: the interrupt where MAME took it
				if (mode == "replay" && cache_wr && nwrites == irq_target) begin
					irq_pending = 1; nirq++;
					if ($fscanf(fd_irq, "%d", irq_target) != 1) irq_target = -1;
				end
			end
		end else if (!cache_cs) served <= 0;
	end

	// hw mode: the scanline interrupt from the raster (deco_mlc.cpp 198-243)
	always @(posedge clk) if (!rst && mode == "hw" && hc == 0 && irqr[5] != 32'hffffffff && vc == irqr[5][31:0]) begin
		if (!irq_pending) nirq++;
		irq_pending = 1;
	end

	// ---- +WATCH=n: a text waveform of the bus seam from write n for +WATCHCLK clocks ----
	int watch = -1, watchclk = 300, watching = 0;
	always @(posedge clk) if (!rst && watch >= 0 && nwrites >= watch && watching < watchclk) begin
		if (watching == 0) $display("clk ce_r | core: CBUS_REQ WR A        CACHE_BUSY | cache->bsc: IBUS_REQ IBUS_WAIT BSC_BUSY | bsc: STATE CBUSY CBUSY2 CACK | BUS_STB A        WE_N | req_act ok WAIT_N | nwrites");
		$display("%0d %0d | %0d %0d %08X %0d | %0d %0d %0d | %0d %0d %0d %0d | %0d %07X %04b | %0d %0d %0d | %0d",
		         clocks, ce_r,
		         u_cpu.u_cpu.CBUS_REQ, u_cpu.u_cpu.CBUS_WR, u_cpu.u_cpu.CBUS_A, u_cpu.u_cpu.CACHE_BUSY,
		         u_cpu.u_cpu.IBUS_REQ, u_cpu.u_cpu.IBUS_WAIT, u_cpu.u_cpu.BSC_IBUS_BUSY,
		         u_cpu.u_cpu.bsc.BUS_STATE, u_cpu.u_cpu.bsc.CBUSY, u_cpu.u_cpu.bsc.CBUSY2, u_cpu.u_cpu.BSC_ACK,
		         u_cpu.cpu_bus_stb, u_cpu.cpu_a, u_cpu.cpu_we,
		         u_cpu.req_active, cache_ok, WAIT_N, nwrites);
		watching++;
	end

	// ---- CPI: committed instructions, CPU cycles, cycles waited on the bus ----
	longint commits = 0, cycles = 0, waited = 0, clocks = 0;
	always @(posedge clk) if (!rst) begin
		clocks++;
		if (u_cpu.u_cpu.core.u_trace.TRACE_VALID) commits++;
		if (ce_r) begin cycles++; if (!WAIT_N) waited++; end
	end

	// ---- run ----
	logic  done = 0;
	string done_reason = "";
	int    first_vec = 0;
	always @(posedge clk) if (!rst && cache_ok && !cache_wr && ba == 27'h100 && first_vec == 0) begin
		first_vec = nacc;
		$display("first read of vector 64 (0x100) at access %0d, write %0d, clock %0d", nacc, nwrites, clocks);
	end

	initial begin
		int fd, n;
		void'($value$plusargs("MODE=%s", mode));
		void'($value$plusargs("SET=%s", set));
		void'($value$plusargs("MAXACC=%d", maxacc));
		void'($value$plusargs("MS=%d", ms));
		void'($value$plusargs("ROMLAT=%d", romlat));
		void'($value$plusargs("RAMLAT=%d", ramlat));
		void'($value$plusargs("WATCH=%d", watch));
		void'($value$plusargs("WATCHCLK=%d", watchclk));
		clk_limit = longint'(ms) * 84000;
		for (int i = 0; i < 32; i++) begin clipr[i] = 0; irqr[i] = 0; end
		fd = $fopen($sformatf("debug/%s_maincpu.bin", set), "rb");
		if (fd == 0) $fatal(1, "cannot open debug/%s_maincpu.bin", set);
		n = $fread(rom, fd);
		$fclose(fd);
		$display("program ROM: %0d bytes; mode %s, romlat %0d, maxacc %0d, ms %0d", n, mode, romlat, maxacc, ms);
		// hw mode writes its own file: a replay run and a hw run in parallel must not share one
		// (a string variable, not a literal ternary: Verilator pads "" to the other arm's width)
		if (mode == "hw") trace_sfx = "_hw"; else trace_sfx = "";
		fd_trace = $fopen($sformatf("debug/%s-boot/%s_rtl%s.trace", set, set, trace_sfx), "w");
		if (fd_trace == 0) $fatal(1, "cannot open debug/%s-boot/%s_rtl.trace", set, set);
		$fwrite(fd_trace, "# RTL bus accesses from reset (sim/boot_tb, mode %s), seq rw addr mask data\n", mode);
		if (mode == "replay") begin
			fd_replay = $fopen($sformatf("debug/%s-boot/%s_replay.txt", set, set), "r");
			fd_irq    = $fopen($sformatf("debug/%s-boot/%s_irq.txt", set, set), "r");
			if (fd_replay == 0 || fd_irq == 0) $fatal(1, "run scripts/compare_boot_trace.py replay %s first", set);
			if ($fscanf(fd_irq, "%d", irq_target) != 1) irq_target = -1;
		end
		repeat (40) @(posedge clk);
		rst = 0;
		while (!done && clocks < clk_limit) @(posedge clk);
		if (!done) done_reason = "time limit";
		$fclose(fd_trace);
		$display("stop: %s. %0d accesses, %0d writes, %0d I/O reads (%0d not at MAME's address), %0d interrupts raised, %0d acknowledged",
		         done_reason, nacc, nwrites, nio, nio_bad, nirq, nack);
		$display("CPI: %0d instructions in %0d CPU cycles (%0d waited on the bus): %.2f cycles per instruction, %.2f without waits",
		         commits, cycles, waited, real'(cycles) / real'(commits > 0 ? commits : 1),
		         real'(cycles - waited) / real'(commits > 0 ? commits : 1));
		$finish;
	end
endmodule
