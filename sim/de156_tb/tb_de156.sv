// SPDX-License-Identifier: GPL-3.0-or-later
// Every word of a DE156 program through jtosman_deco156 against MAME's decrypted region
// (scripts/de156_decrypt_check.py runs it).
`timescale 1ns/1ps
module tb_de156;
	localparam int WORDS = 1 << 18;
	logic [7:0]  raw [0:4*WORDS-1];
	logic [7:0]  dec [0:4*WORDS-1];
	logic [17:0] a;
	logic [17:0] dec_addr;
	logic [31:0] raw_w, dec_w;
	jtosman_deco156 u_dut (.a, .dec_addr, .raw(raw_w), .dec(dec_w));
	function automatic logic [31:0] le(input int k, input bit from_raw);
		return from_raw ? {raw[4*k+3], raw[4*k+2], raw[4*k+1], raw[4*k]}
		                : {dec[4*k+3], dec[4*k+2], dec[4*k+1], dec[4*k]};
	endfunction
	initial begin
		string fr, fd;
		int f, n, bad;
		if (!$value$plusargs("RAW=%s", fr) || !$value$plusargs("DEC=%s", fd)) $fatal(1, "+RAW= +DEC=");
		f = $fopen(fr, "rb"); n = $fread(raw, f); $fclose(f);
		if (n != 4 * WORDS) $fatal(1, "raw: %0d bytes", n);
		f = $fopen(fd, "rb"); n = $fread(dec, f); $fclose(f);
		if (n != 4 * WORDS) $fatal(1, "dec: %0d bytes", n);
		bad = 0;
		for (int k = 0; k < WORDS; k++) begin
			a = 18'(k);
			#1 raw_w = le(int'(dec_addr), 1);
			#1 if (dec_w !== le(k, 0)) begin
				if (bad < 8) $display("word %05x: RTL %08x MAME %08x (raw word %05x)", k, dec_w, le(k, 0), dec_addr);
				bad++;
			end
		end
		if (bad == 0) $display("PASS: %0d words identical to MAME's decrypted region", WORDS);
		else $display("FAIL: %0d of %0d words differ", bad, WORDS);
		$finish;
	end
endmodule
