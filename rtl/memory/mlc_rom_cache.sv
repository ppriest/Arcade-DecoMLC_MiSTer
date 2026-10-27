// SPDX-License-Identifier: GPL-3.0-or-later
// The DE156's program reads on SDRAM port 1: a direct-mapped cache of LINES 16-byte units in
// block RAM, in place of sdram_narrow_bridge's one held unit (the SH-2 has its own 4 KB cache
// and keeps the bridge). The ARM has no cache of its own here (Amber's is off: rtl/cpu/amber
// PROVENANCE.md), so without this every fetch and literal load is an SDRAM burst, and on the
// sprites' worst lines the port's traffic makes the engine overrun (sim/core_tb, stadhr96u).
//
// The client interface is sdram_narrow_bridge's with WORD_BYTES 4: req pulses with addr held
// until valid pulses, data the 32-bit word (lower address in the low half). A hit answers two
// clocks after req, a miss when its unit arrives. The ROM is read-only; `inval` (the download)
// drops every line.
module mlc_rom_cache #(
	parameter int LINES = 512
) (
	input  logic         clk,
	input  logic         reset,
	input  logic         inval,
	input  logic         req,
	input  logic [25:0]  addr,
	output logic         valid,
	output logic [31:0]  data,

	// the unit fetch on the port's arbiter: g_req held until g_valid
	output logic         g_req,
	output logic [25:0]  g_addr,
	input  logic         g_valid,
	input  logic [127:0] g_data
);
	localparam int IB = $clog2(LINES);
	localparam int TB = 22 - IB;                  // addr[25:4+IB]

	logic [127:0]  dmem [0:LINES-1];
	logic [TB-1:0] tmem [0:LINES-1];
	logic [LINES-1:0] vbits;

	typedef enum logic [2:0] {C_IDLE, C_LOOK, C_WAIT, C_DRAIN} cstate_t;
	cstate_t st;

	wire  [IB-1:0] idx = addr[4 +: IB];
	wire  [TB-1:0] tag = addr[25 -: TB];
	logic [127:0]  d_q;
	logic [TB-1:0] t_q;
	logic          v_q;
	logic [1:0]    wsel;
	logic [IB-1:0] idx_r;

	// block RAM: registered reads at req, one write port for the fill
	always_ff @(posedge clk) begin
		if (st == C_IDLE && req) begin
			d_q <= dmem[idx];
			t_q <= tmem[idx];
		end
		if (st == C_WAIT && g_valid) begin
			dmem[idx_r] <= g_data;
			tmem[idx_r] <= tag;
		end
	end

	assign g_addr = {addr[25:4], 4'b0};
	assign g_req  = (st == C_WAIT);

	always_ff @(posedge clk) begin
		valid <= 1'b0;
		if (reset) begin
			st    <= C_IDLE;
			vbits <= '0;
		end else begin
			if (inval) vbits <= '0;
			case (st)
				C_IDLE: if (req) begin
					v_q   <= vbits[idx] && !inval;
					idx_r <= idx;
					wsel  <= addr[3:2];
					st    <= C_LOOK;
				end
				C_LOOK: begin
					if (v_q && t_q == tag) begin
						data  <= d_q[32*wsel +: 32];
						valid <= 1'b1;
						st    <= C_DRAIN;
					end else begin
						st <= C_WAIT;
					end
				end
				C_WAIT: if (g_valid) begin
					data  <= g_data[32*wsel +: 32];
					valid <= 1'b1;
					if (!inval) vbits[idx_r] <= 1'b1;
					st <= C_DRAIN;
				end
				C_DRAIN: st <= C_IDLE;             // a held req is the same request; the client pulses
				default: st <= C_IDLE;
			endcase
		end
	end
endmodule
