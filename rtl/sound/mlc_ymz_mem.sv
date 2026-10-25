// SPDX-License-Identifier: GPL-3.0-or-later
// The YMZ280B's sample ROM on the SDRAM (docs/ROADMAP.md, Memory plan). The chip reads one byte
// at a fixed point of its cycle (YMZ280B.sv: the address a chip clock after the cycle edge, the
// data taken four chip clocks later), which an SDRAM request cannot meet. So the bytes come
// from sixteen held 16-byte units: a read that hits answers at once and fetches the unit after
// it if that is not held, so a channel stepping through a sample always finds its next unit
// waiting; a read that misses (a channel's first after key-on, or after a jump) holds the chip's
// clock enable until its unit arrives (`stall`, counted by the bench; docs/HACKS.md).
//
// Address wiring (deco_mlc.cpp descramble_sound): the chip's address a reads dump byte
// x = {a[23:21], a[19:0], a[20]}; the dump is stored as loaded at YMZ_BASE. Bytes past the
// 6 MB loaded read 0, as MAME's ROMREGION_ERASE00 region does.
//
// Replacement is a clock sweep: each unit has a referenced bit set when it is used or filled;
// the victim pointer passes referenced units (clearing the bit) and rests on one that is not.
module mlc_ymz_mem
	import mlc_video_pkg::*;
(
	input  logic         clk,
	input  logic         reset,
	input  logic         inval,         // the download: drop every unit

	input  logic         ce_in,         // the chip's clock enable, 14 MHz
	output logic         ce_out,        // ce_in, held off while a read waits
	output logic         stall,

	input  logic [23:0]  ma,            // the chip's memory port
	input  logic         moe_n,
	output logic [7:0]   mdi,

	output logic         mem_req,       // one-clock pulse; one in flight
	output logic [25:0]  mem_addr,
	input  logic         mem_valid,
	input  logic [127:0] mem_rdata
);
	localparam int N = 16;

	wire  [23:0] x       = {ma[23:21], ma[19:0], ma[20]};
	wire         x_out   = (x >= 24'h600000);
	wire  [19:0] tag     = x[23:4];
	wire  [19:0] tag_nx  = tag + 20'd1;

	logic [127:0] data  [0:N-1];
	logic [19:0]  tags  [0:N-1];
	logic [N-1:0] valid, refd;
	logic [3:0]   victim;

	logic        hit, nx_held;
	logic [3:0]  hit_i;
	always_comb begin
		hit = 1'b0; hit_i = '0; nx_held = 1'b0;
		for (int k = 0; k < N; k++) begin
			if (valid[k] && tags[k] == tag)    begin hit = 1'b1; hit_i = 4'(k); end
			if (valid[k] && tags[k] == tag_nx) nx_held = 1'b1;
		end
	end

	wire reading = !moe_n;
	assign mdi    = x_out ? 8'h00 : data[hit_i][8*x[3:0] +: 8];
	assign stall  = reading && !x_out && !hit;
	assign ce_out = ce_in && !stall;

	logic        busy;
	logic [19:0] busy_tag;

	always_ff @(posedge clk) begin
		if (reset || inval) begin
			valid   <= '0;
			refd    <= '0;
			victim  <= '0;
			busy    <= 1'b0;
			mem_req <= 1'b0;
		end else begin
			mem_req <= 1'b0;

			if (reading && hit) refd[hit_i] <= 1'b1;

			// the victim pointer rests on an unreferenced unit
			if (!busy && valid[victim] && refd[victim]) begin
				refd[victim] <= 1'b0;
				victim <= victim + 4'd1;
			end

			if (busy) begin
				if (mem_valid) begin
					data[victim]  <= mem_rdata;
					tags[victim]  <= busy_tag;
					valid[victim] <= 1'b1;
					refd[victim]  <= 1'b1;
					victim        <= victim + 4'd1;
					busy          <= 1'b0;
				end
			end else if (reading && !x_out && !hit) begin                    // the miss first
				mem_req  <= 1'b1;
				mem_addr <= YMZ_BASE + {2'b0, tag, 4'b0};
				busy_tag <= tag;
				busy     <= 1'b1;
			end else if (reading && hit && !nx_held && tag_nx < 20'h60000) begin // then the next unit
				mem_req  <= 1'b1;
				mem_addr <= YMZ_BASE + {2'b0, tag_nx, 4'b0};
				busy_tag <= tag_nx;
				busy     <= 1'b1;
			end
		end
	end
endmodule
