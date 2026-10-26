// SPDX-License-Identifier: GPL-3.0-or-later
// The whole board in simulation: mlc_top (the SH7604, the bus, the video, the memory backend)
// on the chip model loaded with the SDRAM image, the factory EEPROM loaded through the top's
// port, running from reset. Frames are written as they scan out; the bus is traced in MAME's
// "seq rw addr mask data" form for scripts/compare_boot_trace.py.
//
//   scripts/run_verilator.sh core_tb [+SET=avengrgs] [+FRAMES=n] [+SAVE=k,l,...] [+TRACE=n] [+AUDIO=1]
//
// +FRAMES stops after n frames (line 248 periods). +SAVE names the frames to write as
// debug/core/<set>_fNNN.rgb (320 x 240 x RGB8; python scripts/rgb2png.py converts). +TRACE=n
// traces the first n bus accesses to debug/<set>-boot/<set>_core.trace. +AUDIO=1 writes the
// core's sound output, after the volume byte, once a chip sample (14 MHz / 384, as sim/ymz_tb)
// to debug/core/<set>_audio.raw (int16 stereo); scripts/compare_audio.py --rtl ... --no-gain
// compares it with MAME. RUN FROM THE REPOSITORY ROOT.
`timescale 1ns/1ps
module tb_core #(
	parameter bit DE156 = 1'b0     // -GDE156=1: the DE156 board (stadhr96u and the other ARM sets)
);
	import mlc_video_pkg::*;

	localparam real HALF = 5.9524;          // 84 MHz
	logic clk = 0;
	always #(HALF) clk = ~clk;
	logic clk_cpu = 0;                      // 42 MHz, aligned: toggles on clk's rising edges
	always @(posedge clk) clk_cpu <= ~clk_cpu;
	logic clk_sdram = 0;                    // 126 MHz, the controller's, unrelated in phase
	always #(3.9683) clk_sdram = ~clk_sdram;
	logic rst = 1;

	string set = "avengrgs", save = "";
	int frames = 300, ntrace = 0;

	logic [7:0] sdimg [0:(1 << 25) - 1];
	logic [7:0] eeimg [0:127];

	// ---- the chip ----
	wire  [15:0] SDRAM_DQ;
	wire  [12:0] SDRAM_A;
	wire   [1:0] SDRAM_BA;
	wire         SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS, SDRAM_DQML, SDRAM_DQMH, SDRAM_CLK, SDRAM_CKE;
	sdram_chip_model_wide u_chip (
		.clk(clk_sdram), .SDRAM_DQ, .SDRAM_A, .SDRAM_BA, .SDRAM_nCS, .SDRAM_nWE, .SDRAM_nRAS, .SDRAM_nCAS
	);

	// ---- the DUT ----
	logic         init = 1, ioctl_wait, ldr_busy;
	logic [7:0]   DDRAM_BURSTCNT, DDRAM_BE;
	logic [28:0]  DDRAM_ADDR;
	logic [63:0]  DDRAM_DIN;
	logic         DDRAM_RD, DDRAM_WE;
	logic [31:0]  inputs_n = 32'hffffffff;
	logic         ee_we = 0;
	logic [5:0]   ee_addr = 0;
	logic [15:0]  ee_din = 0;
	logic         parity = 0;
	logic         has146 = 0;             // +HAS146=1: stadhr96's DECO 146
	logic [1:0]   gfx_layout = 0;         // +LAYOUT=n: the mod byte's bits 5:4
	logic         gfx_frac8 = 0;          // +FRAC8=1
	logic         ce_pix, hblank, vblank, hs, vs, vbl_start, line_done, ovr_ev;
	logic [7:0]   r, g, b, volume;
	logic [15:0]  snd_l, snd_r;

	mlc_top #(.DE156(DE156)) dut (
		.clk, .clk_cpu, .clk_sdram, .reset(rst), .video_reset(rst), .init, .pause(1'b0),
		.SDRAM_A, .SDRAM_DQML, .SDRAM_DQMH, .SDRAM_BA, .SDRAM_nCS, .SDRAM_nWE, .SDRAM_nRAS, .SDRAM_nCAS,
		.SDRAM_CLK, .SDRAM_CKE, .SDRAM_DQ,
		.ioctl_download(1'b0), .ioctl_index(16'd0), .ioctl_wr(1'b0), .ioctl_addr(27'd0), .ioctl_dout(8'd0), .ioctl_wait,
		.DDRAM_BUSY(1'b0), .DDRAM_BURSTCNT, .DDRAM_ADDR, .DDRAM_DOUT(64'd0), .DDRAM_DOUT_READY(1'b0),
		.DDRAM_RD, .DDRAM_DIN, .DDRAM_BE, .DDRAM_WE, .ldr_start(1'b0), .ldr_length(28'd0), .ldr_busy,
		.inputs_n, .has146, .gfx_layout, .gfx_frac8, .ee_we, .ee_addr, .ee_din, .flip(1'b0), .hs_addr(17'd0), .hs_din(8'd0), .hs_dout(), .hs_we(1'b0),
		.ce_pix, .r, .g, .b, .hblank, .vblank, .hs, .vs, .vbl_start, .frame_top(), .volume, .snd_l, .snd_r, .line_done, .ovr_ev
	);

	// ---- frames: the scan-out, captured at the video block's pixel strobe ----
	logic [7:0] frame [0:240*320*3-1];
	int nframe = 0, nirq = 0, novr = 0, npix = 0;
	always_ff @(posedge clk) if (!rst) begin
		if (dut.u_core.u_video.pix_valid && dut.u_core.u_video.pix_y >= 8 && dut.u_core.u_video.pix_y <= 247 && dut.u_core.u_video.pix_x < 320) begin
			frame[((dut.u_core.u_video.pix_y - 8) * 320 + dut.u_core.u_video.pix_x) * 3 + 0] <= r;
			frame[((dut.u_core.u_video.pix_y - 8) * 320 + dut.u_core.u_video.pix_x) * 3 + 1] <= g;
			frame[((dut.u_core.u_video.pix_y - 8) * 320 + dut.u_core.u_video.pix_x) * 3 + 2] <= b;
		end
		if (ovr_ev) novr++;
		if (vbl_start) begin
			parity <= ~parity;
		end
	end
	// the interrupt, counted on its rise
	logic irq_d;
	always_ff @(posedge clk) begin
		irq_d <= dut.u_core.irq_pending;
		if (dut.u_core.irq_pending && !irq_d) nirq++;
	end

	// ---- the bus trace: every completed access of the glue ----
	int fd_tr = 0, nacc = 0;
	always_ff @(posedge clk) if (fd_tr != 0 && nacc < ntrace && dut.u_core.served && !dut.u_core.served_d) begin
		$fwrite(fd_tr, "%0d %s %08X %08X %08X\n", nacc, dut.u_core.cache_wr ? "w" : "r",
		        {dut.u_core.cache_addr[26:2], 2'b00},                      // the word, the area bits kept, as MAME's trace
		        dut.u_core.cache_wr ? {{8{~dut.u_core.cache_dsn[3]}}, {8{~dut.u_core.cache_dsn[2]}}, {8{~dut.u_core.cache_dsn[1]}}, {8{~dut.u_core.cache_dsn[0]}}} : 32'hffffffff,
		        dut.u_core.cache_wr ? dut.u_core.cache_din : dut.u_core.rdata);
		nacc++;
	end

	// ---- the sound: one pair per chip sample, as sim/ymz_tb records it (snd_l/r lag the chip by
	// two clocks, inside the same sample) ----
	int audio = 0, fd_au = 0, nsamp = 0, nyw = 0, nyst = 0;
	wire au_strobe = dut.u_core.u_ymz.OP6.SLOT == 5'd0 && dut.u_core.u_ymz.CYCLE_NUM[2:1] == 2'b00 && dut.u_core.u_ymz.CYCLE1_CE;
	logic [3:0] au_d = 0;
	always_ff @(posedge clk) begin
		au_d <= {au_d[2:0], !rst && au_strobe};
		if (fd_au != 0 && au_d[3]) begin
			$fwrite(fd_au, "%c%c%c%c", snd_l[7:0], snd_l[15:8], snd_r[7:0], snd_r[15:8]);
			nsamp <= nsamp + 1;
		end
		if (dut.u_core.bstate == 3'd3 /* B_YMZ */ && dut.u_core.y_ph == 2'd0 && dut.u_core.ymz_ce_raw && !dut.u_core.y_rd) nyw <= nyw + 1;
		if (dut.u_core.ymz_ce_raw && dut.u_core.ymz_stall) nyst <= nyst + 1;
	end

	task automatic save_frame(input int k);
		int fd;
		string name;
		name = $sformatf("debug/core/%s_f%03d.rgb", set, k);
		fd = $fopen(name, "wb");
		if (fd == 0) begin $display("cannot write %s", name); return; end
		for (int i = 0; i < 240*320*3; i++) $fwrite(fd, "%c", frame[i]);
		$fclose(fd);
		$display("frame %0d written to %s (irqs so far %0d, overruns %0d)", k, name, nirq, novr);
	endtask

	function automatic bit in_list(input string s, input int k);
		int v, i, start;
		string tok;
		if (s.len() == 0) return 0;
		start = 0;
		for (i = 0; i <= s.len(); i++) begin
			if (i == s.len() || s[i] == ",") begin
				tok = s.substr(start, i - 1);
				if (tok.len() > 0 && tok.atoi() == k) return 1;
				start = i + 1;
			end
		end
		return 0;
	endfunction

	int fd, n;
	initial begin
		void'($value$plusargs("SET=%s", set));
		void'($value$plusargs("FRAMES=%d", frames));
		void'($value$plusargs("SAVE=%s", save));
		void'($value$plusargs("TRACE=%d", ntrace));
		void'($value$plusargs("AUDIO=%d", audio));
		begin int h146 = 0; void'($value$plusargs("HAS146=%d", h146)); has146 = h146 != 0; end
		begin int lay = 0, f8 = 0; void'($value$plusargs("LAYOUT=%d", lay)); void'($value$plusargs("FRAC8=%d", f8));
			gfx_layout = 2'(lay); gfx_frac8 = f8 != 0; end
		if (audio) fd_au = $fopen({"debug/core/", set, "_audio.raw"}, "wb");

		fd = $fopen({"debug/", set, "_sdram.bin"}, "rb");
		if (fd == 0) begin $display("cannot open debug/%s_sdram.bin (scripts/mlc_layout.py --image)", set); $finish; end
		n = $fread(sdimg, fd); $fclose(fd);
		for (int w = 0; w < (1 << 24); w++) u_chip.mem[w] = {sdimg[2*w + 1], sdimg[2*w]};
		$display("sdram image: %0d bytes", n);
		fd = $fopen({"debug/", set, "_eeprom.bin"}, "rb");
		if (fd == 0) begin $display("cannot open debug/%s_eeprom.bin", set); $finish; end
		n = $fread(eeimg, fd); $fclose(fd);
		if (ntrace > 0) fd_tr = $fopen({"debug/", set, "-boot/", set, "_core.trace"}, "w");

		// the EEPROM image: 64 big-endian words through the dump port, with the core in reset
		repeat (4) @(posedge clk);
		for (int i = 0; i < 64; i++) begin
			@(posedge clk);
			ee_we <= 1'b1; ee_addr <= i[5:0]; ee_din <= {eeimg[2*i], eeimg[2*i + 1]};
		end
		@(posedge clk); ee_we <= 1'b0;

		// the controller's init runs from init's fall; the game from reset's
		init <= 0;
		repeat (600) @(posedge clk);
		rst <= 0;
		$display("running %0d frames", frames);

		while (nframe < frames) begin
			@(posedge clk);
			if (vbl_start) begin
				// the picture is shown a line after it is drawn (mlc_video_timing): line 247 is on
				// screen during line 248, so the frame is saved at the next line start
				if (in_list(save, nframe)) begin
					@(posedge clk);
					while (!dut.u_core.u_video.line_start) @(posedge clk);
					repeat (24) @(posedge clk);
					save_frame(nframe);
				end
				if (nframe % 50 == 0) $display("frame %0d: irqs %0d, overruns %0d, volume %02x", nframe, nirq, novr, volume);
				nframe++;
			end
		end
		$display("done: %0d frames, %0d interrupts, %0d overruns; YMZ writes %0d, stalled chip clocks %0d, sound samples %0d",
		         nframe, nirq, novr, nyw, nyst, nsamp);
		if (fd_au != 0) $fclose(fd_au);
		if (fd_tr != 0) $fclose(fd_tr);
		$finish;
	end

endmodule
