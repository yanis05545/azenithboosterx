#!/system/bin/sh
# =====================================================================
#  ThermalX v2 - lib/daemon.sh
#  Daemon tunggal + siklus hidup game. Dirancang untuk stabil:
#   * single-instance (pidfile) + supervisor yang restart & membersihkan state
#   * deteksi game murah: pra-filter 'ps' (1 fork ringan) -> dumpsys hanya bila
#     ada proses game hidup; saat main, game dipantau lewat /proc/<pid> (tanpa
#     fork) dan foreground dicek tiap FG_CHECK_INGAME detik
#   * semua dumpsys dibungkus timeout; metode foreground auto-fallback
#   * boot counter (bukan marker) -> tidak ada self-disable palsu saat reboot cepat
# =====================================================================

GAMES_DEFAULT="com.mobile.legends com.tencent.ig com.pubg.imobile com.pubg.krmobile com.vng.pubgmobile com.rekoo.pubgm com.miHoYo.GenshinImpact com.miHoYo.hkrpg com.HoYoverse.hkrpgoversea com.HoYoverse.Nap com.activision.callofduty.shooter com.garena.game.codm com.dts.freefireth com.dts.freefiremax com.konami.efootball.pes.mobile com.winlator com.roblox.client com.mojang.minecraftpe com.kurogame.wutheringwaves.global com.levelinfinite.sgameGlobal com.supercell.brawlstars com.proximabeta.mf.uamo"

GAME_PKG=""; GAME_PID=""; COOL_UNTIL=0; PS_OK=0; DAEMON_QUIT=0
FG_PKG=""

games_build() {
  { for gb in $GAMES_DEFAULT; do echo "$gb"; done
    [ -n "$EXTRA_GAME_PACKAGES" ] && echo "$EXTRA_GAME_PACKAGES" | tr ',' '\n'
    [ -f "$DATADIR/games.user" ] && cat "$DATADIR/games.user"
  } | sed 's/[[:space:]]//g' | grep -E '^[A-Za-z0-9_.]+$' | sort -u > "$RUNDIR/games.list"
}

is_game_pkg() { grep -qxF "$1" "$RUNDIR/games.list" 2>/dev/null; }

running_games() { ps -A -o NAME 2>/dev/null | grep -F -x -f "$RUNDIR/games.list" 2>/dev/null; }

ps_selftest() { ps -A -o NAME 2>/dev/null | grep -qx 'system_server' && PS_OK=1 || PS_OK=0; }

system_alive() {
  [ -n "$(pidof surfaceflinger 2>/dev/null)" ] || return 1
  [ -n "$(pidof system_server 2>/dev/null)" ] || return 1
  return 0
}

# foreground app -> FG_PKG (tanpa subshell supaya FG_METHOD yang berhasil diingat)
fg_get() {
  FG_PKG=$(fg_try "${FG_METHOD:-1}")
  [ -n "$FG_PKG" ] && return 0
  for fgm in 1 2 3 4; do
    [ "$fgm" = "${FG_METHOD:-0}" ] && continue
    FG_PKG=$(fg_try "$fgm")
    [ -n "$FG_PKG" ] && { FG_METHOD=$fgm; log_msg "FG: metode foreground beralih ke $fgm"; return 0; }
  done
  return 1
}

game_pid() { set -- $(pidof "$1" 2>/dev/null); echo "$1"; }

# ---------------------------------------------------------------------
# Siklus hidup game
# ---------------------------------------------------------------------
start_game() {
  GAME_PKG=$1; GAME_PID=$2
  preset_params
  thermal_limits_init
  : > "$RUNDIR/writes"
  log_msg "GAME START $GAME_PKG pid=$GAME_PID | tier=$TIER soc=$SOC_VENDOR preset=$PRESET($PRESET_EFF) cap=$LV_CAP start=$LV_START"
  for sg_fn in thermal_apply perf_sched_apply perf_fpsgo_apply log_reduce_apply perf_touch_apply \
               perf_io_apply refresh_apply network_apply ram_apply; do
    if ! system_alive; then
      log_msg "STAGE: system tidak responsif sebelum $sg_fn -> batalkan & cooldown"
      stop_game "system tidak responsif"; COOL_UNTIL=$(( $(uptime_s) + COOLDOWN_SEC )); return 1
    fi
    "$sg_fn" || log_msg "STAGE: $sg_fn rc=$? (fitur dilewati, lanjut)"
    [ "$STAGE_STEP_DELAY" -gt 0 ] && sleep "$STAGE_STEP_DELAY"
  done
  perf_set_level "$LV_START"
  perf_priority_apply "$GAME_PID"
  fse_reset "$GAME_PKG"
  HOT_SINCE=0; THERM_STATE=0; NEXT_MON=0; NEXT_FG=$(( $(uptime_s) + FG_CHECK_INGAME ))
  sg_ok=$(grep -c '^ok' "$RUNDIR/writes" 2>/dev/null); sg_df=$(grep -c '^diff' "$RUNDIR/writes" 2>/dev/null); sg_rj=$(grep -c '^rej' "$RUNDIR/writes" 2>/dev/null)
  log_msg "GAME START selesai: tulis ok=$sg_ok dibulatkan-kernel=$sg_df ditolak=$sg_rj"
  echo "$GAME_PKG" > "$RUNDIR/game"
  notify "Gaming mode ON: $GAME_PKG (preset $PRESET_EFF, tier $TIER)"
}

stop_game() {
  log_msg "GAME STOP ${GAME_PKG:-?} ($1)"
  cleanup_all
  GAME_PKG=""; GAME_PID=""
  rm -f "$RUNDIR/game"
  [ -n "$2" ] && notify "$2"
}

# ---------------------------------------------------------------------
# Tick
# ---------------------------------------------------------------------
NEXT_MON=0; NEXT_FG=0

tick_ingame() {
  if [ ! -d "$R/proc/$GAME_PID" ]; then stop_game "proses game berakhir" "Gaming mode OFF, direstore"; return; fi
  if [ "$MODE" = off ]; then stop_game "mode off" "Gaming mode OFF (manual)"; return; fi
  now=$(uptime_s)
  # poin 5: mode hard dipantau lebih sering (HARD_MON_SEC) karena lebih banyak
  # proteksi vendor dimatikan -> suhu bisa naik lebih cepat di antara polling.
  ti_mon=4; [ "$THERMAL_MODE" = hard ] && ti_mon=$HARD_MON_SEC
  if [ "$FEAT_TEMP_MONITOR" = 1 ] && [ "$now" -ge "$NEXT_MON" ]; then
    NEXT_MON=$((now + ti_mon))
    temps_read probe
    thermal_eval
    echo "$T_SOC|$T_BATT|$T_SKIN|$THERM_STATE" > "$RUNDIR/temps"
    if [ "$THERM_STATE" -ge 2 ]; then
      ti_lim=$SAFE_HOT_SECONDS; [ "$THERMAL_MODE" = hard ] && ti_lim=$HARD_SAFE_HOT_SECONDS
      log_msg "SAFETY: $THERM_WHY (ambang ${ti_lim}s, mode $THERMAL_MODE) -> boost dimatikan, cooldown ${COOLDOWN_SEC}s"
      stop_game "thermal" "Suhu tinggi ($THERM_WHY) - boost dimatikan otomatis"
      COOL_UNTIL=$(( $(uptime_s) + COOLDOWN_SEC ))
      # poin 5: setelah safety trip di mode hard, turunkan otomatis ke auto
      # untuk sisa sesi - mode hard harus dipilih ulang secara sadar, tidak
      # otomatis dicoba lagi dengan ambang yang sama persis setelah cooldown.
      if [ "$HARD_TRIPPED" = 1 ] && [ "$HARD_DEMOTE_AFTER_TRIP" = 1 ]; then
        if grep -q '^THERMAL_MODE=' "$CONF" 2>/dev/null; then
          sed -i 's/^THERMAL_MODE=.*/THERMAL_MODE=auto/' "$CONF" 2>/dev/null
        else
          echo "THERMAL_MODE=auto" >> "$CONF"
        fi
        THERMAL_MODE=auto; HARD_TRIPPED=0
        # kalau yang memaksa hard itu Bypass Thermal, lepas juga kuncinya supaya
        # Disable Thermal tidak ikut terkunci permanen gara-gara safety trip ini,
        # dan status di WebUI tidak bohong bilang bypass masih aktif.
        if [ "$BYPASS_THERMAL" = 1 ]; then
          by_setconf BYPASS_THERMAL 0; by_setconf BYPASS_PREV_MODE ""
          BYPASS_THERMAL=0
          log_msg "SAFETY: Bypass Thermal ikut dimatikan otomatis (safety trip)"
        fi
        log_msg "SAFETY: thermal hard -> diturunkan ke auto otomatis (safety trip). Pilih 'hard' lagi secara manual kalau tetap mau dipakai."
        notify "ThermalX: mode thermal 'hard' dimatikan otomatis karena overheat, diturunkan ke 'auto'"
      fi
      return
    fi
  fi
  if [ "$MODE" != on ] && [ "$now" -ge "$NEXT_FG" ]; then
    NEXT_FG=$((now + FG_CHECK_INGAME))
    if fg_get && [ "$FG_PKG" != "$GAME_PKG" ]; then
      stop_game "game keluar dari foreground ($FG_PKG)" "Gaming mode OFF, direstore"
      return
    fi
  fi
  fse_tick
}

tick_idle() {
  [ "$MODE" = off ] && return 0
  now=$(uptime_s)
  [ "$now" -lt "$COOL_UNTIL" ] && return 0
  if [ "$MODE" != on ] && [ "$PS_OK" = 1 ]; then
    [ -n "$(running_games)" ] || return 0
  fi
  fg_get || return 0
  if [ "$MODE" = on ] || is_game_pkg "$FG_PKG"; then
    ti_pid=$(game_pid "$FG_PKG")
    [ -n "$ti_pid" ] || return 0
    # jangan mulai kalau device masih panas (setelah cooldown)
    temps_read
    if { [ -n "$T_SOC" ] && [ "$T_SOC" -ge $((SOC_LIM - 6)) ]; } || { [ -n "$T_BATT" ] && [ "$T_BATT" -ge $((BATT_LIM - 2)) ]; }; then
      log_msg "START ditunda: device masih panas (soc=${T_SOC:-?} batt=${T_BATT:-?})"
      COOL_UNTIL=$((now + 30)); return 0
    fi
    start_game "$FG_PKG" "$ti_pid"
  fi
}

# ---------------------------------------------------------------------
# Boot guard
# ---------------------------------------------------------------------
boot_commit_bg() {
  (
    bc_n=0
    while [ "$(getprop sys.boot_completed)" != 1 ] && [ "$bc_n" -lt 180 ]; do sleep 2; bc_n=$((bc_n + 2)); done
    sleep "$BOOT_OK_DELAY"
    if system_alive; then
      echo 0 > "$DATADIR/boot_count"
      log_msg "BOOT: sukses, boot_count direset"
    else
      log_msg "BOOT: system tidak responsif setelah delay, boot_count TIDAK direset"
    fi
  ) &
}

# ---------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------
daemon_exit() { DAEMON_QUIT=1; }

daemon_main() {
  if [ -f "$RUNDIR/daemon.pid" ]; then
    dm_old=$(cat "$RUNDIR/daemon.pid" 2>/dev/null)
    if [ -n "$dm_old" ] && [ "$dm_old" != "$$" ] && kill -0 "$dm_old" 2>/dev/null; then
      log_msg "DAEMON: sudah berjalan (pid $dm_old), instance ini keluar"
      return 0
    fi
  fi
  echo $$ > "$RUNDIR/daemon.pid"
  trap 'daemon_exit' TERM INT HUP
  trap 'cleanup_all; rm -f "$RUNDIR/daemon.pid"' EXIT

  load_conf
  scan_if_needed
  thermal_limits_init; preset_params
  games_build
  ps_selftest
  log_msg "DAEMON v$TX_VER start pid=$$ | $SOC_VENDOR/$SOC_NAME tier=$TIER ram=${RAM_MB}MB cluster=$N_CLUSTERS gpu=$GPU_BACKEND fpsgo=$HAS_FPSGO ps=$PS_OK"

  dm_w=0
  while [ ! -f "$RUNDIR/safe_done" ] && [ "$dm_w" -lt 20 ]; do sleep 1; dm_w=$((dm_w + 1)); done
  dm_safe=$(cat "$DATADIR/safe_mode" 2>/dev/null)
  case "$dm_safe" in
    skip)
      log_msg "P.3: safe_mode=skip -> daemon idle total (hanya boot_count)"
      boot_commit_bg; return 0 ;;
    cool)
      log_msg "P.3: safe_mode=cool -> preset cool, thermal off"
      PRESET=cool; THERMAL_MODE=off ;;
  esac
  boot_commit_bg

  dm_i=0
  while [ "$DAEMON_QUIT" = 0 ]; do
    echo "$(uptime_s)" > "$RUNDIR/heartbeat"
    [ -f "$MODDIR/disable" ] || [ -f "$MODDIR/remove" ] && { log_msg "DAEMON: module disabled/removed, berhenti"; break; }
    [ -f "$RUNDIR/stop" ] && { log_msg "DAEMON: stop diminta CLI"; break; }
    MODE=$(cat "$DATADIR/mode_state" 2>/dev/null); MODE=${MODE:-auto}
    dm_i=$((dm_i + 1)); [ $((dm_i % 200)) = 0 ] && log_rotate
    # konfigurasi bisa diubah user kapan saja (WebUI/CLI): baca ulang tiap 30 tick, hanya saat idle
    if [ -z "$GAME_PKG" ] && [ $((dm_i % 30)) = 0 ]; then load_conf; thermal_limits_init; preset_params; games_build; fi
    if [ -n "$GAME_PKG" ]; then tick_ingame; sleep "$FPS_TICK"
    else tick_idle; sleep "$POLL_INTERVAL"; fi
  done
  [ -n "$GAME_PKG" ] && stop_game "daemon berhenti" "Gaming mode OFF, direstore"
  return 0
}
