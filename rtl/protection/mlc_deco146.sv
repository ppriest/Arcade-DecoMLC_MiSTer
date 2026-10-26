// SPDX-License-Identifier: GPL-3.0-or-later
// The DECO 146 protection chip, as MAME's deco_146_base_device (deco146.cpp) has it, wired as
// deco_mlc.cpp wires it for Stadium Hero '96: its 2 KB window at 0x70f000, one 16-bit word in
// bits 31:16 of each 32-bit slot (mlc 298-313, 368), no address scramble, the magic read xor
// on (set_use_magic_read_address_xor), the input ports unbound (they read 0xffff).
//
// Two banks of 128 words of RAM, written at every write's address (bits 7:1); 1024 read
// addresses, each one table entry (scripts/gen_deco146.py: the RAM word or a port, which input
// nibble goes, rotated, to which output nibble, and whether the xor and nand registers apply).
// The xor register is written at 0x2c, the nand register at 0x36; a read whose entry is RAM
// word 0x78 swaps the banks after it is read. A read of the address just written returns the
// written word unchanged, once. The chip-select configuration area (address bits 14:11 = 8) is
// outside the MLC's window, and chip select 0 decodes the whole window after reset, so neither
// is built. The sound latch port (0x64) is stored like any other word; nothing reads its latch
// on this board.
//
// Read: rd for one clock with addr; dout valid with valid, three clocks later. Write: wr for one
// clock with addr, din and be (bit 1 = bits 15:8).
module mlc_deco146 (
	input  logic         clk,
	input  logic         reset,

	input  logic         rd,
	input  logic         wr,
	input  logic [10:1]  addr,
	input  logic [15:0]  din,
	input  logic [1:0]   be,
	output logic [15:0]  dout,
	output logic         valid
);
	localparam logic [10:0] MAGIC_XOR = 11'h44a;    // deco146_device: magic_read_addr_xor
	localparam logic [7:0]  XOR_PORT  = 8'h2c;
	localparam logic [7:0]  NAND_PORT = 8'h36;
	localparam logic [6:0]  BANK_WORD = 7'h3c;      // bankswap_read_addr 0x78, as a word

	// ---- the read table, 1024 x 31 ----
	logic [31:0] table_rom [0:1023];
	initial $readmemh("rtl/protection/mlc_deco146_table.hex", table_rom);
	logic [31:0] ent;

	// ---- the RAM: two banks of 128 words, one byte RAM per lane ----
	logic [7:0]  ram_hi [0:255];
	logic [7:0]  ram_lo [0:255];
	initial for (int i = 0; i < 256; i++) begin ram_hi[i] = 8'hff; ram_lo[i] = 8'hff; end
	logic [15:0] ram_q;
	logic [7:0]  ram_raddr;

	logic        bank;
	logic [15:0] xor_r, nand_r;
	logic [10:0] latch_addr;
	logic [15:0] latch_data;
	logic        latch_flag;

	wire  [10:0] a     = {addr, 1'b0};
	wire  [7:0]  waddr = {bank, a[7:1]};

	always_ff @(posedge clk) begin
		if (wr && be[1]) ram_hi[waddr] <= din[15:8];
		if (wr && be[0]) ram_lo[waddr] <= din[7:0];
		ram_q <= {ram_hi[ram_raddr], ram_lo[ram_raddr]};
	end

	// the read: s1 has the table entry, s2 the RAM address, s3 the RAM word
	logic        s1, s2, s3, s1_latched, s2_latched, s3_latched;
	logic [15:0] s2_latch_data, s3_latch_data;
	logic [31:0] s2_ent, s3_ent;

	always_ff @(posedge clk) begin
		if (reset) begin
			bank       <= 1'b0;
			xor_r      <= 16'd0;
			nand_r     <= 16'd0;
			latch_addr <= 11'h7ff;              // MAME's 0xffff, outside the window
			latch_data <= 16'd0;
			latch_flag <= 1'b0;
			s1 <= 1'b0; s2 <= 1'b0; s3 <= 1'b0; valid <= 1'b0;
		end else begin
			s1 <= rd; s2 <= s1; s3 <= s2; valid <= s3;

			if (wr) begin
				latch_addr <= a;
				latch_data <= din;
				latch_flag <= 1'b1;
				if (a[7:0] == XOR_PORT) begin
					if (be[1]) xor_r[15:8] <= din[15:8];
					if (be[0]) xor_r[7:0]  <= din[7:0];
				end else if (a[7:0] == NAND_PORT) begin
					if (be[1]) nand_r[15:8] <= din[15:8];
					if (be[0]) nand_r[7:0]  <= din[7:0];
				end
			end

			if (rd) begin
				s1_latched <= (a == latch_addr) && latch_flag;
				latch_flag <= 1'b0;
				ent        <= table_rom[(a ^ MAGIC_XOR) >> 1];
			end

			if (s1) begin
				ram_raddr     <= {bank, ent[6:0]};
				s2_ent        <= ent;
				s2_latched    <= s1_latched;
				s2_latch_data <= latch_data;
				// the swap follows the read, which uses the bank as it was
				if (!s1_latched && ent[8:7] == 2'd0 && ent[6:0] == BANK_WORD) bank <= ~bank;
			end

			if (s2) begin
				s3_ent        <= s2_ent;
				s3_latched    <= s2_latched;
				s3_latch_data <= s2_latch_data;
			end
			if (s3) dout <= s3_latched ? s3_latch_data : finish(s3_ent, s3_ent[8:7] == 2'd0 ? ram_q : 16'hffff);
		end
	end

	// MAME's reorder(), then the xor and the nand
	function automatic logic [15:0] finish(input logic [31:0] e, input logic [15:0] d);
		logic [15:0] r;
		logic [4:0]  f;
		logic [3:0]  n;
		r = 16'd0;
		for (int j = 0; j < 4; j++) begin
			f = e[9 + 5*j +: 5];
			n = d[4*j +: 4];
			case (f[3:2])
				2'd1: n = {n[2:0], n[3]};
				2'd2: n = {n[1:0], n[3:2]};
				2'd3: n = {n[0], n[3:1]};
				default: ;
			endcase
			if (f[4]) r[4*f[1:0] +: 4] = r[4*f[1:0] +: 4] | n;
		end
		if (e[29]) r = r ^ xor_r;
		if (e[30]) r = r & ~nand_r;
		return r;
	endfunction
endmodule
