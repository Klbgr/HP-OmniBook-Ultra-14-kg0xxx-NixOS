# Collects system / GPU / sound / Wi-Fi diagnostics. Run as root: sudo omnibook-diag
# `--cpu-load` adds a ~4 min CPU load test (1, 2, 6, 12 busy cores).
# The report goes to /boot (the FAT ESP, readable from Windows) when mounted.

if [[ $EUID -ne 0 ]]; then
  echo "run as root (sudo omnibook-diag)" >&2
  exit 1
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

  section "CPU frequency and idle"
  for p in /sys/devices/system/cpu/cpufreq/policy*; do
    [[ -d $p ]] || continue
    printf '%s: cpus=%s driver=%s governor=%s cur=%s min=%s max=%s hw=%s-%s\n' \
      "${p##*/}" "$(cat $p/related_cpus)" "$(cat $p/scaling_driver)" \
      "$(cat $p/scaling_governor)" "$(cat $p/scaling_cur_freq)" \
      "$(cat $p/scaling_min_freq)" "$(cat $p/scaling_max_freq)" \
      "$(cat $p/cpuinfo_min_freq)" "$(cat $p/cpuinfo_max_freq)"
    printf '  available: %s\n  boost: %s\n' \
      "$(cat $p/scaling_available_frequencies 2>/dev/null)" \
      "$(cat $p/boost $p/scaling_boost_frequencies 2>/dev/null | tr '\n' ' ')"
  done
  run cat /sys/devices/system/cpu/cpufreq/boost
  if [[ ${1:-} == --cpu-load ]]; then
    # scaling_cur_freq is the kernel's view; cpuinfo_cur_freq asks the firmware.
    sample() {
      printf '[%ss]\n' "$1"
      for p in /sys/devices/system/cpu/cpufreq/policy*; do
        printf '%s: scaling_cur=%s cpuinfo_cur=%s max=%s\n' "${p##*/}" \
          "$(cat $p/scaling_cur_freq)" "$(cat $p/cpuinfo_cur_freq 2>/dev/null)" \
          "$(cat $p/scaling_max_freq)"
      done
      for z in /sys/class/thermal/thermal_zone*; do
        printf '%s %s\n' "$(cat $z/temp)" "$(cat $z/type)"
      done | sort -rn | head -n 5
      grep -H . /sys/class/thermal/cooling_device*/cur_state 2>/dev/null | grep -v ':0$'
    }
    # matrixprod is a heavy FP load; the default stressor mix draws less power.
    for n in 1 2 6 12; do
      t=25; [[ $n == 12 ]] && t=120
      printf '\n--- stress-ng --cpu %s --cpu-method matrixprod -t %s ---\n' "$n" "$t"
      stress-ng --cpu "$n" --cpu-method matrixprod -t "$t" --metrics-brief 2>&1 \
        | grep -E 'cpu +[0-9]' &
      if [[ $n == 12 ]]; then
        for s in 10 30 60 110; do sleep $((s - ${prev:-0})); prev=$s; sample "$s"; done
      else
        sleep 20; sample 20
      fi
      wait
    done
  fi
  run cat /sys/devices/system/cpu/cpuidle/current_driver /sys/devices/system/cpu/cpuidle/current_governor
  for c in /sys/devices/system/cpu/cpu[0-9]*; do
    [[ -d $c/cpuidle ]] || continue
    printf '%s:' "${c##*/}"
    for s in $c/cpuidle/state*; do
      printf ' %s usage=%s time=%sus' "$(cat $s/name)" "$(cat $s/usage)" "$(cat $s/time)"
    done
    echo
  done
  run ls /sys/bus/scmi_protocol/devices
  run lsmod
  dmesg | grep -iE 'scmi|cpucp|cpufreq|cpuidle|psci' | tail -n 40

  section "sleep"
  run cat /sys/power/mem_sleep
  grep -r . /sys/power/suspend_stats 2>/dev/null
  grep -r . /sys/kernel/debug/qcom_stats 2>/dev/null
  grep -l enabled /sys/devices/platform/soc@0/*/power/wakeup 2>/dev/null

  section "GPU"
  dmesg | grep -iE 'adreno|msm_dpu|\[drm\]|gmu|zap' | tail -n 30
  run ls -l /dev/dri /dev/dri/by-path
  # sysfs reports the edid attribute as 0 bytes, so test its content.
  for e in /sys/class/drm/card*-*/edid; do
    [[ -e $e && $(head -c 1 "$e" | wc -c) -gt 0 ]] || continue
    printf '\n$ edid-decode %s (%s bytes)\n' "$e" "$(wc -c < "$e")"
    edid-decode < "$e" 2>&1
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
