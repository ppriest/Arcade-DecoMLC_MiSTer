// SPDX-License-Identifier: GPL-3.0-or-later
// Double-buffered 320-pixel line buffer (docs/phase1_video.md). The pen index lives in RAM, the
// written and shadow flags in registers so the engine's "first opaque pixel wins" test (v 107,
// 124) is a register read and the render bank is cleared in one clock at the swap; no clear pass.
//
// A write with shadow_only ORs the flags (v 114); otherwise the pen is written, written set and
// the flags ORed (v 132-133). The engine only writes where written[wx] is clear and never the
// same x twice in a row, so there is no read-after-write hazard on the registers.
module mlc_line_buffer (
	input  logic         clk,
	input  logic         reset,

	input  logic         swap,          // first clock of a line period: banks exchange roles

	// engine, into the render bank
	input  logic         we,
	input  logic [8:0]   wx,
	input  logic [10:0]  wpen,
	input  logic [1:0]   wflags,
	input  logic         wshadow_only,
	output logic [319:0] written,       // of the render bank

	// scan-out, from the display bank
	input  logic [8:0]   rx,
	output logic [10:0]  rpen,          // next clock
	output logic         rwritten,
	output logic [1:0]   rflags
);

	logic bank;                         // render bank; display is ~bank

	logic [10:0] pen [0:1023];          // {bank, x}: 1024 entries, 320 used per bank
	logic [319:0] wr_a, wr_b;
	logic [1:0]   fl_a [0:319];
	logic [1:0]   fl_b [0:319];

	assign written = bank ? wr_b : wr_a;

	always_ff @(posedge clk) begin
		if (we && !wshadow_only) pen[{bank, wx}] <= wpen;
		rpen <= pen[{~bank, rx}];
	end

	always_ff @(posedge clk) begin
		if (reset) begin
			bank <= 1'b0;
			wr_a <= '0; wr_b <= '0;
			for (int i = 0; i < 320; i++) begin fl_a[i] <= '0; fl_b[i] <= '0; end
		end else begin
			// a write lands in the render bank, in the swap clock too (that bank is the one
			// handed to the display); the swap clears the other bank, the new render one
			if (we) begin
				if (bank) begin
					if (!wshadow_only) wr_b[wx] <= 1'b1;
					fl_b[wx] <= fl_b[wx] | wflags;
				end else begin
					if (!wshadow_only) wr_a[wx] <= 1'b1;
					fl_a[wx] <= fl_a[wx] | wflags;
				end
			end
			if (swap) begin
				bank <= ~bank;
				if (bank) begin
					wr_a <= '0;
					for (int i = 0; i < 320; i++) fl_a[i] <= '0;
				end else begin
					wr_b <= '0;
					for (int i = 0; i < 320; i++) fl_b[i] <= '0;
				end
			end
			rwritten <= bank ? wr_a[rx] : wr_b[rx];
			rflags   <= bank ? fl_a[rx] : fl_b[rx];
		end
	end

endmodule
