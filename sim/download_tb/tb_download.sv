// SPDX-License-Identifier: GPL-3.0-or-later
// The ROM download, byte for byte: the .mra image (scripts/build_mra.py --image, MAME's regions
// at their bases) streamed through hps_io's ioctl interface into mlc_sdram_top, then every
// 16-byte unit of the chip read back through a sprite slot and compared with the image
// scripts/mlc_layout.py builds from the region files (debug/<set>_sdram.bin). Two independent
// constructions of the SDRAM contents meet here: the .mra's interleaves and the RTL's address
// transform on one side, the Python layout on the other.
//
//   scripts/run_verilator.sh download_tb [+SET=avengrgs] [+BYTES=n]
//
// +BYTES limits the download to the first n bytes (the comparison follows). RUN FROM THE
// REPOSITORY ROOT.
`timescale 1ns/1ps
module tb_download;
	import mlc_video_pkg::*;

	localparam real HALF = 5.9524;          // 84 MHz
	logic clk = 0;
	always #(HALF) clk = ~clk;
	logic rst = 1;

	string set = "avengrgs";
	int nbytes = 0;

	logic [7:0] img  [0:(1 << 25) - 1];     // the .mra image
	logic [7:0] want [0:(1 << 25) - 1];     // the layout's SDRAM image

	// ---- the chip ----
	wire  [15:0] SDRAM_DQ;
	wire  [12:0] SDRAM_A;
	wire   [1:0] SDRAM_BA;
	wire         SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS, SDRAM_DQML, SDRAM_DQMH, SDRAM_CLK, SDRAM_CKE;
	sdram_chip_model_wide u_chip (
		.clk, .SDRAM_DQ, .SDRAM_A, .SDRAM_BA, .SDRAM_nCS, .SDRAM_nWE, .SDRAM_nRAS, .SDRAM_nCAS
	);

	// ---- the DUT ----
	logic         init = 1;
	logic         ioctl_download = 0, ioctl_wr = 0, ioctl_wait;
	logic [26:0]  ioctl_addr = 0;
	logic [7:0]   ioctl_dout = 0;
	logic [1:0]   spr_req = 0, spr_valid;
	logic [51:0]  spr_addr = 0;
	logic [127:0] spr_rdata;
	logic         cpu_rom_valid, ymz_valid, ldr_busy;
	logic [31:0]  cpu_rom_data;
	logic [7:0]   ymz_data;
	logic [7:0]   DDRAM_BURSTCNT, DDRAM_BE;
	logic [28:0]  DDRAM_ADDR;
	logic [63:0]  DDRAM_DIN;
	logic         DDRAM_RD, DDRAM_WE;

	mlc_sdram_top dut (
		.clk, .reset(rst), .init,
		.SDRAM_A, .SDRAM_DQML, .SDRAM_DQMH, .SDRAM_BA, .SDRAM_nCS, .SDRAM_nWE, .SDRAM_nRAS, .SDRAM_nCAS,
		.SDRAM_CLK, .SDRAM_CKE, .SDRAM_DQ,
		.ioctl_download, .ioctl_index(16'd0), .ioctl_wr, .ioctl_addr, .ioctl_dout, .ioctl_wait,
		.DDRAM_BUSY(1'b0), .DDRAM_BURSTCNT, .DDRAM_ADDR, .DDRAM_DOUT(64'd0), .DDRAM_DOUT_READY(1'b0),
		.DDRAM_RD, .DDRAM_DIN, .DDRAM_BE, .DDRAM_WE, .ldr_start(1'b0), .ldr_length(28'd0), .ldr_busy,
		.spr_req, .spr_addr, .spr_valid, .spr_rdata,
		.cpu_rom_req(1'b0), .cpu_rom_addr(20'd0), .cpu_rom_valid, .cpu_rom_data,
		.ymz_req(1'b0), .ymz_addr(23'd0), .ymz_valid, .ymz_data
	);

	// ---- the download: one byte per clock while ioctl_wait is low, the write in the same
	// step the wait clears (LESSONS, "Backpressure") ----
	int dl_i = 0, dl_n = 0;
	logic dl_run = 0;
	always_ff @(posedge clk) begin
		ioctl_wr <= 1'b0;
		if (dl_run && dl_i < dl_n && !ioctl_wait && !ioctl_wr) begin
			ioctl_wr   <= 1'b1;
			ioctl_addr <= dl_i[26:0];
			ioctl_dout <= img[dl_i];
			dl_i       <= dl_i + 1;
		end
	end

	// ---- read-back through sprite slot 0 ----
	task automatic read_unit(input logic [25:0] a, output logic [127:0] d);
		@(posedge clk);
		spr_req[0]      <= 1'b1;
		spr_addr[25:0]  <= a;
		@(posedge clk);
		spr_req[0] <= 1'b0;
		while (!spr_valid[0]) @(posedge clk);
		d = spr_rdata;
	endtask

	int fd, n, bad = 0, units, t0;
	logic [127:0] got, exp;

	initial begin
		void'($value$plusargs("SET=%s", set));
		void'($value$plusargs("BYTES=%d", nbytes));
		fd = $fopen({"debug/", set, "_mra.bin"}, "rb");
		if (fd == 0) begin $display("cannot open debug/%s_mra.bin (scripts/build_mra.py --image)", set); $finish; end
		n = $fread(img, fd); $fclose(fd);
		$display("mra image: %0d bytes", n);
		dl_n = (nbytes > 0 && nbytes < n) ? nbytes : n;
		fd = $fopen({"debug/", set, "_sdram.bin"}, "rb");
		if (fd == 0) begin $display("cannot open debug/%s_sdram.bin (scripts/mlc_layout.py --image)", set); $finish; end
		n = $fread(want, fd); $fclose(fd);
		$display("layout image: %0d bytes", n);

		repeat (4) @(posedge clk);
		rst  <= 0;
		init <= 0;
		repeat (500) @(posedge clk);            // the controller's own init sequence

		ioctl_download <= 1'b1;
		@(posedge clk);
		dl_run <= 1'b1;
		t0 = $time;
		while (dl_i < dl_n) begin
			@(posedge clk);
			if ((dl_i & 32'h3FFFFF) == 0 && ioctl_wr) $display("  downloaded %0d MB", dl_i >> 20);
		end
		repeat (64) @(posedge clk);
		dl_run <= 1'b0;
		ioctl_download <= 1'b0;
		repeat (64) @(posedge clk);
		$display("download of %0d bytes took %0d clocks", dl_n, ($time - t0) / 11);

		// every unit the download covered, against the layout image
		units = dl_n / 16;
		for (int u = 0; u < units; u++) begin
			read_unit(26'(u * 16), got);
			for (int k = 0; k < 16; k++) exp[8*k +: 8] = want[u * 16 + k];
			if (got !== exp) begin
				bad++;
				if (bad <= 10) $display("MISMATCH unit %07x: got %032x want %032x", u * 16, got, exp);
			end
			if ((u & 32'h3FFFF) == 0 && u) $display("  checked %0d MB", (u * 16) >> 20);
		end
		if (bad == 0) $display("PASS: %0d units (%0d bytes) read back equal to the layout image", units, units * 16);
		else          $display("FAIL: %0d of %0d units differ", bad, units);
		$finish;
	end

endmodule
