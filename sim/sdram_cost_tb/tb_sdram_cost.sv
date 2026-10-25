// SPDX-License-Identifier: GPL-3.0-or-later
// The cost of one 8-byte granule read on the vendored controller, in clocks, for the memory
// plan's fetch budget (docs/ROADMAP.md, Phase 0 exit criterion 5). Port 0 alone against the
// command-decoding chip model: 256 reads at pseudo-random granule addresses (rows and banks
// change between them), each issued the clock after the previous acknowledge, which is how a
// pipelined sprite fetch keeps the port busy. Reports the clocks from request to acknowledge,
// minimum, mean and maximum, and the clocks per read over the whole run (refreshes included).
//
//     scripts/run_sim.sh sdram_cost_tb            (from the repository root)
`timescale 1ns / 1ps
module tb_sdram_cost #(parameter BL8 = 0);

	localparam realtime CLK_PERIOD = 11.905;   // 84 MHz, as the core will run it
	logic clk = 0;
	always #(CLK_PERIOD / 2.0) clk = ~clk;

	wire  [15:0] SDRAM_DQ;
	wire  [12:0] SDRAM_A;
	wire   [1:0] SDRAM_BA;
	wire         SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS;
	wire         SDRAM_DQML, SDRAM_DQMH, SDRAM_CLK, SDRAM_CKE;

	sdram_chip_model_wide u_chip (
		.clk(clk),
		.SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA),
		.SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE),
		.SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS)
	);

	logic        init = 1;
	logic [25:1] addr0 = 0;
	wire  [8*(BL8 ? 16 : 8)-1:0] dout0;
	logic        req0 = 0;
	wire         ack0;

	sdram #(.BL8(BL8)) u_sdram (
		.SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_DQML(SDRAM_DQML),
		.SDRAM_DQMH(SDRAM_DQMH), .SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS),
		.SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
		.SDRAM_CLK(SDRAM_CLK), .SDRAM_CKE(SDRAM_CKE),
		.init(init), .clk(clk),
		.addr0(addr0), .wrl0(1'b0), .wrh0(1'b0), .din0('0), .dout0(dout0),
		.req0(req0), .ack0(ack0),
		.addr1('0), .wrl1(1'b0), .wrh1(1'b0), .din1('0), .dout1(), .req1(1'b0), .ack1(),
		.addr2('0), .wrl2(1'b0), .wrh2(1'b0), .din2('0), .dout2(), .req2(1'b0), .ack2()
	);

	int lat, lat_min = 1 << 30, lat_max = 0, lat_sum = 0, n = 0, t0, t1;
	logic [31:0] lfsr = 32'hACE1_2345;

	// one granule read: flip req, count clocks until ack follows
	task automatic read_granule(input [22:0] g);
		int c;
		@(posedge clk);
		addr0 <= BL8 ? {g[21:0], 3'b000} : {g, 2'b00};
		req0  <= ~req0;
		c = 0;
		@(posedge clk);
		while (ack0 !== req0) begin @(posedge clk); c++; end
		lat = c + 1;
		if (lat < lat_min) lat_min = lat;
		if (lat > lat_max) lat_max = lat;
		lat_sum += lat;
		n++;
	endtask

	initial begin
		$display("=== granule read cost on sdram.sv at 84 MHz, port 0, back to back: BL8 = %0d, %0d-byte granules ===", BL8, BL8 ? 16 : 8);
		repeat (10) @(posedge clk);
		init <= 0;
		repeat (400) @(posedge clk);
		t0 = $time / CLK_PERIOD;
		for (int i = 0; i < 256; i++) begin
			lfsr = {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
			read_granule(lfsr[22:0]);
		end
		t1 = $time / CLK_PERIOD;
		$display("256 reads: request-to-acknowledge min %0d, mean %.1f, max %0d clocks; %.1f clocks per read end to end (refreshes included)",
		         lat_min, real'(lat_sum) / real'(n), lat_max, real'(t1 - t0) / real'(n));
		$display("PASS: measured");
		$finish;
	end

endmodule
