// SPDX-License-Identifier: GPL-3.0-or-later
// rtl/protection/mlc_deco146.sv against a Python port of MAME's deco_146_base_device
// (scripts/gen_deco146.py), over sim/deco146_tb/gen_ops.py's random operations.
// sim/deco146_tb/run.sh runs it. RUN FROM THE REPOSITORY ROOT.
`timescale 1ns/1ps
module tb_deco146;
	logic clk = 0;
	always #5 clk = ~clk;
	logic reset = 1, rd = 0, wr = 0;
	logic [10:1] addr;
	logic [15:0] din, dout;
	logic [1:0]  be;
	logic        valid;
	mlc_deco146 dut (.clk, .reset, .rd, .wr, .addr, .din, .be, .dout, .valid);

	initial begin
		int f, kind, a, d, m, e, n, bad, nr;
		f = $fopen("obj_iverilog/deco146_ops.txt", "r");
		if (f == 0) $fatal(1, "no ops file");
		repeat (4) @(posedge clk);
		reset <= 0;
		n = 0; bad = 0; nr = 0;
		while ($fscanf(f, "%h %h %h %h %h", kind, a, d, m, e) == 5) begin
			@(posedge clk);
			addr <= a[10:1]; din <= d; be <= {m[15:8] != 0, m[7:0] != 0};
			if (kind) wr <= 1; else rd <= 1;
			@(posedge clk);
			wr <= 0; rd <= 0;
			if (!kind) begin
				do @(posedge clk); while (!valid);
				if (dout !== e[15:0]) begin
					if (bad < 10) $display("op %0d: read %03x RTL %04x MAME %04x", n, a, dout, e);
					bad++;
				end
				nr++;
			end
			n++;
		end
		if (bad == 0) $display("PASS: %0d operations, %0d reads equal MAME's", n, nr);
		else $display("FAIL: %0d of %0d reads differ", bad, nr);
		$finish;
	end
endmodule
