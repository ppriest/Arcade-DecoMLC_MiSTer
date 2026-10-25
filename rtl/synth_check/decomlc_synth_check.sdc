# clk_sys = 84 MHz, the value docs/ROADMAP.md proposes: 12x the 7 MHz pixel clock,
# 4x the 21 MHz SH-2. The CPU advances only on ce_r/ce_f, one clock in four each,
# but no multicycle is claimed here: this run measures the core unconstrained
# except for the period, and the Fmax Summary says what it can do. A multicycle
# of 4 on CPU-internal paths would be legitimate only after the gating audit
# Seta's harness documents for TG68K; that audit has not been done on this core.
create_clock -name clk -period 11.905 [get_ports clk]
derive_clock_uncertainty

# Harness artefact: the XOR-reduction register on the output pin.
set_false_path -to [get_keepers {result*}]
