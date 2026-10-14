# Collects GPU / sound / Wi-Fi diagnostics. Run as root:
#   omnibook-diag               report only
#   omnibook-diag --wifi NAME   load ath12k now with /etc/omnibook/wlan-bdf/NAME
#                               as board.bin (once per boot)
#   omnibook-diag --wifi default  load ath12k with the built-in board files
# The report goes to /boot (the FAT ESP, readable from Windows) when mounted.

if [[ $EUID -ne 0 ]]; then
  echo "run as root (sudo omnibook-diag)" >&2
  exit 1
fi

if [[ ${1:-} == --wifi ]]; then
  name=${2:-default}
  if [[ $name != default && ! -f /etc/omnibook/wlan-bdf/$name ]]; then
    echo "unknown board file; choose one of: default" >&2
    ls /etc/omnibook/wlan-bdf >&2
    exit 1
  fi
  if [[ -e /sys/module/ath12k_wifi7 ]]; then
    echo "ath12k_wifi7 already loaded: boot with modprobe.blacklist=ath12k_wifi7" >&2
    echo "(press e in the boot menu) to test another board file" >&2
    exit 1
  fi
  if [[ $name != default ]]; then
    src=$(cat /sys/module/firmware_class/parameters/path)
    d=/run/omnibook-fw
    # Real dirs only along ath12k/WCN7850/hw2.0, symlinks everywhere else.
    link_except() {
      mkdir -p "$2/$3"
      for e in "$1"/*; do
        [[ ${e##*/} == "$3" ]] || ln -s "$e" "$2/"
      done
    }
    rm -rf $d && mkdir -p $d
    link_except "$src" $d ath12k
    link_except "$src/ath12k" $d/ath12k WCN7850
    link_except "$src/ath12k/WCN7850" $d/ath12k/WCN7850 hw2.0
    # board-2.bin stays: it also carries the regdb.
    for e in "$src"/ath12k/WCN7850/hw2.0/*; do
      case ${e##*/} in board.bin*) ;; *) ln -s "$e" $d/ath12k/WCN7850/hw2.0/ ;; esac
    done
    cp "/etc/omnibook/wlan-bdf/$name" $d/ath12k/WCN7850/hw2.0/board.bin
    echo -n $d > /sys/module/firmware_class/parameters/path
  fi
  wout=/root/omnibook-wifi.txt
  mountpoint -q /boot && wout=/boot/omnibook-wifi.txt
  n=$(dmesg | wc -l)
  echo "loading ath12k_wifi7 with board file: $name (log: $wout)"
  # BOOT | QMI debug messages (PCI adds one line per interrupt)
  modprobe ath12k debug_mask=0x60
  modprobe ath12k_wifi7
  sleep 30
  { echo "board file: $name"; ls -lL /run/omnibook-fw/ath12k/WCN7850/hw2.0/ 2>&1
    dmesg | tail -n +$((n + 1)) | grep -v 'Modules linked in'
    ls /sys/class/net; } > "$wout" 2>&1
  tail -n 15 "$wout"
  exit 0
fi

out=/root/omnibook-diag.txt
mountpoint -q /boot && out=/boot/omnibook-diag.txt
user=nixos
uid=$(id -u "$user" 2>/dev/null || true)

section() { printf '\n===== %s =====\n' "$*"; }
run() { printf '\n$ %s\n' "$*"; "$@" 2>&1 || printf '(exit %s)\n' "$?"; }
as_user() {
  [[ -n $uid && -d /run/user/$uid ]] || { echo "(no session for $user)"; return; }
  printf '\n$ (as %s) %s\n' "$user" "$*"
  runuser -u "$user" -- env XDG_RUNTIME_DIR="/run/user/$uid" "$@" 2>&1
}

{
  section "system"
  run uname -a
  run cat /proc/cmdline
  run readlink -f /run/current-system /run/booted-system /run/opengl-driver

  section "kernel warnings"
  dmesg | grep -v 'Modules linked in' \
    | grep -E -A 20 'WARNING:|Unable to handle|Internal error|BUG:|Call trace' | head -n 200

  section "previous boot: last kernel messages"
  journalctl -b -1 -k --no-pager -o short-monotonic 2>&1 \
    | grep -v 'Modules linked in' | tail -n 150

  section "GPU"
  dmesg | grep -iE 'adreno|msm_dpu|\[drm\]|gmu|zap' | tail -n 30
  run ls -l /dev/dri /dev/dri/by-path
  for e in /sys/class/drm/card*-eDP-*/edid; do
    [[ -s $e ]] && run edid-decode "$e"
  done
  for c in /sys/class/drm/card*-DP-*; do
    [[ -e $c ]] && printf '%s: %s, %s\n' "${c##*/}" "$(cat $c/status)" "$(cat $c/enabled)"
  done
  dmesg | grep -iE 'msm_dp|dp_ctrl|dp_display|link training|aux_hpd|altmode|ucsi' | tail -n 30
  for so in /run/opengl-driver/lib/libgallium*.so; do
    [[ -e $so ]] || continue
    printf '%s: Mahua id patched in: ' "$so"
    grep -ac 'X2-85 (Mahua)' "$so" || true
  done
  run env EGL_LOG_LEVEL=debug eglinfo -B
  journalctl -b --no-pager -o cat _COMM=kwin_wayland 2>/dev/null \
    | grep -iE 'egl|gbm|drm|llvmpipe|freedreno|render|kms' | tail -n 40

  section "sound"
  run cat /proc/asound/cards
  run aplay -l
  run ls /sys/bus/soundwire/devices
  dmesg | grep -iE 'snd|asoc|wsa|swr|soundwire|apm|gpr|q6|lpass|audio' | tail -n 40
  run alsaucm -c hw:0 list _verbs
  run alsaucm -c hw:0 list _devices/HiFi
  run alsaucm -c hw:0 dump text
  run amixer -c 0 scontrols
  as_user wpctl status
  as_user pactl list cards
  as_user journalctl --user -b --no-pager -o cat -u wireplumber -u pipewire
  journalctl -b --no-pager -o cat _UID="$uid" 2>/dev/null \
    | grep -iE 'wireplumber|pipewire|alsa|ucm|spa\.' | tail -n 60

  section "Wi-Fi"
  run cat /sys/module/firmware_class/parameters/path
  run ls -lL /run/omnibook-fw/ath12k/WCN7850/hw2.0/
  run ls -l /etc/omnibook/wlan-bdf/
  dmesg | grep -iE 'ath12k|mhi' | tail -n 30
  run ls /sys/class/net

  section "Bluetooth"
  dmesg | grep -iE 'bluetooth|hci|qca|btqca|uart14|serial1|wcn7850' | tail -n 30
  run rfkill list
  run btmgmt info
  run bluetoothctl show
  run journalctl -b --no-pager -o cat -u bluetooth

  section "USB"
  run lsusb -t
  dmesg | grep -iE 'usb [0-9]+-|xhci|dwc3|eusb2|repeater|-71' | tail -n 40
} > "$out" 2>&1

echo "report written to $out"
