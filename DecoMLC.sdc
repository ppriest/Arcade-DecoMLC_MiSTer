derive_pll_clocks
derive_clock_uncertainty

# core specific constraints

# clk_sdram (PLL output 3, 126 MHz) meets the rest only through sdram_port_cdc's dual-clock
# FIFOs and two-register synchronisers (rtl/memory/mlc_sdram_top.sv)
set_clock_groups -asynchronous \
	-group [get_clocks {emu|pll|pll_inst|altera_pll_i|general[3].gpll~PLL_OUTPUT_COUNTER|divclk}] \
	-group [get_clocks {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk \
	                    emu|pll|pll_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk}]
