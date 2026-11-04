#!/usr/bin/env bash
# Copies the HP-signed ADSP/CDSP firmware from this laptop's Windows driver
# store into firmware/ (the files are not redistributable, so they are not in git).
#
#   ./extract-firmware.sh [WINDOWS_DIR]
#
# WINDOWS_DIR defaults to /mnt/c/Windows (WSL). From a Linux live system, mount
# the Windows partition read-only first and pass its Windows directory.
# SUBSYS=... overrides the board id matched in the ADSP driver (default: 8F03103C).
set -euo pipefail

win=${1:-/mnt/c/Windows}
subsys=${SUBSYS:-8F03103C}
store=$win/System32/DriverStore/FileRepository
repo=$(dirname "$(readlink -f "$0")")
dest=$repo/firmware/qcom/glymur/hp/omnibook-ultra-14-kg0xxx

[[ -d $store ]] || { echo "driver store not found: $store" >&2; exit 1; }

# INF files are often UTF-16: drop the NUL bytes before matching. Matching is
# done on variables: with pipefail, `| grep -q` on a large file fails on SIGPIPE.
inf_text() { tr -d '\000' < "$1"; }

adsp=
for d in "$store"/qcsubsys_ext_adsp8480.inf_arm64_*; do
  [[ -f $d/qcsubsys_ext_adsp8480.inf ]] || continue
  t=$(inf_text "$d/qcsubsys_ext_adsp8480.inf")
  [[ ${t^^} == *"SUBSYS_${subsys^^}"* ]] && adsp=$d
done
if [[ -z $adsp ]]; then
  echo "no ADSP driver package for SUBSYS_$subsys; board ids found:" >&2
  for f in "$store"/qcsubsys_ext_adsp8480.inf_arm64_*/qcsubsys_ext_adsp8480.inf; do
    inf_text "$f" | grep -oi 'SUBSYS_[0-9A-F]\{8\}' || true
  done | sort -u >&2
  exit 1
fi

# Several generic CDSP packages can be installed: take the highest DriverVer.
cdsp=$(for d in "$store"/qcnspmcdm8480.inf_arm64_*; do
  [[ -f $d/qcnspmcdm8480.inf ]] || continue
  t=$(inf_text "$d/qcnspmcdm8480.inf")
  v=0
  [[ $t =~ DriverVer[[:space:]]*=[^,]*,[[:space:]]*([0-9.]+) ]] && v=${BASH_REMATCH[1]}
  echo "$v $d"
done | sort -V | tail -n 1 | cut -d' ' -f2-)
[[ -n $cdsp ]] || { echo "no CDSP driver package (qcnspmcdm8480) found" >&2; exit 1; }

find_one() {
  local f
  f=$(find "$1" -iname "$2" -type f -print -quit)
  [[ -n $f ]] || { echo "$2 not found in $1" >&2; exit 1; }
  echo "$f"
}

mkdir -p "$dest"
for pair in "$adsp:qcadsp8480.mbn" "$adsp:adsp_dtbs.elf" "$cdsp:qccdsp8480.mbn" "$cdsp:cdsp_dtbs.elf"; do
  src=$(find_one "${pair%:*}" "${pair##*:}")
  cp "$src" "$dest/${pair##*:}"
  echo "${pair##*:} <- $src"
done
(cd "$dest" && sha256sum ./*)

# CDSP process shells for FastRPC (NPU offload); must match the CDSP firmware.
shells=$repo/dsp/cdsp
mkdir -p "$shells"
for f in fastrpc_shell_3 fastrpc_shell_unsigned_3; do
  src=$(find_one "$cdsp" "$f")
  cp "$src" "$shells/$f"
  echo "$f <- $src"
done
(cd "$shells" && sha256sum ./*)
