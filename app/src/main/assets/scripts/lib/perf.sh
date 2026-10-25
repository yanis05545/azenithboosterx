#!/system/bin/sh
# =====================================================================
#  ThermalX v2 - lib/perf.sh
#  CPU/GPU "boost level" (0..5), scheduler, prioritas, touch, I/O, FPSGO.
#
#  Beda dari v1: frekuensi TIDAK dikunci min=max selamanya. Yang diatur hanya
#  LANTAI (floor) frekuensi per-cluster/GPU dengan bobot per-cluster, naik
#  turun mengikuti hasil mesin FPS (lib/fps.sh) dan suhu. Semua path berasal
#  dari scan (policy*, devfreq, ged, kgpu), bukan tebakan.
# =====================================================================

LV_MAX=5
LV_CAP=3; LV_START=1; PRESET_EFF=balanced

preset_params() {
  pp=$PRESET
  if [ "$pp" = auto ]; then
    case "${TIER:-mid}" in
      flagship) LV_CAP=4; LV_START=2; PRESET_EFF=balanced ;;
      high)     LV_CAP=4; LV_START=1; PRESET_EFF=balanced ;;
      mid)      LV_CAP=3; LV_START=1; PRESET_EFF=balanced ;;
      *)        LV_CAP=3; LV_START=0; PRESET_EFF=balanced ;;
    esac
    return 0
  fi
  case "$pp" in
    cool)     LV_CAP=2; LV_START=0; PRESET_EFF=cool ;;
    extreme)  LV_CAP=5; LV_START=3; PRESET_EFF=extreme ;;
    *)        LV_CAP=3; LV_START=1; PRESET_EFF=balanced ;;
  esac
}

# ---------------------------------------------------------------------
# C. FREQUENCY FLOOR PER LEVEL
# ---------------------------------------------------------------------
perf_set_cpu_level() {
  pc_lv=$1
  [ -s "$SCANDIR/cpu_policies" ] || return 1
  while IFS='|' read -r pc_n pc_p pc_min pc_max pc_w pc_t; do
    set -- $pc_t
    pc_cnt=$#
    [ "$pc_cnt" -ge 2 ] || continue
    if [ "$pc_lv" -le 0 ]; then restore_path "$pc_p/scaling_min_freq"; continue; fi
    pc_idx=$(( (pc_cnt - 1) * pc_lv * pc_w / (LV_MAX * 100) ))
    pc_f=$(nth_word $((pc_idx + 1)) $pc_t)
    [ -n "$pc_f" ] || continue
    pc_cur=$(read1 "$pc_p/scaling_max_freq")
    if [ -n "$pc_cur" ] && [ "$pc_f" -gt "$pc_cur" ] 2>/dev/null; then
      if [ "$PRESET_EFF" = extreme ]; then safe_write "$pc_p/scaling_max_freq" "$pc_max"
      else pc_f=$pc_cur; fi
    fi
    safe_write "$pc_p/scaling_min_freq" "$pc_f"
  done < "$SCANDIR/cpu_policies"
}

perf_set_gpu_level() {
  pg_lv=$1
  [ "$GPU_BACKEND" = none ] && return 0
  IFS='|' read -r pg_be pg_path pg_minn pg_maxn < "$SCANDIR/gpu"
  [ -n "$pg_path" ] || return 1
  if [ "$pg_lv" -le 0 ]; then restore_path "$pg_path/$pg_minn"; return 0; fi
  [ -s "$SCANDIR/gpu_tbl" ] || return 0        # tanpa tabel OPP: tidak ada skala level
  pg_t=$(cat "$SCANDIR/gpu_tbl"); set -- $pg_t; pg_cnt=$#
  [ "$pg_cnt" -ge 2 ] || return 0
  pg_idx=$(( (pg_cnt - 1) * pg_lv / LV_MAX ))
  pg_f=$(nth_word $((pg_idx + 1)) $pg_t)
  case "$pg_be" in
    devfreq)
      pg_cur=$(read1 "$pg_path/$pg_maxn")
      if [ -n "$pg_cur" ] && [ "$pg_f" -gt "$pg_cur" ] 2>/dev/null; then
        if [ "$PRESET_EFF" = extreme ]; then safe_write "$pg_path/$pg_maxn" "${pg_t##* }"
        else pg_f=$pg_cur; fi
      fi
      safe_write "$pg_path/$pg_minn" "$pg_f" ;;
    mtk_ged|exynos_kgpu)
      safe_write "$pg_path/$pg_minn" "$pg_f" ;;
  esac
}

perf_set_uclamp() {
  pu_lv=$1
  pu_f="$R/dev/cpuctl/top-app/cpu.uclamp.min"
  if [ -e "$pu_f" ]; then
    if [ "$pu_lv" -le 0 ]; then restore_path "$pu_f"; else safe_write "$pu_f" $((pu_lv * 8)); fi
  fi
  pu_s="$R/dev/stune/top-app/schedtune.boost"
  if [ -e "$pu_s" ]; then
    if [ "$pu_lv" -le 0 ]; then restore_path "$pu_s"; else safe_write "$pu_s" $((pu_lv * 5)); fi
  fi
}

perf_set_level() {
  [ "$FEAT_FREQ" = 1 ] || return 0
  pl_lv=$1
  [ "$pl_lv" -gt "$LV_MAX" ] && pl_lv=$LV_MAX
  [ "$pl_lv" -lt 0 ] && pl_lv=0
  perf_set_cpu_level "$pl_lv"
  perf_set_gpu_level "$pl_lv"
  perf_set_uclamp "$pl_lv"
  FSE_LEVEL=$pl_lv
  echo "$pl_lv" > "$RUNDIR/level"
}

# ---------------------------------------------------------------------
# D. SCHEDULER
# ---------------------------------------------------------------------
perf_sched_apply() {
  [ "$FEAT_SCHED" = 1 ] || return 0
  [ -s "$SCANDIR/cpu_policies" ] || return 0
  while IFS='|' read -r ps_n ps_p ps_rest; do
    for ps_f in "$ps_p/schedutil/up_rate_limit_us" "$ps_p/schedutil/rate_limit_us"; do
      [ -e "$ps_f" ] && safe_write "$ps_f" 500
    done
  done < "$SCANDIR/cpu_policies"
  if [ "$PRESET_EFF" = extreme ] && [ "$SOC_VENDOR" = qcom ]; then
    safe_write "$R/proc/sys/kernel/sched_boost" 1
  fi
  log_msg "D: scheduler tuning (preset=$PRESET_EFF)"
}

# ---------------------------------------------------------------------
# E. PRIORITAS PROSES GAME (nice/ionice; RT hanya kalau PRIO_RT=1)
# ---------------------------------------------------------------------
thr_nice() { sed 's/^.*) //' "$R/proc/$1/stat" 2>/dev/null | awk '{print $17}'; }

perf_priority_apply() {
  [ "$FEAT_PRIORITY" = 1 ] || return 0
  pr_pid=$1
  [ -d "$R/proc/$pr_pid" ] || return 1
  : > "$RUNDIR/prio_state"
  pr_o=$(thr_nice "$pr_pid"); pr_o=${pr_o:-0}
  echo "$pr_pid|$pr_o" >> "$RUNDIR/prio_state"
  renice -n "$PRIO_NICE" -p "$pr_pid" >/dev/null 2>&1
  ionice -c 2 -n 0 -p "$pr_pid" >/dev/null 2>&1
  pr_n=0
  for pr_t in "$R/proc/$pr_pid"/task/*; do
    pr_tid=${pr_t##*/}
    { read -r pr_c < "$pr_t/comm"; } 2>/dev/null || continue
    case "$pr_c" in
      UnityMain|UnityGfx*|RenderThread*|GameThread|RHIThread|UE4*|Main\ Thread)
        pr_o=$(thr_nice "$pr_tid"); pr_o=${pr_o:-0}
        echo "$pr_tid|$pr_o" >> "$RUNDIR/prio_state"
        renice -n $((PRIO_NICE - 2)) -p "$pr_tid" >/dev/null 2>&1
        [ "$PRIO_RT" = 1 ] && chrt -f -p 2 "$pr_tid" >/dev/null 2>&1
        pr_n=$((pr_n + 1)) ;;
    esac
  done
  log_msg "E: prioritas pid $pr_pid (nice $PRIO_NICE, thread kunci=$pr_n, rt=$PRIO_RT)"
}

perf_priority_revert() {
  [ -s "$RUNDIR/prio_state" ] || return 0
  while IFS='|' read -r pv_id pv_nice; do
    [ -d "$R/proc/$pv_id" ] || continue
    renice -n "${pv_nice:-0}" -p "$pv_id" >/dev/null 2>&1
    chrt -o -p 0 "$pv_id" >/dev/null 2>&1
  done < "$RUNDIR/prio_state"
  rm -f "$RUNDIR/prio_state"
  log_msg "E: prioritas direvert"
}

# ---------------------------------------------------------------------
# K. TOUCH (hanya node vendor yang benar-benar ada di device)
# ---------------------------------------------------------------------
perf_touch_apply() {
  [ "$FEAT_TOUCH" = 1 ] || return 0
  tc_n=0
  safe_write "$R/sys/module/msm_performance/parameters/touchboost" 1 && tc_n=$((tc_n + 1))
  safe_write "$R/proc/touchpanel/game_switch_enable" 1 && tc_n=$((tc_n + 1))
  tc_f="$R/sys/module/cpu_boost/parameters/input_boost_ms"
  if [ -e "$tc_f" ]; then
    tc_c=$(read1 "$tc_f")
    [ "${tc_c:-0}" -lt 120 ] 2>/dev/null && safe_write "$tc_f" 120 && tc_n=$((tc_n + 1))
  fi
  log_msg "K: touch node vendor dipakai=$tc_n (0 = device tidak punya node touch boost, normal)"
}

# ---------------------------------------------------------------------
# L. I/O (hanya storage flash nyata: sd*, mmcblk*, nvme*; bukan loop/zram/dm)
# ---------------------------------------------------------------------
perf_io_apply() {
  [ "$FEAT_IO" = 1 ] || return 0
  io_n=0
  for io_b in "$R"/sys/block/sd[a-z] "$R"/sys/block/mmcblk[0-9] "$R"/sys/block/nvme[0-9]n[0-9]; do
    [ -d "$io_b/queue" ] || continue
    safe_write "$io_b/queue/read_ahead_kb" 512
    safe_write "$io_b/queue/iostats" 0
    safe_write "$io_b/queue/add_random" 0
    if [ -r "$io_b/queue/scheduler" ]; then
      case " $(cat "$io_b/queue/scheduler" 2>/dev/null | tr -d '[]') " in
        *" none "*) safe_write "$io_b/queue/scheduler" none ;;
        *" noop "*) safe_write "$io_b/queue/scheduler" noop ;;
      esac
    fi
    io_n=$((io_n + 1))
  done
  # clock UFS dinaikkan ke maksimum selama game (loading lebih cepat)
  while read -r io_d; do
    [ -n "$io_d" ] || continue
    io_t=$({ tbl_sort < "$io_d/available_frequencies"; } 2>/dev/null)
    [ -n "$io_t" ] && safe_write "$io_d/min_freq" "${io_t##* }"
  done < "$SCANDIR/ufs_devfreq"
  log_msg "L: I/O dituning pada $io_n perangkat storage"
}

# F. FPSGO: lihat lib/fpsgo.sh (perf_fpsgo_apply)
