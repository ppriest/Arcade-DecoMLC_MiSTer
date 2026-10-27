// SPDX-License-Identifier: GPL-3.0-or-later
// One sdram.sv port, run on the controller's own clock (clk_sdram, 126 MHz), for clients on clk
// (84 MHz): sdram_phy's client interface, but queued, so a client may keep requests in flight
// and the controller can start the next as soon as one ends. The clocks come from one PLL but
// are treated as asynchronous (DecoMLC.sdc): requests and answers cross through
// mlc_async_fifo, nothing else does.
//
//   clk side: req pulses while !busy, with we, we16, addr, wdata (sdram_phy's meaning); a read's
//     answer comes back with valid, rdata held until the next valid, in request order. Writes
//     have no answer. busy while the request queue is full or MAXRD reads are unanswered.
//   clk_sdram side: the queue's head goes to the port as soon as the last transaction is
//     acknowledged (port_req toggles, port_ack follows it); a read's 16 bytes are taken the
//     clock its acknowledge arrives, when sdram.sv's dout holds them.
module sdram_port_cdc #(
	parameter int GB    = 16,
	parameter int MAXRD = 3
) (
	input  logic             clk,
	input  logic             reset,         // clk's
	input  logic             clk_sdram,
	input  logic             reset_sdram,   // clk_sdram's, overlapping reset

	input  logic             req,
	input  logic             we,
	input  logic             we16,
	input  logic [25:0]      addr,
	input  logic [15:0]      wdata,
	output logic             busy,
	output logic             valid,
	output logic [8*GB-1:0]  rdata,

	// sdram.sv's port
	output logic [25:1]      port_addr,
	output logic             port_wrl,
	output logic             port_wrh,
	output logic [15:0]      port_din,
	input  logic [8*GB-1:0]  port_dout,
	output logic             port_req,
	input  logic             port_ack
);
	localparam int QW = 1 + 1 + 1 + 25 + 16;     // we, wrl, wrh, addr[25:1], din

	// requests, clk to clk_sdram
	logic          q_full, q_empty, q_pop;
	logic [QW-1:0] q_din, q_dout;
	assign q_din = {we, we && (we16 || !addr[0]), we && (we16 || addr[0]), addr[25:1],
	                we16 ? wdata : {wdata[7:0], wdata[7:0]}};
	mlc_async_fifo #(.W(QW), .AW(2)) u_req (
		.wclk(clk), .wrst(reset), .push(req), .din(q_din), .full(q_full),
		.rclk(clk_sdram), .rrst(reset_sdram), .pop(q_pop), .dout(q_dout), .empty(q_empty)
	);

	// answers, clk_sdram to clk
	logic              a_full, a_empty, a_push, a_pop;
	logic [8*GB-1:0]   a_dout;
	mlc_async_fifo #(.W(8 * GB), .AW(2)) u_ans (
		.wclk(clk_sdram), .wrst(reset_sdram), .push(a_push), .din(port_dout), .full(a_full),
		.rclk(clk), .rrst(reset), .pop(a_pop), .dout(a_dout), .empty(a_empty)
	);

	// clk side: reads in flight, and the answers handed out
	logic [2:0] n_rd;
	assign busy  = q_full || (n_rd >= 3'(MAXRD));
	assign a_pop = !a_empty;
	always_ff @(posedge clk) begin
		valid <= 1'b0;
		if (reset) n_rd <= '0;
		else begin
			n_rd <= n_rd + {2'b0, req && !we} - {2'b0, a_pop};
			if (a_pop) begin
				valid <= 1'b1;
				rdata <= a_dout;
			end
		end
	end

	// clk_sdram side: one transaction at a time on the port, back to back
	logic t_busy, t_rd;
	assign q_pop = !q_empty && !t_busy;
	assign a_push = t_busy && t_rd && (port_ack == port_req);
	always_ff @(posedge clk_sdram) begin
		if (reset_sdram) begin
			t_busy   <= 1'b0;
			port_req <= port_ack;
		end else if (t_busy) begin
			if (port_ack == port_req) t_busy <= 1'b0;
		end else if (!q_empty) begin
			{t_rd, port_wrl, port_wrh, port_addr, port_din} <= {!q_dout[QW-1], q_dout[QW-2:0]};
			port_req <= ~port_req;
			t_busy   <= 1'b1;
		end
	end
endmodule
