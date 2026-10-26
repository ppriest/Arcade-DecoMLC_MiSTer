// SPDX-License-Identifier: GPL-3.0-or-later
// N read clients, round-robin, and the ROM download's writes at absolute priority, on one
// sdram_port_cdc: sdram_arbiter's interface (rtl/memory/sdram_arbiter.sv), but a read is issued
// whenever the port accepts one, so each client's request can be in flight at once and the
// controller runs them back to back. A queue of client numbers, in issue order, routes the
// answers, which come back in that order.
//
// A client request is captured on its rising edge, so pulse and held clients share the
// arbiter, and a client has at most one outstanding. c_valid follows the port's valid by one
// cycle; c_rdata is latched on it. A write raises dl_busy for one clock once it is queued.
module mlc_port_arbiter #(
	parameter int N  = 2,
	parameter int GB = 16
) (
	input  logic clk,
	input  logic reset,

	output logic         phy_req,
	output logic         phy_we,
	output logic         phy_we16,
	output logic [25:0]  phy_addr,
	output logic [15:0]  phy_wdata,
	input  logic         phy_busy,
	input  logic         phy_valid,
	input  logic [8*GB-1:0] phy_rdata,

	input  logic [N-1:0]      c_req,
	input  logic [26*N-1:0]   c_addr,
	output logic [N-1:0]      c_valid,
	output logic [8*GB-1:0]   c_rdata,

	input  logic         dl_req,
	input  logic [25:0]  dl_addr,
	input  logic [15:0]  dl_data,
	input  logic         dl_we16,
	output logic         dl_busy
);
	localparam int CW = (N > 1) ? $clog2(N) : 1;

	logic [CW-1:0] rr_ptr;
	logic [N-1:0]  pend, c_req_d;
	logic          have_pick;
	logic [CW-1:0] pick;
	always_comb begin
		have_pick = 1'b0;
		pick      = rr_ptr;
		for (int k = 0; k < N; k++) begin
			int unsigned idx;
			idx = (int'(rr_ptr) + k) % N;
			if (!have_pick && pend[idx]) begin
				have_pick = 1'b1;
				pick      = CW'(idx);
			end
		end
	end
	logic [25:0] pick_addr;
	always_comb begin
		pick_addr = 26'd0;
		for (int k = 0; k < N; k++)
			if (k == int'(pick)) pick_addr = c_addr[26*k +: 26];
	end

	// the clients whose reads are in flight, in issue order
	logic [CW-1:0] tq [0:3];
	logic [2:0]    tq_w, tq_r;
	wire  [CW-1:0] head = tq[tq_r[1:0]];

	logic          wr_hold;
	logic [8*GB-1:0] rdata_l;
	assign c_rdata = rdata_l;

	always_ff @(posedge clk) begin
		if (reset) begin
			phy_req <= 1'b0;
			c_valid <= '0;
			dl_busy <= 1'b0;
			wr_hold <= 1'b0;
			rr_ptr  <= '0;
			pend    <= '0;
			c_req_d <= '0;
			tq_w    <= '0;
			tq_r    <= '0;
		end else begin
			phy_req <= 1'b0;
			c_valid <= '0;
			dl_busy <= 1'b0;
			c_req_d <= c_req;
			pend    <= pend | (c_req & ~c_req_d);

			if (phy_valid) begin
				rdata_l       <= phy_rdata;
				c_valid[head] <= 1'b1;
				tq_r          <= tq_r + 3'd1;
			end

			if (wr_hold) begin
				wr_hold <= 1'b0;                 // the writer sees dl_busy and drops its request
			end else if (!phy_busy && !phy_req) begin
				if (dl_req) begin
					phy_req   <= 1'b1;
					phy_we    <= 1'b1;
					phy_we16  <= dl_we16;
					phy_addr  <= dl_addr;
					phy_wdata <= dl_data;
					dl_busy   <= 1'b1;
					wr_hold   <= 1'b1;
				end else if (have_pick) begin
					phy_req  <= 1'b1;
					phy_we   <= 1'b0;
					phy_we16 <= 1'b0;
					phy_addr <= pick_addr;
					tq[tq_w[1:0]] <= pick;
					tq_w     <= tq_w + 3'd1;
					pend[pick] <= 1'b0;
					rr_ptr   <= (int'(pick) == N-1) ? '0 : CW'(int'(pick) + 1);
				end
			end
		end
	end
endmodule
