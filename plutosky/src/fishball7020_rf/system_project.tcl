source ../maia-sdr/maia-hdl/adi-hdl/scripts/adi_env.tcl
source $ad_hdl_dir/projects/scripts/adi_project_xilinx.tcl
source $ad_hdl_dir/projects/scripts/adi_board.tcl

# fishball7020: XC7Z020-2CLG400I (speed grade -2, industrial temp)
adi_project_create fishball7020_rf 0 {} "xc7z020clg400-2"

adi_project_files fishball7020_rf [list "$ad_hdl_dir/library/common/ad_iobuf.v" "system_constr.xdc" "system_top.v"]

# Use improved implementation strategy for best timing results (matches maia pluto flow)
set_property strategy Performance_ExplorePostRoutePhysOpt [get_runs impl_1]

set_property is_enabled false [get_files *system_sys_ps7_0.xdc]
adi_project_run fishball7020_rf
source $ad_hdl_dir/library/axi_ad9361/axi_ad9361_delay.tcl
