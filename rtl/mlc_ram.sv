// SPDX-License-Identifier: GPL-3.0-or-later
// One block RAM in the form Quartus 17 infers as a single true-dual-port M10K: port A writes
// and reads one address, port B reads another, each read registered (one clock). Port A returns
// the new data when it writes (Quartus's TDP template): an old-data read on a written port is
// not an M10K true-dual-port mode, and Quartus duplicates the RAM to provide it. No client reads
// the word it writes in the same clock.
// Wider RAMs with byte enables are built from several of these side by side: Quartus 17 builds
// registers, not M10K, for a byte-lane write in a loop or a part-select write into a wide word
// (docs/LESSONS_LEARNED.md).
module mlc_ram #(
	parameter int W  = 8,
	parameter int AW = 13
) (
	input  logic          clk,
	input  logic          we_a,
	input  logic [AW-1:0] addr_a,
	input  logic [W-1:0]  d_a,
	output logic [W-1:0]  q_a,
	input  logic [AW-1:0] addr_b,
	output logic [W-1:0]  q_b
);
	logic [W-1:0] mem [0:(1 << AW) - 1];

	always_ff @(posedge clk) begin
		if (we_a) begin
			mem[addr_a] <= d_a;
			q_a         <= d_a;
		end else begin
			q_a <= mem[addr_a];
		end
	end

	always_ff @(posedge clk) q_b <= mem[addr_b];
endmodule
