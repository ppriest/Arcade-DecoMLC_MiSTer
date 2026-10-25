// SPDX-License-Identifier: GPL-3.0-or-later
// The per-line sprite engine: scanner, hit FIFO and drawer (docs/phase1_video.md), with the
// VRAM read port shared between the two and the SDRAM side as two slots: a unit fetch takes a
// free slot (the drawer's first, alternating slots), its answer is routed by the slot's tag to
// the scanner, the drawer's table lookup, or the row FIFO the drawer's emitter reads in order.
module mlc_sprite_engine
	import mlc_video_pkg::*;
(
	input  logic         clk,
	input  logic         reset,

	input  logic         line_start,
	input  logic         line_valid,
	input  logic [8:0]   scanline,
	input  logic         parity,
	input  logic         alpha_on,

	// registers
	input  logic [79:0]  clip_min_y,
	input  logic [79:0]  clip_max_y,
	input  logic [79:0]  clip_min_x,
	input  logic [79:0]  clip_max_x,
	input  logic [32:0]  ras_y,
	input  logic [32:0]  ras_x,
	input  logic [29:0]  ras_s,

	// list
	output logic [8:0]   cand_addr,
	input  logic [9:0]   cand_data,
	input  logic [9:0]   cand_count,
	output logic [8:0]   ent_addr,
	input  logic [127:0] ent_data,

	// VRAM read port
	output logic [12:0]  vram_rd_addr,
	input  logic [127:0] vram_rd_data,

	// SDRAM: two arbiter clients, so two 16-byte unit fetches are in flight; responses in
	// issue order (the arbiter is round-robin and each client has at most one outstanding)
	output logic [1:0]   mem_req,          // one-clock pulses
	output logic [51:0]  mem_addr,         // {slot 1, slot 0}
	input  logic [1:0]   mem_valid,
	input  logic [127:0] mem_rdata,        // shared; captured on the slot's valid

	// line buffer
	output logic         lb_we,
	output logic [8:0]   lb_x,
	output logic [10:0]  lb_pen,
	output logic [1:0]   lb_flags,
	output logic         lb_shadow_only,
	input  logic [319:0] lb_written,

	output logic         line_done,        // level: nothing left to do for the line
	output logic         ovr_ev            // pulse: line_start arrived with work unfinished
);

	// ---- scanner ----
	logic         s_vr_req, s_vr_ack;
	logic [12:0]  s_vr_addr;
	logic         s_mem_req, s_mem_ack, s_mem_take;
	logic [25:0]  s_mem_addr;
	logic         hit_push, hit_full, hit_empty, hit_pop, scan_done;
	hit_t         hit_in, hit_out;

	mlc_sprite_scan u_scan (
		.clk, .reset, .line_start, .line_valid, .scanline, .parity,
		.cand_addr, .cand_data, .cand_count, .ent_addr, .ent_data,
		.clip_min_y, .clip_max_y, .ras_y, .ras_x, .ras_s,
		.vr_req(s_vr_req), .vr_addr(s_vr_addr), .vr_ack(s_vr_ack), .vr_data(vram_rd_data),
		.mem_req(s_mem_req), .mem_addr(s_mem_addr), .mem_take(s_mem_take), .mem_ack(s_mem_ack), .mem_rdata,
		.hit_push, .hit(hit_in), .hit_full, .done(scan_done)
	);

	mlc_fifo #(.W($bits(hit_t)), .AW(4)) u_fifo (
		.clk, .reset, .flush(line_start),
		.push(hit_push), .din(hit_in), .full(hit_full),
		.pop(hit_pop), .dout(hit_out), .empty(hit_empty), .count()
	);

	// ---- drawer ----
	logic         d_vr_req, d_vr_ack;
	logic [14:0]  d_vr_addr;
	logic         tab_req, tab_take, tab_ack, row_req, row_take, row_dv, row_pop;
	logic [25:0]  tab_addr, row_addr;
	logic [127:0] row_data;
	logic         draw_busy;

	mlc_sprite_draw u_draw (
		.clk, .reset, .line_start, .alpha_on, .clip_min_x, .clip_max_x,
		.hit_empty, .hit(hit_out), .hit_pop,
		.vr_req(d_vr_req), .vr_addr(d_vr_addr), .vr_ack(d_vr_ack), .vr_data(vram_rd_data),
		.tab_req, .tab_addr, .tab_take, .tab_ack, .tab_rdata(mem_rdata),
		.row_req, .row_addr, .row_take, .row_dv, .row_data, .row_pop,
		.lb_we, .lb_x, .lb_pen, .lb_flags, .lb_shadow_only, .lb_written,
		.busy(draw_busy)
	);

	// ---- VRAM read mux: one-clock reads, the drawer first; a client's request is masked
	// the clock after its ack so a level request is served once ----
	logic d_mask, s_mask;
	wire  d_grant = d_vr_req && !d_mask;
	wire  s_grant = s_vr_req && !s_mask && !d_grant;
	assign vram_rd_addr = d_grant ? d_vr_addr[14:2] : s_vr_addr;
	always_ff @(posedge clk) begin
		d_vr_ack <= d_grant;
		s_vr_ack <= s_grant;
		d_mask   <= d_grant;
		s_mask   <= s_grant;
	end

	// ---- the two SDRAM slots ----
	localparam logic [1:0] T_SCAN = 2'd0, T_TAB = 2'd1, T_ROW = 2'd2;
	logic [1:0] slot_busy, slot_discard;
	logic [1:0] slot_tag [0:1];
	logic       last_slot;
	logic [1:0] row_inflight;              // row fetches issued, not yet in the FIFO

	// the row FIFO: four units; a fetch is issued only when its answer will have room
	logic        rf_push, rf_full, rf_empty;
	logic [2:0]  rf_count;
	logic [127:0] rf_din;
	mlc_fifo #(.W(128), .AW(2)) u_rows (
		.clk, .reset, .flush(line_start),
		.push(rf_push), .din(rf_din), .full(rf_full),
		.pop(row_pop), .dout(row_data), .empty(rf_empty), .count(rf_count)
	);
	assign row_dv = !rf_empty;
	wire   row_credit = ({1'b0, rf_count} + {2'b0, row_inflight}) < 4'd4;

	wire        want_tab  = tab_req;
	wire        want_row  = row_req && row_credit && !want_tab;
	wire        want_scan = s_mem_req && !want_tab && !want_row;
	wire        want      = want_tab || want_row || want_scan;
	wire [1:0]  pick_tag  = want_tab ? T_TAB : want_row ? T_ROW : T_SCAN;
	wire [25:0] pick_addr = want_tab ? tab_addr : want_row ? row_addr : s_mem_addr;
	wire        free0 = !slot_busy[0], free1 = !slot_busy[1];
	wire        use1  = last_slot ? (free0 ? 1'b0 : 1'b1) : (free1 ? 1'b1 : 1'b0);
	wire        issue = want && (free0 || free1) && !line_start;
	assign tab_take   = issue && want_tab;
	assign row_take   = issue && want_row;
	assign s_mem_take = issue && want_scan;

	// answers, routed by tag; a row unit of a line that ended is dropped
	wire v0 = mem_valid[0], v1 = mem_valid[1];
	assign s_mem_ack = (v0 && slot_tag[0] == T_SCAN) || (v1 && slot_tag[1] == T_SCAN);
	assign tab_ack   = (v0 && slot_tag[0] == T_TAB)  || (v1 && slot_tag[1] == T_TAB);
	assign rf_push   = (v0 && slot_tag[0] == T_ROW && !slot_discard[0]) || (v1 && slot_tag[1] == T_ROW && !slot_discard[1]);
	assign rf_din    = mem_rdata;

	always_ff @(posedge clk) begin
		if (reset) begin
			slot_busy    <= '0;
			slot_discard <= '0;
			last_slot    <= 1'b0;
			row_inflight <= '0;
			mem_req      <= '0;
		end else begin
			mem_req <= '0;
			if (issue) begin
				mem_req[use1]            <= 1'b1;
				mem_addr[26*use1 +: 26]  <= pick_addr;
				slot_busy[use1]          <= 1'b1;
				slot_tag[use1]           <= pick_tag;
				slot_discard[use1]       <= 1'b0;
				last_slot                <= use1;
			end
			for (int k = 0; k < 2; k++) begin
				if (mem_valid[k]) slot_busy[k] <= 1'b0;
				if (line_start && slot_busy[k] && slot_tag[k] == T_ROW) slot_discard[k] <= 1'b1;
			end
			row_inflight <= row_inflight + {1'b0, issue && want_row}
			                            - {1'b0, (v0 && slot_tag[0] == T_ROW) || (v1 && slot_tag[1] == T_ROW)};
		end
	end

	assign line_done = scan_done && hit_empty && !draw_busy;

	logic active;
	always_ff @(posedge clk) begin
		if (reset) begin
			active <= 1'b0;
			ovr_ev <= 1'b0;
		end else begin
			ovr_ev <= line_start && active && !line_done;
			if (line_start) active <= line_valid;
		end
	end

endmodule
