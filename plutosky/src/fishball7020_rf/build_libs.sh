#!/bin/bash
# build_libs.sh — package all ADI library IPs needed for fishball7020_rf
# Run once before rebuild.tcl if IPs have not been packaged yet.
# Usage: bash build_libs.sh

VIVADO="${VIVADO:-/c/Xilinx/Vivado/2022.1}/bin/vivado"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/../maia-sdr/maia-hdl/adi-hdl/library"

LIBS=(
  axi_sysid
  sysid_rom
  axi_ad9361
  axi_dmac
  util_cpack2
  util_upack2
  util_clkdiv
  util_tdd_sync
  util_rfifo
  util_wfifo
  util_reduced_logic
)

for ip in "${LIBS[@]}"; do
  ip_tcl="$LIB/$ip/${ip}_ip.tcl"
  if [ ! -f "$ip_tcl" ]; then
    echo "SKIP: $ip — no _ip.tcl found"
    continue
  fi
  echo "=== Packaging $ip ==="
  (cd "$LIB/$ip" && ADI_IGNORE_VERSION_CHECK=1 "$VIVADO" -mode batch -source "${ip}_ip.tcl" -notrace 2>&1 | tail -5)
  echo ""
done

echo "=== All IPs packaged ==="
