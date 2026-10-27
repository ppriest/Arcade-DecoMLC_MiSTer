// SPDX-License-Identifier: GPL-3.0-or-later
// First-word-fall-through FIFO: dout is the head while !empty; pop advances. Flush empties it.
module mlc_fifo #(
	parameter int W = 128,
	parameter int AW = 4
) (
	input  logic          clk,
	input  logic          reset,
	input  logic          flush,
	input  logic          push,
	input  logic [W-1:0]  din,
	output logic          full,
	input  logic          pop,
	output logic [W-1:0]  dout,
	output logic          empty,
	output logic [AW:0]   count          // entries held
);

	logic [W-1:0] mem [0:(1 << AW) - 1];
	logic [AW:0]  wp, rp;

	assign empty = (wp == rp);
	assign full  = (wp[AW-1:0] == rp[AW-1:0]) && (wp[AW] != rp[AW]);
	assign dout  = mem[rp[AW-1:0]];
	assign count = wp - rp;

	always_ff @(posedge clk) begin
		if (push && !full) mem[wp[AW-1:0]] <= din;
	end

	always_ff @(posedge clk) begin
		if (reset || flush) begin
			wp <= '0;
			rp <= '0;
		end else begin
			if (push && !full) wp <= wp + 1'b1;
			if (pop && !empty) rp <= rp + 1'b1;
		end
	end

endmodule
