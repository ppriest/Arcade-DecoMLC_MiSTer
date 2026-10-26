// SPDX-License-Identifier: GPL-3.0-or-later
// The DE156's coprocessor 0 on the Amber core (rtl/cpu/amber/a23_coprocessor.v) against MAME's
// arithmetic: sim/amber_tb/gen_cp0.py writes the program and the expected results;
// sim/amber_tb/run_cp0.sh runs it. The CPU runs at one enable in six, held while the
// coprocessor is busy, as in the core; reads answer after +delay clocks.
`timescale 1ns/1ps
module tb_cp0;
	logic clk = 0;
	always #5 clk = ~clk;
	logic rst = 1;
	logic [2:0] div = 0;
	always_ff @(posedge clk) div <= (div == 3'd5) ? 3'd0 : div + 3'd1;
	wire ce = div == 3'd0;

	logic [31:0] mem [0:4095];           // 16 KB from 0
	logic [31:0] expect_r [0:1023];
	wire  [31:0] adr, wdat;
	wire  [3:0]  sel;
	wire         we, cyc, stb, tga, busy;
	logic [7:0]  lat = 0;
	int          delay = 2, nexp = 0, nres = 0, bad = 0, nbusy = 0;
	wire         req = cyc && stb;
	wire         ack = req && (lat >= delay);
	wire  [31:0] rdat = ack ? mem[adr[13:2]] : 32'hffffffff;

	a23_core cpu (
		.i_clk(clk), .i_reset(rst), .i_irq(1'b0), .i_firq(1'b0), .i_system_rdy(ce && !busy),
		.o_wb_adr(adr), .o_wb_sel(sel), .o_wb_we(we), .i_wb_dat(rdat), .o_wb_dat(wdat),
		.o_wb_cyc(cyc), .o_wb_stb(stb), .i_wb_ack(ack), .i_wb_err(1'b0), .o_wb_tga(tga),
		.o_copro_busy(busy)
	);

	always_ff @(posedge clk) begin
		if (rst || !req) lat <= 0; else if (!ack) lat <= lat + 1'b1;
		if (busy) nbusy <= nbusy + 1;
		if (ack && we) begin
			for (int k = 0; k < 4; k++) if (sel[k]) mem[adr[13:2]][8*k +: 8] <= wdat[8*k +: 8];
			if (adr >= 32'h4000 && adr < 32'h5000) begin
				if (wdat !== expect_r[nres]) begin
					if (bad < 10) $display("result %0d: RTL %08x MAME %08x", nres, wdat, expect_r[nres]);
					bad++;
				end
				nres++;
			end
			if (adr == 32'h3ffc) begin
				if (nres != nexp) $display("FAIL: %0d results stored, %0d expected", nres, nexp);
				else if (bad) $display("FAIL: %0d of %0d results differ", bad, nres);
				else $display("PASS: %0d results equal MAME's (delay %0d, %0d busy clocks)", nres, delay, nbusy);
				$finish;
			end
		end
	end

	initial begin
		string dir;
		int f;
		if (!$value$plusargs("DIR=%s", dir)) dir = "obj_iverilog";
		void'($value$plusargs("delay=%d", delay));
		for (int i = 0; i < 4096; i++) mem[i] = 0;
		$readmemh({dir, "/cp0_program.hex"}, mem);
		$readmemh({dir, "/cp0_expect.hex"}, expect_r);
		f = $fopen({dir, "/cp0_expect.hex"}, "r");
		begin logic [31:0] w; while ($fscanf(f, "%h", w) == 1) nexp++; end
		$fclose(f);
		repeat (16) @(negedge clk);
		rst = 0;
		#20000000 $display("FAIL: timeout, %0d results", nres);
		$finish;
	end
endmodule
