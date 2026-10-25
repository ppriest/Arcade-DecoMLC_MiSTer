// SPDX-License-Identifier: GPL-3.0-or-later
// VRAM, 128 KB: index blocks and tile tables (deco_mlc_v.cpp 307-335, 505-507). Four lanes of
// 32-bit words, so the engine reads a 16-byte index block in one clock and picks a lane for a
// 32-bit table entry; each lane is four byte RAMs (mlc_ram) for the CPU's byte enables. Port A
// is the CPU's (read or write), port B the engine's. Word k of the block at [32k +: 32]; words
// are the SH-2's 32-bit values.
module mlc_vram (
	input  logic         clk,

	input  logic         cpu_we,
	input  logic [14:0]  cpu_addr,      // 32-bit word 0..32767
	input  logic [31:0]  cpu_wdata,
	input  logic [3:0]   cpu_be,        // byte enables, bit 3 = bits 31:24
	output logic [31:0]  cpu_rdata,     // next clock

	input  logic [12:0]  rd_addr,       // 16-byte block 0..8191
	output logic [127:0] rd_data        // next clock
);

	logic [31:0] cpu_q [0:3];
	logic [1:0]  cpu_lane_d;

	genvar g, k;
	generate
		for (g = 0; g < 4; g++) begin : lane
			for (k = 0; k < 4; k++) begin : byte_ram
				mlc_ram #(.W(8), .AW(13)) u_ram (
					.clk,
					.we_a(cpu_we && cpu_addr[1:0] == g[1:0] && cpu_be[k]),
					.addr_a(cpu_addr[14:2]), .d_a(cpu_wdata[8*k +: 8]), .q_a(cpu_q[g][8*k +: 8]),
					.addr_b(rd_addr), .q_b(rd_data[32*g + 8*k +: 8])
				);
			end
		end
	endgenerate

	always_ff @(posedge clk) cpu_lane_d <= cpu_addr[1:0];
	assign cpu_rdata = cpu_q[cpu_lane_d];

endmodule
