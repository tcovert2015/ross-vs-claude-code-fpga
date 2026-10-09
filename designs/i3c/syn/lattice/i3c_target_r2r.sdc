# =============================================================================
# i3c_target_r2r.sdc  -  ANALYSIS-ONLY overlay, not used for synthesis/map/PAR.
#
# build.tcl applies this on top of the constraints already embedded in the
# routed database (i3c_target.sdc) for a second STA pass that cuts every
# top-level port path, leaving the register-to-register paths only. It answers
# "does the logic itself close at 125 MHz" separately from the pad-bound Avalon
# I/O paths, the same split as reports/quartus/timing_split.txt.
# =============================================================================
set_false_path -from [all_inputs]
set_false_path -to   [all_outputs]
