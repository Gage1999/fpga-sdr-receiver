# fishball7020_rf/rebuild.tcl
#
# Build the fishball7020_rf bitstream from scratch.
#
# Usage:
#   cd <path-to>/fishball7020_rf
#   $VIVADO/bin/vivado -mode batch -source rebuild.tcl
#
# Output:
#   fishball7020_rf.runs/impl_1/system_top.bit - raw bitstream
#
# Then rebuild BOOT.BIN (see docs/build_guide.md):
#   cd ../boot_parts
#   $VIVADO/bin/bootgen -arch zynq -image fishball7020_rf.bif -o BOOT.bin -w on

set script_dir [file dirname [file normalize [info script]]]
cd $script_dir

source system_project.tcl
