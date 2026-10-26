// SPDX-License-Identifier: GPL-3.0-or-later
// A dual-clock FIFO of 2**AW entries: gray-coded pointers, each synchronised into the other
// domain through two registers (the clock domain crossings of rtl/memory/sdram_port_cdc.sv).
// dout is the head entry, combinationally, while !empty; pop advances it. full and empty are
// pessimistic by the synchroniser's delay, never optimistic. Both resets must overlap.
module mlc_async_fifo #(
	parameter int W  = 8,
	parameter int AW = 2
) (
	input  logic         wclk,
	input  logic         wrst,
	input  logic         push,
	input  logic [W-1:0] din,
	output logic         full,

	input  logic         rclk,
	input  logic         rrst,
	input  logic         pop,
	output logic [W-1:0] dout,
	output logic         empty
);
	logic [W-1:0]  mem [0:(1 << AW) - 1];
	logic [AW:0]   wbin, wgray, rbin, rgray;
	logic [AW:0]   wgray_r1, wgray_r2;          // wgray in rclk
	logic [AW:0]   rgray_w1, rgray_w2;          // rgray in wclk

	function automatic logic [AW:0] b2g(input logic [AW:0] b);
		return b ^ (b >> 1);
	endfunction

	// write side
	wire [AW:0] wbin_n = wbin + {{AW{1'b0}}, 1'b1};
	assign full = (b2g(wbin) == {~rgray_w2[AW:AW-1], rgray_w2[AW-2:0]});
	always_ff @(posedge wclk) begin
		if (wrst) begin
			wbin <= '0; wgray <= '0; rgray_w1 <= '0; rgray_w2 <= '0;
		end else begin
			rgray_w1 <= rgray; rgray_w2 <= rgray_w1;
			if (push && !full) begin
				mem[wbin[AW-1:0]] <= din;
				wbin  <= wbin_n;
				wgray <= b2g(wbin_n);
			end
		end
	end

	// read side
	wire [AW:0] rbin_n = rbin + {{AW{1'b0}}, 1'b1};
	assign empty = (rgray == wgray_r2);
	assign dout  = mem[rbin[AW-1:0]];
	always_ff @(posedge rclk) begin
		if (rrst) begin
			rbin <= '0; rgray <= '0; wgray_r1 <= '0; wgray_r2 <= '0;
		end else begin
			wgray_r1 <= wgray; wgray_r2 <= wgray_r1;
			if (pop && !empty) begin
				rbin  <= rbin_n;
				rgray <= b2g(rbin_n);
			end
		end
	end
endmodule
