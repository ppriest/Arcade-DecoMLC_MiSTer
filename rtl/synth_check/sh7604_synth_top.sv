// SPDX-License-Identifier: GPL-3.0-or-later
// Standalone synthesis and timing harness for the SH7604 at clk_sys = 84 MHz.
//
// Not part of the core build. It measures whether jotego's copy of srg320's SH7604,
// enabled one clock in four, closes timing at 84 MHz on this device and speed grade,
// and its size (docs/ROADMAP.md Phase 0 exit criterion 4). The core runs the CPU on
// clk_cpu, a 42 MHz output of the same PLL.
//
// Shape copied from Arcade-Seta_MiSTer rtl/synth_check/seta_synth_top.sv: inputs
// come from a free-running pattern register and every output is XOR-reduced onto
// one pin, so Quartus can neither optimise the CPU away nor fold its decode flat.
// The memory side answers every request one clock later with pattern data, which
// is the jtsh7604 wrapper's zero-wait contract (rtl/cpu/sh7604/README.md).
//
// A synthesis harness, not a simulation model: the program it runs is noise.

`default_nettype none

module sh7604_synth_top (
	input  wire  clk,      // 84 MHz under test
	input  wire  rst_n,
	input  wire  stim,     // feeds the pattern register
	output logic result    // every CPU output, XOR-reduced
);

	wire rst = ~rst_n;

	logic [31:0] pat;
	always_ff @(posedge clk or posedge rst)
		if (rst) pat <= 32'h1234_5678;
		else     pat <= {pat[30:0], pat[31] ^ pat[21] ^ pat[1] ^ stim};

	// 84 MHz / 4 = 21 MHz: ce_r one clock in four, ce_f two clocks later
	// (rtl/cpu/sh7604/README.md, "Clock Enables").
	logic [1:0] ce_cnt;
	always_ff @(posedge clk or posedge rst)
		if (rst) ce_cnt <= 2'd0;
		else     ce_cnt <= ce_cnt + 2'd1;
	wire ce_r = (ce_cnt == 2'd0);
	wire ce_f = (ce_cnt == 2'd2);

	wire [26:0] A;
	wire [31:0] cpu_dout;
	wire        BS_N, CS0_N, CS1_N, CS2_N, CS3_N, RD_WR_N, CE_N, OE_N, RD_N, IVECF_N, RFS, BGR_N, WAIT_N;
	wire [3:0]  WE_N;
	wire        cache_cs, cache_we, cache_rd, cache_wr;
	wire [26:1] cache_addr;
	wire [31:0] cache_din;
	wire [3:0]  cache_dsn;

	// Memory side: acknowledge one clock after a request, data from the pattern.
	logic        cache_ok;
	logic [31:0] cpu_din;
	always_ff @(posedge clk or posedge rst)
		if (rst) begin
			cache_ok <= 1'b0;
			cpu_din  <= 32'd0;
		end else begin
			cache_ok <= cache_cs & (cache_rd | cache_wr) & ~cache_ok;
			cpu_din  <= pat ^ {cache_addr, 6'd0};
		end

	jtsh7604 #(
		.UBC_DISABLE           ( 1'b1      ),
		.SCI_DISABLE           ( 1'b1      ),
		.WDT_DISABLE           ( 1'b1      ),
		.BUS_AREA_TIMIMG       ( 4'h0      ),
		.BUS_SIZE_BYTE_DISABLE ( 1'b0      ),
		.BUS_SIZE_WORD_DISABLE ( 1'b0      ),
		.MD_CFG                ( 6'b010100 )
	) u_cpu (
		.rst                  ( rst          ),
		.clk                  ( clk          ),
		.ce_r                 ( ce_r         ),
		.ce_f                 ( ce_f         ),
		.nmi_n                ( pat[7]       ),
		.irl_n                ( pat[3:0]     ),
		.cpu_din              ( cpu_din      ),
		.cps3_key1            ( 32'd0        ),
		.cps3_key2            ( 32'd0        ),
		.cps3_crypt_mode      ( 3'b010       ),
		.cps3_region          ( 3'd0         ),
		.cps3_region_redearth ( 1'b0         ),
		.cache_ok             ( cache_ok     ),
		.A                    ( A            ),
		.cpu_dout             ( cpu_dout     ),
		.BS_N                 ( BS_N         ),
		.CS0_N                ( CS0_N        ),
		.CS1_N                ( CS1_N        ),
		.CS2_N                ( CS2_N        ),
		.CS3_N                ( CS3_N        ),
		.RD_WR_N              ( RD_WR_N      ),
		.CE_N                 ( CE_N         ),
		.OE_N                 ( OE_N         ),
		.WE_N                 ( WE_N         ),
		.RD_N                 ( RD_N         ),
		.IVECF_N              ( IVECF_N      ),
		.RFS                  ( RFS          ),
		.BGR_N                ( BGR_N        ),
		.WAIT_N               ( WAIT_N       ),
		.cache_cs             ( cache_cs     ),
		.cache_we             ( cache_we     ),
		.cache_rd             ( cache_rd     ),
		.cache_wr             ( cache_wr     ),
		.cache_addr           ( cache_addr   ),
		.cache_din            ( cache_din    ),
		.cache_dsn            ( cache_dsn    )
	);

	// Every output bit folded onto one pin, registered (the false path in the .sdc
	// is on this register, a harness artefact).
	always_ff @(posedge clk)
		result <= ^{A, cpu_dout, BS_N, CS0_N, CS1_N, CS2_N, CS3_N, RD_WR_N, CE_N, OE_N, WE_N,
		            RD_N, IVECF_N, RFS, BGR_N, WAIT_N, cache_cs, cache_we, cache_rd, cache_wr,
		            cache_addr, cache_din, cache_dsn};

endmodule

`default_nettype wire
