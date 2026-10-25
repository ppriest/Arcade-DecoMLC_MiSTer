project_open decomlc_synth_check -revision decomlc_synth_check
create_timing_netlist
read_sdc
update_timing_netlist
report_timing -setup -npaths 30 -detail summary -from_clock clk -to_clock clk \
    -file worst_summary.rpt
delete_timing_netlist
project_close -dont_export_assignments
