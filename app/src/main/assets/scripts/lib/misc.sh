#!/system/bin/sh
# =====================================================================
#  ThermalX v2 - lib/misc.sh
#  SurfaceFlinger(boot), log, refresh rate, network, RAM, cleanup_all.
# =====================================================================

# ---------------------------------------------------------------------
# I. SurfaceFlinger: prop debug.sf.* hanya dibaca Saat SF start, jadi diset
#    di post-fs-data (sebelum SF jalan). Memanggilnya saat game = tidak ada
#    efek (itu salah di v1). Non-persisten: hilang kalau module dimatikan.
# ---------------------------------------------------------------------
sf_boot_props() {
  [ "$FEAT_SURFACEFLINGER" = 1 ] && [ "$SF_BOOT_PROPS" = 1 ] || return 0
  [ -s "$PROFILE" ] || return 0           # belum pernah scan -> jangan tebak
  case "${TIER:-low}" in low) return 0 ;; esac
  for sb in "debug.sf.latch_unsignaled=1" "debug.sf.disable_backpressure=1"; do
    if command -v resetprop >/dev/null 2>&1; then resetprop "${sb%%=*}" "${sb#*=}" 2>/dev/null
    else setprop "${sb%%=*}" "${sb#*=}" 2>/dev/null; fi
  done
  log_msg "I: prop SurfaceFlinger boot diset (tier=$TIER)"
}

# ---------------------------------------------------------------------
# J. Kurangi overhead logging/tracing (logd TIDAK dimatikan)
# ---------------------------------------------------------------------
log_reduce_apply() {
  [ "$FEAT_LOG_REDUCE" = 1 ] || return 0
  safe_write "$R/proc/sys/kernel/printk" "0 0 0 0"
  safe_write "$R/proc/sys/kernel/sched_schedstats" 0
  safe_write "$R/sys/kernel/tracing/tracing_on" 0
  safe_write "$R/sys/kernel/debug/tracing/tracing_on" 0
  safe_write "$R/sys/module/lowmemorykiller/parameters/debug_level" 0
  prop_set debug.atrace.tags.enableflags 0
  log_msg "J: overhead logging/tracing dikurangi"
}

# ---------------------------------------------------------------------
# M. Refresh rate (backup nilai ASLI; "null" dipulihkan dengan settings delete)
# ---------------------------------------------------------------------
refresh_apply() {
  [ "$FEAT_REFRESH" = 1 ] || return 0
  rf_hz=$(dumpsys display 2>/dev/null | grep -oE '(fps|refreshRate)=[0-9]+(\.[0-9]+)?' | sed 's/.*=//' | sort -n | tail -n1)
  rf_hz=${rf_hz%.*}
  case "$rf_hz" in ''|*[!0-9]*) return 0 ;; esac
  [ "$rf_hz" -ge 61 ] || { log_msg "M: layar hanya ${rf_hz}Hz, skip"; return 0; }
  for rf_k in peak_refresh_rate min_refresh_rate; do
    grep -q "^$rf_k|" "$RUNDIR/settings_backup" 2>/dev/null || \
      echo "$rf_k|$(settings get system "$rf_k" 2>/dev/null)" >> "$RUNDIR/settings_backup"
    settings put system "$rf_k" "$rf_hz" 2>/dev/null
  done
  log_msg "M: refresh rate dikunci ${rf_hz}Hz selama game"
}

refresh_revert() {
  [ -s "$RUNDIR/settings_backup" ] || return 0
  while IFS='|' read -r rr_k rr_v; do
    [ -n "$rr_k" ] || continue
    case "$rr_v" in
      ''|null) settings delete system "$rr_k" >/dev/null 2>&1 ;;
      *) settings put system "$rr_k" "$rr_v" 2>/dev/null ;;
    esac
  done < "$RUNDIR/settings_backup"
  rm -f "$RUNDIR/settings_backup"
  log_msg "M: refresh rate dipulihkan"
}

# ---------------------------------------------------------------------
# N. Network (ping log opsional + dibatasi ukurannya, tidak lagi ping selamanya)
# ---------------------------------------------------------------------
network_apply() {
  [ "$FEAT_NETWORK" = 1 ] || return 0
  safe_write "$R/proc/sys/net/ipv4/tcp_slow_start_after_idle" 0
  safe_write "$R/proc/sys/net/core/rmem_max" 6291456
  safe_write "$R/proc/sys/net/core/wmem_max" 4194304
  nw_c=$(read1 "$R/proc/sys/net/core/rmem_max")
  cmd wifi force-low-latency-mode enabled >/dev/null 2>&1 && : > "$RUNDIR/wifi_ll"
  if [ "$NET_PING_LOG" = 1 ]; then
    ( ping -c 600 -i 2 8.8.8.8 2>/dev/null | while read -r nw_l; do
        echo "$(date '+%H:%M:%S') $nw_l" >> "$DATADIR/ping.log"
        nw_s=$(wc -l < "$DATADIR/ping.log"); [ "${nw_s:-0}" -gt 300 ] && tail -n 150 "$DATADIR/ping.log" > "$DATADIR/ping.log.t" && mv -f "$DATADIR/ping.log.t" "$DATADIR/ping.log"
      done ) >/dev/null 2>&1 &
    echo $! > "$RUNDIR/ping_pid"
  fi
  log_msg "N: network tuning (wifi low-latency=$([ -f "$RUNDIR/wifi_ll" ] && echo ya || echo tidak-didukung))"
}

network_revert() {
  [ -f "$RUNDIR/ping_pid" ] && { kill "$(cat "$RUNDIR/ping_pid")" 2>/dev/null; rm -f "$RUNDIR/ping_pid"; }
  [ -f "$RUNDIR/wifi_ll" ] && { cmd wifi force-low-latency-mode disabled >/dev/null 2>&1; rm -f "$RUNDIR/wifi_ll"; }
}

# ---------------------------------------------------------------------
# O. RAM (min_free_kbytes mengikuti ukuran RAM; drop_caches opsional)
# ---------------------------------------------------------------------
ram_apply() {
  [ "$FEAT_RAM" = 1 ] || return 0
  rm_mb=$((RAM_MB / 128)); [ "$rm_mb" -lt 16 ] && rm_mb=16; [ "$rm_mb" -gt 96 ] && rm_mb=96
  rm_t=$((rm_mb * 1024))
  rm_c=$(read1 "$R/proc/sys/vm/min_free_kbytes")
  if [ -n "$rm_c" ] && [ "$rm_c" -lt "$rm_t" ] 2>/dev/null; then
    safe_write "$R/proc/sys/vm/min_free_kbytes" "$rm_t"
  fi
  [ "$RAM_KILL_BG" = 1 ] && { am kill-all >/dev/null 2>&1; }
  if [ "$RAM_DROP_CACHES" = 1 ]; then sync; echo 1 > "$R/proc/sys/vm/drop_caches" 2>/dev/null; fi
  log_msg "O: RAM manager (min_free=${rm_mb}MB, kill-bg=$RAM_KILL_BG, drop_caches=$RAM_DROP_CACHES)"
}

# ---------------------------------------------------------------------
# cleanup_all - satu jalur pembersihan: game keluar, thermal panas, stop,
# disable, crash (supervisor), uninstall.
# ---------------------------------------------------------------------
cleanup_all() {
  log_msg "cleanup_all()"
  perf_priority_revert
  thermal_revert
  revert_stack
  revert_props
  revert_services
  refresh_revert
  network_revert
  rm -f "$RUNDIR/level" "$RUNDIR/fps_now"
  fpsa_reset_state
  verify_cleanup
}

verify_cleanup() {
  vc_left=0
  [ -s "$STACK" ] && vc_left=1
  [ -s "$PROPSTACK" ] && vc_left=1
  [ -s "$SVCSTACK" ] && vc_left=1
  [ -s "$RUNDIR/settings_backup" ] && vc_left=1
  if [ "$vc_left" = 1 ]; then
    log_msg "WARN: sisa state setelah cleanup, dibersihkan paksa"
    : > "$STACK"; : > "$PROPSTACK"; : > "$SVCSTACK"; rm -f "$RUNDIR/settings_backup"
  fi
  rm -f "$BACKUPDIR"/* 2>/dev/null
}
