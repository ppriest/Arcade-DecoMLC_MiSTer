// SPDX-License-Identifier: GPL-3.0-or-later
// The sprite list: the live RAM the CPU writes, the snapshot copied at vblank start that a
// frame is drawn from (deco_mlc_v.cpp 535-547), and the per-frame candidate list
// (docs/phase1_video.md, "Candidate list").
//
// 384 entries of 8 words; the CPU sees 16-bit words in 32-bit slots (mlc 254-280). The snapshot
// is eight lane RAMs, one per word position, so the engine reads a whole entry in one clock and
// a CPU write landing during the copy can be written through to the lane it belongs to
// (LESSONS, "A snapshot is a race with whoever writes the thing being copied"): a write at or
// below the copy's read cursor is held one clock and applied when its lane is not the one the
// copy is writing. The game writes the list in lines 13-150, never in blanking
// (docs/write_timing_mame.txt), so the path is for safety.
//
// After the copy, the candidate walk (v 161-171), three clocks an entry: at entry i, if entry
// i+1 has 0x1000 and 0x8000 the pair (main i+1) is one candidate and i+1 is consumed; else
// entry i is a candidate when enabled and not auto-flickered off this frame. Candidates are
// {pair, index}, in list order.
module mlc_sprite_list (
	input  logic         clk,
	input  logic         reset,

	// CPU side
	input  logic         cpu_we,
	input  logic [11:0]  cpu_addr,      // slot 0..3071
	input  logic [15:0]  cpu_wdata,
	input  logic [11:0]  cpu_raddr,
	output logic [15:0]  cpu_rdata,     // next clock; the bus pads the upper half with 0xffff

	// frame control
	input  logic         snap_start,    // pulse at vblank start: copy, then build
	input  logic         parity,        // frame parity for auto-flicker (v 170)
	output logic         busy,          // copy or build in progress

	// engine
	input  logic [8:0]   ent_addr,      // entry 0..383
	output logic [127:0] ent_data,      // next clock; word k at [16k +: 16]
	input  logic [8:0]   cand_addr,
	output logic [9:0]   cand_data,     // next clock: {pair, index}
	output logic [9:0]   cand_count     // valid once busy is low
);

	// Live RAM
	logic [15:0] live [0:3071];
	logic [11:0] cursor;                // copy: address read this clock
	logic [15:0] live_q;                // live[cursor] of the previous clock
	always_ff @(posedge clk) begin
		if (cpu_we) live[cpu_addr] <= cpu_wdata;
		cpu_rdata <= live[cpu_raddr];
		live_q    <= live[cursor];
	end

	typedef enum logic [2:0] {S_IDLE, S_COPY, S_SETTLE, S_B_RD0, S_B_RD1, S_B_DEC} state_t;
	state_t state;

	logic [11:0] cursor_d;              // address whose data is live_q
	logic        cursor_d_v;

	// write-through hold
	logic        hold_v;
	logic [11:0] hold_a;
	logic [15:0] hold_d;
	wire hold_apply = hold_v && !(cursor_d_v && hold_a[2:0] == cursor_d[2:0]);

	// Snapshot lanes
	logic [7:0]   snap_we;
	logic [8:0]   snap_wa [0:7];
	logic [15:0]  snap_wd [0:7];
	logic [8:0]   snap_ra;
	logic [127:0] snap_q;

	always_comb begin
		for (int k = 0; k < 8; k++) begin
			snap_we[k] = 1'b0;
			snap_wa[k] = cursor_d[11:3];
			snap_wd[k] = live_q;
		end
		if (cursor_d_v) snap_we[cursor_d[2:0]] = 1'b1;
		if (hold_apply) begin
			snap_we[hold_a[2:0]] = 1'b1;
			snap_wa[hold_a[2:0]] = hold_a[11:3];
			snap_wd[hold_a[2:0]] = hold_d;
		end
	end

	genvar g;
	generate
		for (g = 0; g < 8; g++) begin : lane
			mlc_ram #(.W(16), .AW(9)) u_ram (
				.clk, .we_a(snap_we[g]), .addr_a(snap_wa[g]), .d_a(snap_wd[g]), .q_a(),
				.addr_b(snap_ra), .q_b(snap_q[16*g +: 16])
			);
		end
	endgenerate

	// Candidate build
	logic [8:0]  bi;                    // entry under decision
	logic [15:0] cur_w0, cur_w1;        // entry bi's words 0 and 1
	logic [9:0]  ccount;
	logic        cand_we;
	logic [8:0]  cand_wa;
	logic [9:0]  cand_wd;
	logic [9:0]  cand_mem [0:383];
	logic [8:0]  build_ra;

	wire [15:0] nxt_w0 = snap_q[15:0];
	wire [15:0] nxt_w1 = snap_q[31:16];
	wire        building = (state == S_B_RD0 || state == S_B_RD1 || state == S_B_DEC);
	wire        cur_on   = cur_w0[15] && !(cur_w1[13] && parity);
	wire        nxt_pair = (bi != 9'd383) && nxt_w1[12] && nxt_w0[15];

	assign snap_ra  = building ? build_ra : ent_addr;
	assign ent_data = snap_q;
	assign busy     = (state != S_IDLE);

	always_ff @(posedge clk) begin
		if (cand_we) cand_mem[cand_wa] <= cand_wd;
		cand_data <= cand_mem[cand_addr];
	end

	always_ff @(posedge clk) begin
		if (reset) begin
			state      <= S_IDLE;
			cursor     <= '0;
			cursor_d   <= '0;
			cursor_d_v <= 1'b0;
			hold_v     <= 1'b0;
			cand_count <= '0;
			cand_we    <= 1'b0;
			build_ra   <= '0;
			bi         <= '0;
			ccount     <= '0;
		end else begin
			cand_we    <= 1'b0;
			cursor_d   <= cursor;
			cursor_d_v <= (state == S_COPY);

			if (hold_apply) hold_v <= 1'b0;
			if (cpu_we && ((state == S_COPY && cpu_addr <= cursor) || state == S_SETTLE)) begin
				// synthesis translate_off
				if (hold_v && !hold_apply) $error("mlc_sprite_list: write-through hold overrun");
				// synthesis translate_on
				hold_v <= 1'b1;
				hold_a <= cpu_addr;
				hold_d <= cpu_wdata;
			end

			case (state)
				S_IDLE: begin
					if (snap_start) begin
						cursor <= '0;
						state  <= S_COPY;
					end
				end

				S_COPY: begin
					if (cursor == 12'd3071) state <= S_SETTLE;
					else                    cursor <= cursor + 12'd1;
				end

				// the last copied word and any held write-through land
				S_SETTLE: begin
					if (!hold_v) begin
						bi       <= '0;
						ccount   <= '0;
						build_ra <= '0;
						state    <= S_B_RD0;
					end
				end

				S_B_RD0: begin                      // snap_ra = bi this clock
					build_ra <= bi + 9'd1;
					state    <= S_B_RD1;
				end

				S_B_RD1: begin                      // snap_q = entry bi; snap_ra = bi+1
					cur_w0 <= nxt_w0;
					cur_w1 <= nxt_w1;
					state  <= S_B_DEC;
				end

				S_B_DEC: begin                      // snap_q = entry bi+1
					if (nxt_pair) begin
						cand_we <= 1'b1; cand_wa <= ccount[8:0]; cand_wd <= {1'b1, bi + 9'd1};
						ccount  <= ccount + 10'd1;
					end else if (cur_on) begin
						cand_we <= 1'b1; cand_wa <= ccount[8:0]; cand_wd <= {1'b0, bi};
						ccount  <= ccount + 10'd1;
					end
					if (bi == 9'd383 || (nxt_pair && bi == 9'd382)) begin
						cand_count <= ccount + ((nxt_pair || cur_on) ? 10'd1 : 10'd0);
						state      <= S_IDLE;
					end else begin
						bi       <= nxt_pair ? bi + 9'd2 : bi + 9'd1;
						build_ra <= nxt_pair ? bi + 9'd2 : bi + 9'd1;
						state    <= S_B_RD0;
					end
				end

				default: state <= S_IDLE;
			endcase
		end
	end

endmodule
