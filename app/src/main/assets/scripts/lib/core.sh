#!/system/bin/sh
# =====================================================================
#  ThermalX v2 - lib/core.sh
#  Fondasi: path, logging, konfigurasi, safe_write (backup+verifikasi+stack),
#  prop/service stack, helper kecil. Di-source oleh semua komponen lain.
#
#  Variabel TX_ROOT (default kosong) hanya untuk pengujian di sysfs tiruan;
#  di device asli selalu kosong sehingga path = /sys, /proc, /dev asli.
# =====================================================================

TX_VER=2.6.0
R="${TX_ROOT:-}"
MODDIR="${MODDIR:-/data/adb/modules/thermalx}"
DATADIR="${TX_DATA:-/data/adb/thermalx}"
BACKUPDIR="$DATADIR/backup"
SCANDIR="$DATADIR/scan"
RUNDIR="$DATADIR/run"
CONF="$DATADIR/thermalx.conf"
LOG="$DATADIR/log.txt"
STACK="$DATADIR/applied_stack"      # satu path sysfs per baris
PROPSTACK="$DATADIR/props_stack"    # key|nilai_lama (kosong = tidak ada)
SVCSTACK="$DATADIR/svc_stack"       # nama service yang kita stop
PROFILE="$SCANDIR/profile.conf"

mkdir -p "$DATADIR" "$BACKUPDIR" "$SCANDIR" "$RUNDIR" 2>/dev/null

# ---------------------------------------------------------------------
# Logging (dengan rotasi supaya tidak memenuhi /data)
# ---------------------------------------------------------------------
log_msg() {
  printf '%s %s\n' "$(date '+%m-%d %H:%M:%S')" "$*" >> "$LOG" 2>/dev/null
}

log_rotate() {
  [ -f "$LOG" ] || return 0
  lr_sz=$(wc -c < "$LOG" 2>/dev/null); lr_sz=${lr_sz:-0}
  if [ "$lr_sz" -gt 262144 ] 2>/dev/null; then
    mv -f "$LOG" "$LOG.old" 2>/dev/null
    : > "$LOG"
  fi
}

uptime_s() {
  { read -r up_a up_b < "$R/proc/uptime"; } 2>/dev/null
  echo "${up_a%.*}"
}

# ---------------------------------------------------------------------
# Konfigurasi
# ---------------------------------------------------------------------
num_or() { # num_or VARNAME DEFAULT  -> pastikan variabel numerik
  eval "nv_cur=\$$1"
  case "$nv_cur" in
    ''|*[!0-9]*) eval "$1=$2" ;;
  esac
}

load_conf() {
  if [ ! -f "$CONF" ] && [ -f "$MODDIR/thermalx.conf.default" ]; then
    cp "$MODDIR/thermalx.conf.default" "$CONF" 2>/dev/null
  fi
  [ -f "$CONF" ] && . "$CONF"
  CONF_VERSION=${CONF_VERSION:-2}
  PRESET=${PRESET:-auto}                    # auto|cool|balanced|extreme
  THERMAL_MODE=${THERMAL_MODE:-auto}        # off|soft|auto|hard
  THERMAL_KILL=${THERMAL_KILL:-0}           # 1 = matikan service thermal permanen (lib/thermalkill.sh)
  BYPASS_THERMAL=${BYPASS_THERMAL:-0}       # 1 = mode hard dipaksa, saling kunci dengan THERMAL_KILL (lib/bypass.sh)
  BYPASS_PREV_MODE=${BYPASS_PREV_MODE:-}    # THERMAL_MODE sebelum bypass, dipakai untuk kembalikan saat bypass off
  TK_BATT_MAX=${TK_BATT_MAX:-45}; TK_SKIN_MAX=${TK_SKIN_MAX:-47}; TK_HOT_SEC=${TK_HOT_SEC:-10}; TK_TICK=${TK_TICK:-2}
  TK_BLOCK=${TK_BLOCK:-1}; TK_BLOCK_AFTER=${TK_BLOCK_AFTER:-2}; TK_KERNEL=${TK_KERNEL:-1}; TK_TRIP_C=${TK_TRIP_C:-90}
  FEAT_THERMAL=${FEAT_THERMAL:-1}
  FEAT_TEMP_MONITOR=${FEAT_TEMP_MONITOR:-1}
  FEAT_FREQ=${FEAT_FREQ:-1}
  FEAT_SCHED=${FEAT_SCHED:-1}
  FEAT_PRIORITY=${FEAT_PRIORITY:-1}
  FEAT_FPS_ENGINE=${FEAT_FPS_ENGINE:-1}
  FEAT_FPSGO_TUNE=${FEAT_FPSGO_TUNE:-1}
  FEAT_SURFACEFLINGER=${FEAT_SURFACEFLINGER:-1}
  FEAT_LOG_REDUCE=${FEAT_LOG_REDUCE:-1}
  FEAT_TOUCH=${FEAT_TOUCH:-1}
  FEAT_IO=${FEAT_IO:-1}
  FEAT_REFRESH=${FEAT_REFRESH:-1}
  FEAT_NETWORK=${FEAT_NETWORK:-1}
  FEAT_RAM=${FEAT_RAM:-1}
  SAFE_SOC_C=${SAFE_SOC_C:-auto}
  SAFE_BATT_C=${SAFE_BATT_C:-43}
  SAFE_SKIN_C=${SAFE_SKIN_C:-46}
  SAFE_HOT_SECONDS=${SAFE_HOT_SECONDS:-20}
  COOLDOWN_SEC=${COOLDOWN_SEC:-180}
  INJECT_C=${INJECT_C:-40}
  TRIP_RAISE_C=${TRIP_RAISE_C:-0}
  POLL_INTERVAL=${POLL_INTERVAL:-3}
  FPS_TICK=${FPS_TICK:-2}
  FG_CHECK_INGAME=${FG_CHECK_INGAME:-5}
  FPS_DROP_PCT=${FPS_DROP_PCT:-90}
  FPS_STABLE_SAMPLES=${FPS_STABLE_SAMPLES:-15}
  FPSGO_AUDITION=${FPSGO_AUDITION:-1}
  FPSGO_DISCOVER=${FPSGO_DISCOVER:-1}
  FPSGO_APPLY_UNVERIFIED=${FPSGO_APPLY_UNVERIFIED:-0}
  FPSGO_AB_WARMUP=${FPSGO_AB_WARMUP:-6}
  FPSGO_AB_WINDOW=${FPSGO_AB_WINDOW:-8}
  FPSGO_AB_SETTLE=${FPSGO_AB_SETTLE:-3}
  FPSGO_AB_REG_PCT=${FPSGO_AB_REG_PCT:-3}
  FPSGO_RELEARN_DAYS=${FPSGO_RELEARN_DAYS:-14}
  PRIO_NICE=${PRIO_NICE:--6}
  PRIO_RT=${PRIO_RT:-0}
  RAM_KILL_BG=${RAM_KILL_BG:-1}
  RAM_DROP_CACHES=${RAM_DROP_CACHES:-0}
  NET_PING_LOG=${NET_PING_LOG:-0}
  SF_BOOT_PROPS=${SF_BOOT_PROPS:-1}
  NOTIFY=${NOTIFY:-1}
  BOOT_FAIL_LIMIT=${BOOT_FAIL_LIMIT:-3}
  BOOT_OK_DELAY=${BOOT_OK_DELAY:-45}
  STAGE_STEP_DELAY=${STAGE_STEP_DELAY:-0}
  SAFE_WINDOW_SEC=${SAFE_WINDOW_SEC:-8}
  EXTRA_GAME_PACKAGES=${EXTRA_GAME_PACKAGES:-}
  # -- hard-mode thermal protection (poin 5): hard mode mematikan lebih banyak
  # proteksi vendor, jadi pengaman software harus LEBIH ketat, bukan sama dengan
  # mode lain. Lihat lib/thermal.sh thermal_eval().
  HARD_SAFE_HOT_SECONDS=${HARD_SAFE_HOT_SECONDS:-8}     # vs SAFE_HOT_SECONDS=20 default
  HARD_EMERGENCY_MARGIN_C=${HARD_EMERGENCY_MARGIN_C:-5} # lewat limit+margin = THERM_STATE=2 instan
  HARD_MON_SEC=${HARD_MON_SEC:-2}                       # vs 4 dtk default (tick_ingame)
  HARD_DEMOTE_AFTER_TRIP=${HARD_DEMOTE_AFTER_TRIP:-1}   # turunkan ke auto otomatis setelah safety trip
  # -- anti-sawtooth FPS level (poin 6): lihat lib/fps.sh fse_tick().
  SAWTOOTH_WINDOW_SEC=${SAWTOOTH_WINDOW_SEC:-45}  # jendela deteksi gantian arah
  SAWTOOTH_FLAPS=${SAWTOOTH_FLAPS:-3}             # berapa kali gantian arah = sawtooth
  SAWTOOTH_LOCK_SEC=${SAWTOOTH_LOCK_SEC:-60}      # kunci level selama ini kalau sawtooth
  for nv in SAFE_BATT_C SAFE_SKIN_C SAFE_HOT_SECONDS COOLDOWN_SEC INJECT_C TRIP_RAISE_C \
            POLL_INTERVAL FPS_TICK FG_CHECK_INGAME FPS_DROP_PCT FPS_STABLE_SAMPLES \
            BOOT_FAIL_LIMIT BOOT_OK_DELAY STAGE_STEP_DELAY SAFE_WINDOW_SEC \
            FPSGO_AB_WARMUP FPSGO_AB_WINDOW FPSGO_AB_SETTLE FPSGO_AB_REG_PCT FPSGO_RELEARN_DAYS \
            HARD_SAFE_HOT_SECONDS HARD_EMERGENCY_MARGIN_C HARD_MON_SEC \
            SAWTOOTH_WINDOW_SEC SAWTOOTH_FLAPS SAWTOOTH_LOCK_SEC; do
    case "$nv" in
      SAFE_BATT_C) num_or $nv 43 ;;   SAFE_SKIN_C) num_or $nv 46 ;;
      SAFE_HOT_SECONDS) num_or $nv 20 ;; COOLDOWN_SEC) num_or $nv 180 ;;
      INJECT_C) num_or $nv 40 ;;      TRIP_RAISE_C) num_or $nv 0 ;;
      POLL_INTERVAL) num_or $nv 3 ;;  FPS_TICK) num_or $nv 2 ;;
      FG_CHECK_INGAME) num_or $nv 5 ;; FPS_DROP_PCT) num_or $nv 90 ;;
      FPS_STABLE_SAMPLES) num_or $nv 15 ;; BOOT_FAIL_LIMIT) num_or $nv 3 ;;
      BOOT_OK_DELAY) num_or $nv 45 ;; STAGE_STEP_DELAY) num_or $nv 0 ;;
      SAFE_WINDOW_SEC) num_or $nv 8 ;;
      FPSGO_AB_WARMUP) num_or $nv 6 ;; FPSGO_AB_WINDOW) num_or $nv 8 ;;
      FPSGO_AB_SETTLE) num_or $nv 3 ;;  FPSGO_AB_REG_PCT) num_or $nv 3 ;;
      FPSGO_RELEARN_DAYS) num_or $nv 14 ;;
      HARD_SAFE_HOT_SECONDS) num_or $nv 8 ;; HARD_EMERGENCY_MARGIN_C) num_or $nv 5 ;;
      HARD_MON_SEC) num_or $nv 2 ;;
      SAWTOOTH_WINDOW_SEC) num_or $nv 45 ;; SAWTOOTH_FLAPS) num_or $nv 3 ;;
      SAWTOOTH_LOCK_SEC) num_or $nv 60 ;;
    esac
  done
  [ "$POLL_INTERVAL" -lt 1 ] && POLL_INTERVAL=1
  [ "$FPS_TICK" -lt 1 ] && FPS_TICK=1
  [ "$FPSGO_AB_WINDOW" -lt 3 ] && FPSGO_AB_WINDOW=3
  [ "$HARD_MON_SEC" -lt 1 ] && HARD_MON_SEC=1
  # profile hasil scan (tier, vendor, dst) - dibuat oleh scan_all
  [ -f "$PROFILE" ] && . "$PROFILE"
  return 0
}

# ---------------------------------------------------------------------
# Wrapper perintah eksternal yang bisa tidak ada / menggantung
# ---------------------------------------------------------------------
HAVE_TIMEOUT=""
command -v timeout >/dev/null 2>&1 && HAVE_TIMEOUT=1
tmo() { # tmo <detik> perintah...
  tmo_s=$1; shift
  if [ -n "$HAVE_TIMEOUT" ]; then timeout "$tmo_s" "$@"; else "$@"; fi
}

getp() { getprop "$1" 2>/dev/null; }

lower() { echo "$*" | tr 'A-Z' 'a-z'; }

# baca satu angka dari file tanpa fork (builtin read). Kosong kalau gagal.
read1() { { read -r r1_v < "$1"; } 2>/dev/null && echo "$r1_v"; }

# ---------------------------------------------------------------------
# Normalisasi suhu -> derajat Celcius integer ("" kalau tidak valid)
# ---------------------------------------------------------------------
norm_temp() {
  nt=$1
  case "$nt" in ''|*[!0-9-]*) return 1 ;; esac
  [ "$nt" -lt 0 ] 2>/dev/null && return 1
  if [ "$nt" -ge 1000 ]; then nt=$((nt / 1000))
  elif [ "$nt" -ge 150 ]; then nt=$((nt / 10)); fi
  [ "$nt" -gt 150 ] && return 1
  echo "$nt"
}

# ---------------------------------------------------------------------
# safe_write <path> <nilai>
#   - tidak pernah menulis nilai yang tidak bisa dikembalikan (backup dulu)
#   - key backup = path (tidak ada tabrakan antar-policy / antar-zona)
#   - verifikasi read-back, hasil dicatat ke $RUNDIR/writes
#   return: 0 ok | 1 node tidak ada/tak terbaca | 2 ditolak kernel
# ---------------------------------------------------------------------
sw_bfile() { echo "$BACKUPDIR/$(echo "$1" | tr '/' '%')"; }

norm_val() { # nilai node dalam bentuk yang bisa ditulis balik
  nv_raw=$(cat "$1" 2>/dev/null) || return 1
  case "$nv_raw" in
    *\[*\]*) nv_raw=$(echo "$nv_raw" | sed -n 's/.*\[\([^]]*\)\].*/\1/p') ;;
  esac
  echo "$nv_raw"
}

stack_drop() { # buang satu path dari STACK + backup-nya
  grep -vxF "$1" "$STACK" > "$STACK.tmp" 2>/dev/null
  mv -f "$STACK.tmp" "$STACK" 2>/dev/null
  rm -f "$(sw_bfile "$1")"
}

safe_write() {
  sw_p=$1; sw_v=$2
  [ -e "$sw_p" ] || return 1
  sw_new=0
  if ! grep -qxF "$sw_p" "$STACK" 2>/dev/null; then
    sw_b=$(sw_bfile "$sw_p")
    if ! norm_val "$sw_p" > "$sw_b.tmp" 2>/dev/null; then rm -f "$sw_b.tmp"; return 1; fi
    [ -s "$sw_b.tmp" ] || { rm -f "$sw_b.tmp"; return 1; }
    mv -f "$sw_b.tmp" "$sw_b"
    echo "$sw_p" >> "$STACK"
    sw_new=1
  fi
  if { echo "$sw_v" > "$sw_p"; } 2>/dev/null; then
    sw_chk=$(norm_val "$sw_p")
    if [ "$(echo $sw_chk)" = "$(echo $sw_v)" ]; then
      echo "ok $sw_p" >> "$RUNDIR/writes"
    else
      echo "diff $sw_p want=$sw_v got=$sw_chk" >> "$RUNDIR/writes"
    fi
    return 0
  fi
  [ "$sw_new" = 1 ] && stack_drop "$sw_p"
  echo "rej $sw_p" >> "$RUNDIR/writes"
  return 2
}

# tulis nilai backup (kondisi awal) ke satu path tanpa menghapusnya dari stack
restore_path() {
  rp_b=$(sw_bfile "$1")
  [ -f "$rp_b" ] || return 1
  rp_o=$(cat "$rp_b" 2>/dev/null)
  [ -n "$rp_o" ] || return 1
  { echo "$rp_o" > "$1"; } 2>/dev/null
}

revert_stack() {
  [ -s "$STACK" ] || { : > "$STACK"; return 0; }
  awk '{a[NR]=$0} END{for(i=NR;i>0;i--) print a[i]}' "$STACK" | while read -r rs_p; do
    [ -n "$rs_p" ] || continue
    restore_path "$rs_p"
    rm -f "$(sw_bfile "$rs_p")"
  done
  : > "$STACK"
}

# ---------------------------------------------------------------------
# Property (non-persisten, dengan backup; nilai lama kosong = dihapus saat revert)
# ---------------------------------------------------------------------
prop_set() {
  ps_k=$1; ps_v=$2
  case "$ps_k" in ro.*) return 1 ;; esac
  if ! grep -q "^$ps_k|" "$PROPSTACK" 2>/dev/null; then
    echo "$ps_k|$(getp "$ps_k")" >> "$PROPSTACK"
  fi
  if command -v resetprop >/dev/null 2>&1; then resetprop "$ps_k" "$ps_v" 2>/dev/null
  else setprop "$ps_k" "$ps_v" 2>/dev/null; fi
}

revert_props() {
  [ -s "$PROPSTACK" ] || { : > "$PROPSTACK"; return 0; }
  while IFS='|' read -r rp_k rp_v; do
    [ -n "$rp_k" ] || continue
    if [ -n "$rp_v" ]; then
      if command -v resetprop >/dev/null 2>&1; then resetprop "$rp_k" "$rp_v" 2>/dev/null
      else setprop "$rp_k" "$rp_v" 2>/dev/null; fi
    else
      resetprop --delete "$rp_k" 2>/dev/null || setprop "$rp_k" "" 2>/dev/null
    fi
  done < "$PROPSTACK"
  : > "$PROPSTACK"
}

# ---------------------------------------------------------------------
# Service init (stop -> start ulang saat revert), hanya yang sedang running
# ---------------------------------------------------------------------
svc_stop() {
  [ "$(getp "init.svc.$1")" = "running" ] || return 1
  grep -qxF "$1" "$SVCSTACK" 2>/dev/null || echo "$1" >> "$SVCSTACK"
  stop "$1" 2>/dev/null
}

revert_services() {
  [ -s "$SVCSTACK" ] || { : > "$SVCSTACK"; return 0; }
  while read -r rv_s; do
    [ -n "$rv_s" ] && start "$rv_s" 2>/dev/null
  done < "$SVCSTACK"
  : > "$SVCSTACK"
}

notify() {
  [ "$NOTIFY" = "1" ] || return 0
  cmd notification post -t "ThermalX" thermalx "$1" >/dev/null 2>&1 &
}

nth_word() { # nth_word <n> <daftar...>  (1-based)
  nw_n=$1; shift
  nw_i=1
  for nw_w in "$@"; do
    [ "$nw_i" = "$nw_n" ] && { echo "$nw_w"; return 0; }
    nw_i=$((nw_i + 1))
  done
  return 1
}
