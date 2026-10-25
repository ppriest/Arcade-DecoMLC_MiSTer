// SPDX-License-Identifier: GPL-3.0-or-later
// The YMZ280B against MAME (docs/ROADMAP.md, Phase 3). Replays MAME's register writes
// (scripts/mame/ymzlog.lua: debug/ymz/writes.txt, machine time in seconds) at the same times on
// the chip, and writes every output sample to debug/ymz/rtl.raw (int16 stereo, little-endian,
// one pair per sample at 14 MHz / 384); scripts/compare_audio.py compares it with MAME's WAV.
//
// The sample ROM is debug/<set>_ymz.bin as dumped; the chip's address a reads dump byte x with
// x[0] = a[20], x[20:1] = a[19:0], x[23:21] = a[23:21] (deco_mlc.cpp descramble_sound).
//   +MEM=0  reads answer at once from the ROM (the chip alone, the default)
//   +MEM=1  through mlc_ymz_mem on a behavioural SDRAM (+ROMLAT clocks a unit), at 84 MHz with
//           the chip on a 1-in-6 enable: the board's arrangement
//
//   scripts/run_verilator.sh ymz_tb [+MEM=1] [+SECONDS=n] [+SET=avengrgs]
//
// RUN FROM THE REPOSITORY ROOT.
`timescale 1ns/1ps
module tb_ymz;
	import mlc_video_pkg::*;

	localparam real HALF = 5.9524;             // 84 MHz
	logic clk = 0;
	always #(HALF) clk = ~clk;
	logic rst_n = 0;

	string set = "avengrgs";
	int mem_mode = 0, seconds = 0, romlat = 18;

	logic [7:0] rom [0:(1 << 23) - 1];
	function automatic logic [23:0] dump_addr(input logic [23:0] a);
		return {a[23:21], a[19:0], a[20]};
	endfunction

	// ---- the chip clock: 1 in 6 (14 MHz) ----
	logic [2:0] cediv = 0;
	always_ff @(posedge clk) cediv <= (cediv == 3'd5) ? 3'd0 : cediv + 3'd1;
	wire ce_raw = (cediv == 3'd0);

	// ---- the chip ----
	logic        a_reg = 0, wr_n = 1, cs_n = 1;
	logic [7:0]  di = 0;
	logic [23:0] ma;
	logic [7:0]  mdi;
	logic        moe_n;
	logic [15:0] out_l, out_r;
	logic        ce_chip;

	YMZ280B u_ymz (
		.CLK(clk), .RST_N(rst_n), .EN(1'b1), .CE(ce_chip),
		.A(a_reg), .DI(di), .DO(), .RD_N(1'b1), .WR_N(wr_n), .CS_N(cs_n), .IC_N(rst_n),
		.IRQ_N(), .MA(ma), .MDI(mdi), .MDO(), .MOE_N(moe_n), .MWR_N(), .MCE_N(),
		.OUT_L(out_l), .OUT_R(out_r), .SND_EN(3'b111)
	);

	// ---- memory: direct, or the board's path ----
	logic        mem_req, mem_valid;
	logic [25:0] mem_addr;
	logic [127:0] mem_rdata;
	logic [7:0]  m_data;
	logic        m_stall;
	int          lat = -1;
	logic [25:0] req_a;
	int          nstall = 0, nmiss = 0;

	mlc_ymz_mem u_mem (
		.clk, .reset(!rst_n), .inval(1'b0),
		.ce_in(ce_raw), .ce_out(), .stall(m_stall),
		.ma, .moe_n, .mdi(m_data),
		.mem_req, .mem_addr, .mem_valid, .mem_rdata
	);

	assign ce_chip = mem_mode ? (ce_raw && !m_stall) : ce_raw;
	assign mdi     = mem_mode ? m_data : (dump_addr(ma) < 24'h600000 ? rom[dump_addr(ma)] : 8'h00);

	always_ff @(posedge clk) begin
		mem_valid <= 1'b0;
		if (!rst_n) lat <= -1;
		else if (mem_req) begin
			if (lat >= 0) $display("SDRAM: request while one is in flight");
			req_a <= mem_addr; lat <= romlat; nmiss <= nmiss + 1;
		end else if (lat > 0) lat <= lat - 1;
		else if (lat == 0) begin
			for (int k = 0; k < 16; k++) begin
				int o;
				o = int'(req_a) - int'(YMZ_BASE) + k;
				mem_rdata[8*k +: 8] <= (o >= 0 && o < 24'h600000) ? rom[o] : 8'h00;
			end
			mem_valid <= 1'b1;
			lat <= -1;
		end
		if (ce_raw && m_stall) nstall <= nstall + 1;
	end

	// ---- the output, at each sample ----
	int fd_out, nsamp = 0;
	logic [15:0] last_l = 0, last_r = 0;
	logic        oe_d = 0;
	// OUT_L/R update once a sample (slot 0, cycle 0); record on every update strobe of the chip
	wire out_strobe = (u_ymz.OP6.SLOT == 5'd0 && u_ymz.CYCLE_NUM[2:1] == 2'b00 && u_ymz.CYCLE1_CE);
	always_ff @(posedge clk) if (rst_n && out_strobe) begin
		oe_d <= 1'b1;
	end else oe_d <= 1'b0;
	always_ff @(posedge clk) if (oe_d) begin
		$fwrite(fd_out, "%c%c%c%c", out_l[7:0], out_l[15:8], out_r[7:0], out_r[15:8]);
		nsamp <= nsamp + 1;
	end

	// ---- +KTRACE=1: every key-on and key-off as the chip takes it, and every register write ----
	int ktrace = 0;
	always_ff @(posedge clk) if (ktrace && u_ymz.SLOT1_CE && (u_ymz.OP2.KON || u_ymz.OP2.KOFF))
		$display("%.6f s slot %0d %s", real'(now) / 84.0e6, u_ymz.OP2.SLOT, u_ymz.OP2.KON ? "KEY ON" : "key off");
	always_ff @(posedge clk) if (ktrace && u_ymz.REG_WR && u_ymz.CYCLE1_CE && u_ymz.REG_A[7:5] == 3'b000 && u_ymz.REG_A[1:0] == 2'b01)
		$display("%.6f s   reg %02x <= %02x committed", real'(now) / 84.0e6, u_ymz.REG_A, u_ymz.REG_D);

	// +VTRACE=1: voice 1's ADPCM state each time it takes a new nibble, to debug/ymz/rtl_v1.txt
	int vtrace = 0, fd_v = 0;
	always_ff @(posedge clk) if (vtrace && fd_v != 0 && u_ymz.SLOT1_CE && u_ymz.OP4.SLOT == 3'd1 && u_ymz.OP4.PHASE_OVF)
		$fwrite(fd_v, "%0d %0d\n", $signed(u_ymz.ADPCM_RAM_D[15:0]), u_ymz.ADPCM_RAM_D[30:16]);

	// +PTRACE=n: n passes of voice 1's ADPCM stage after its key-on
	int ptrace = 0, np = 0;
	always_ff @(posedge clk) if (ptrace > np && u_ymz.SLOT1_CE && u_ymz.OP3.SLOT == 3'd1 && real'(now) / 84.0e6 > 4.537) begin
		$display("pass %0d: OP3 ovf %0d kon %0d mo %0d sn %0d SA %04x | RAM_Q step %0d sig %0d",
		         np, u_ymz.OP3.PHASE_OVF, u_ymz.OP3.KON, u_ymz.OP3.MO, u_ymz.OP3.SN, {u_ymz.OP3.SA[15:0]},
		         u_ymz.ADPCM_RAM_Q[30:16], $signed(u_ymz.ADPCM_RAM_Q[15:0]));
		np <= np + 1;
	end

	// +STRACE=1: voice 1's interpolated sample (OP5.WD) and level-scaled sample (OP6.SD) each pass
	int strace = 0, fd_s = 0;
	always_ff @(posedge clk) if (strace && fd_s != 0 && u_ymz.SLOT1_CE) begin
		if (u_ymz.OP4.SLOT == 3'd1) $fwrite(fd_s, "N %04x\n", u_ymz.OP4.WD[15:0]);
		if (u_ymz.OP5.SLOT == 3'd1) $fwrite(fd_s, "W %04x\n", u_ymz.OP5.WD[15:0]);
		if (u_ymz.OP6.SLOT == 3'd1) $fwrite(fd_s, "S %04x\n", u_ymz.OP6.SD[15:0]);
	end

	int rtrace = 0;
	logic moe_d = 1;
	always_ff @(posedge clk) begin
		moe_d <= moe_n;
		if (ktrace && rtrace < 40 && !moe_n && moe_d && real'(now) / 84.0e6 > 4.5) begin
			$display("%.7f s read MA %06x -> %02x (slot pipeline OP3 %0d)", real'(now) / 84.0e6, ma, mdi, u_ymz.OP3.SLOT);
			rtrace <= rtrace + 1;
		end
	end

	// ---- the writes ----
	real t;
	int  fd_w, r, nw = 0;
	logic [31:0] ad, d, mk;
	string line;
	longint now = 0;
	always_ff @(posedge clk) now <= now + 1;

	// WR_N falls on the clock after a chip enable: the chip sets its write strobe on the clock it
	// sees the edge and clears it on its cycle enable, so an edge on an enable clock is lost
	// (YMZ280B.sv, REG_WR); the board's glue does the same (mlc_core)
	task automatic bus_write(input logic a, input logic [7:0] v);
		do @(posedge clk); while (!ce_raw);
		a_reg <= a; di <= v; cs_n <= 0; wr_n <= 0;
		repeat (12) @(posedge clk);                 // two chip clocks low
		wr_n <= 1; cs_n <= 1;
		repeat (12) @(posedge clk);
	endtask

	initial begin
		int fd, n;
		longint target;
		void'($value$plusargs("SET=%s", set));
		void'($value$plusargs("MEM=%d", mem_mode));
		void'($value$plusargs("SECONDS=%d", seconds));
		void'($value$plusargs("ROMLAT=%d", romlat));
		void'($value$plusargs("KTRACE=%d", ktrace));
		void'($value$plusargs("VTRACE=%d", vtrace));
		void'($value$plusargs("PTRACE=%d", ptrace));
		void'($value$plusargs("STRACE=%d", strace));
		if (strace) fd_s = $fopen("debug/ymz/rtl_s1.txt", "w");
		if (vtrace) fd_v = $fopen("debug/ymz/rtl_v1.txt", "w");
		fd = $fopen({"debug/", set, "_ymz.bin"}, "rb");
		if (fd == 0) begin $display("cannot open debug/%s_ymz.bin", set); $finish; end
		n = $fread(rom, fd); $fclose(fd);
		$display("sample ROM: %0d bytes; memory %s", n, mem_mode ? "mlc_ymz_mem" : "direct");
		fd_out = $fopen("debug/ymz/rtl.raw", "wb");
		fd_w = $fopen("debug/ymz/writes.txt", "r");
		if (fd_w == 0) begin $display("cannot open debug/ymz/writes.txt"); $finish; end

		repeat (60) @(posedge clk);
		rst_n <= 1;
		while ($fgets(line, fd_w)) begin
			if (line.len() < 4 || line[0] == "#") continue;
			r = $sscanf(line, "%f %h %h %h", t, ad, d, mk);
			if (r != 4) continue;
			if (seconds > 0 && t > seconds) break;
			if (ad[23:0] != 24'h600000 && ad[23:0] != 24'h600004) continue;   // the volume is applied by the compare
			target = longint'(t * 84.0e6);
			while (now < target) @(posedge clk);
			bus_write(ad[2], d[31:24]);
			nw++;
			if (nw % 200 == 0) $display("  %0d writes, %.1f s", nw, t);
		end
		// run on a second past the last write
		target = now + 84_000_000;
		while (now < target) @(posedge clk);
		$fclose(fd_out);
		$display("done: %0d writes, %0d samples (%.2f s at 14 MHz / 384); unit fetches %0d, stalled chip clocks %0d",
		         nw, nsamp, real'(nsamp) * 384.0 / 14.0e6, nmiss, nstall);
		$finish;
	end

endmodule
