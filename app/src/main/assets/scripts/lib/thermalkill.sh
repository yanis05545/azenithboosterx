#!/system/bin/sh
# =====================================================================
#  ThermalX - lib/thermalkill.sh : "Disable Thermal" mandiri (mode AGRESIF)
#
#  Kenapa versi lama masih menyisakan "running"?
#   Service HAL thermal (mis. vendor.thermal-hal-2-0.mtk) punya baris
#   'interface' di .rc. Begitu `stop` dijalankan, system_server / powerhal /
#   hwservicemanager meminta HAL itu lagi dan init MENYALAKAN ULANG lewat
#   ctl.interface_start. Loop 5 dtk + `stop` saja tidak pernah menang.
#
#  Strategi v2.6 (berlapis):
#   1. stop + ctl.stop + kill -9 PID (PID dari init.svc_debug_pid.*)  -> cepat
#   2. watchdog 2 dtk (bukan 5) untuk SEMUA service *thermal* yang
#      running/restarting, ditambah sapu proses *thermal* yatim
#   3. kalau service hidup lagi setelah dimatikan (ada yang menyalakan ulang)
#      -> BLOCK: binary HAL di-bind-mount dengan stub kosong (exit 0), jadi
#      respawn mati seketika dan tidak sempat menjalankan apa pun. Dilepas
#      otomatis saat fitur dimatikan.
#   4. prop disable-thermal + cmd thermalservice override-status 0 (diulang)
#   5. kernel: policy THERMAL pada MTK PPM dimatikan, trip passive/active zona
#      SoC dinaikkan ke TK_TRIP_C (hanya dinaikkan, nilai asli disimpan)
#
#  PENGAMAN (tetap): zona thermal kernel TIDAK dimatikan sehingga suhu asli
#  tetap terbaca. Kalau baterai >= TK_BATT_MAX, skin >= TK_SKIN_MAX atau SoC >=
#  batas tier selama TK_HOT_SEC detik -> SEMUA dikembalikan dan THERMAL_KILL=0.
# =====================================================================

TK_SVC="$DATADIR/tk_svc"; TK_PROP="$DATADIR/tk_props"; TK_PID="$RUNDIR/tk.pid"
TK_MNT="$DATADIR/tk_mounts"; TK_STUB="$DATADIR/tk_stub"; TK_KERN="$DATADIR/tk_kern"

tk_setconf() { # tk_setconf KEY VAL
  if grep -q "^$1=" "$CONF" 2>/dev/null; then sed -i "s/^$1=[^ #]*/$1=$2/" "$CONF"
  else echo "$1=$2" >> "$CONF"; fi
}
# semua nama service *thermal* (apa pun statusnya)
tk_list_names() { getprop 2>/dev/null | sed -n 's/^\[init\.svc\.\([^]]*thermal[^]]*\)\]: \[[a-z_-]*\]$/\1/p'; }
# yang masih hidup: running ATAU restarting (respawn)
tk_list_running() { getprop 2>/dev/null | sed -n -e 's/^\[init\.svc\.\([^]]*thermal[^]]*\)\]: \[running\]$/\1/p' -e 's/^\[init\.svc\.\([^]]*thermal[^]]*\)\]: \[restarting\]$/\1/p'; }
tk_list_all() { getprop 2>/dev/null | sed -n 's/^\[init\.svc\.\([^]]*thermal[^]]*\)\]: \[\([a-z_-]*\)\]$/\1=\2/p'; }

# cari path binary service dari file .rc init
tk_bin_of() {
  for tk_d in /vendor/etc/init /vendor/etc/init/hw /odm/etc/init /system/etc/init /system_ext/etc/init /product/etc/init; do
    [ -d "$tk_d" ] || continue
    tk_f=$(grep -lF "service $1 " "$tk_d"/*.rc 2>/dev/null | head -n 1)
    [ -n "$tk_f" ] || continue
    sed -n "s|^[[:space:]]*service $1 \([^ ]*\).*|\1|p" "$tk_f" | head -n 1
    return 0
  done
  return 0
}

# ---------------- BLOCK: stub di atas binary HAL ----------------
tk_block() { # tk_block nama [path_binary]
  tkb_n=$1; tkb_b=$2
  [ -n "$tkb_b" ] || tkb_b=$(tk_bin_of "$tkb_n")
  [ -n "$tkb_b" ] && [ -f "$tkb_b" ] || return 1
  grep -qxF "$tkb_b" "$TK_MNT" 2>/dev/null && return 0
  printf '#!/system/bin/sh\nexit 0\n' > "$TK_STUB" 2>/dev/null; chmod 755 "$TK_STUB" 2>/dev/null
  tkb_ctx=$(ls -Z "$tkb_b" 2>/dev/null | awk '{print $1}')
  [ -n "$tkb_ctx" ] && chcon "$tkb_ctx" "$TK_STUB" 2>/dev/null
  tkb_err=$(mount --bind "$TK_STUB" "$tkb_b" 2>&1)
  if [ $? -eq 0 ]; then
    echo "$tkb_b" >> "$TK_MNT"
    sed -i "\|^$tkb_n|d" "$DATADIR/tk_block_fail" 2>/dev/null
    log_msg "TKILL: BLOCK $tkb_n -> $tkb_b di-bind stub (respawn jadi mati seketika)"
    return 0
  fi
  # simpan alasan gagal supaya kelihatan di `thermalx thermalkill status` (bukan cuma di log)
  echo "$tkb_n|$tkb_b|${tkb_err:-mount ditolak tanpa pesan (kemungkinan SELinux/izin)}" >> "$DATADIR/tk_block_fail"
  log_msg "TKILL: BLOCK $tkb_n gagal untuk $tkb_b -> $tkb_err"
  return 1
}
tk_unblock() {
  [ -s "$TK_MNT" ] || { : > "$TK_MNT"; return 0; }
  while read -r tku_b; do [ -n "$tku_b" ] && umount "$tku_b" 2>/dev/null; done < "$TK_MNT"
  : > "$TK_MNT"
}

# ---------------- matikan satu service ----------------
tk_stop_one() { # tk_stop_one nama [force]
  tks_n=$1; tks_force=$2
  if grep -qxF "$tks_n" "$TK_SVC" 2>/dev/null; then tks_seen=1; else tks_seen=0; echo "$tks_n" >> "$TK_SVC"; fi
  tks_pid=$(getprop "init.svc_debug_pid.$tks_n" 2>/dev/null)
  case "$tks_pid" in ''|*[!0-9]*) tks_pid="" ;; esac
  tks_bin=""; [ -n "$tks_pid" ] && tks_bin=$(readlink "/proc/$tks_pid/exe" 2>/dev/null)
  stop "$tks_n" 2>/dev/null
  setprop ctl.stop "$tks_n" 2>/dev/null
  [ -n "$tks_pid" ] && kill -9 "$tks_pid" 2>/dev/null
  # sudah pernah dimatikan tapi hidup lagi = ada yang menyalakan ulang -> BLOCK
  if [ "${TK_BLOCK:-1}" = 1 ]; then
    if [ "$tks_force" = force ]; then tk_block "$tks_n" "$tks_bin"
    elif [ "$tks_seen" = 1 ]; then
      tks_c=$(cat "$RUNDIR/tkrs.$tks_n" 2>/dev/null); tks_c=$(( ${tks_c:-0} + 1 )); echo "$tks_c" > "$RUNDIR/tkrs.$tks_n"
      [ "$tks_c" -ge "${TK_BLOCK_AFTER:-2}" ] && tk_block "$tks_n" "$tks_bin"
    fi
  fi
  return 0
}
tk_enforce() { # tk_enforce [force]  -> matikan semua service thermal yang hidup
  for tk_s in $(tk_list_running); do tk_stop_one "$tk_s" "$1"; done
}
# sapu proses *thermal* userspace yang tidak terdaftar sebagai service (atau sisa)
tk_kill_procs() {
  ps -A -o PID,NAME 2>/dev/null | while read -r tkp_p tkp_n; do
    case "$tkp_p" in ''|*[!0-9]*) continue ;; esac
    case "$tkp_n" in
      *thermalx*|*thermalservice*) continue ;;
      *thermal*) readlink "/proc/$tkp_p/exe" >/dev/null 2>&1 && kill -9 "$tkp_p" 2>/dev/null ;;
    esac
  done
}

tk_props_apply() {
  [ -s "$SCANDIR/thermal_props" ] || return 0
  while IFS='|' read -r tk_k tk_v; do
    [ -n "$tk_k" ] || continue
    grep -q "^$tk_k|" "$TK_PROP" 2>/dev/null || echo "$tk_k|$(getprop "$tk_k")" >> "$TK_PROP"
    if command -v resetprop >/dev/null 2>&1; then resetprop "$tk_k" "$tk_v" 2>/dev/null; else setprop "$tk_k" "$tk_v" 2>/dev/null; fi
  done < "$SCANDIR/thermal_props"
}
tk_props_revert() {
  [ -s "$TK_PROP" ] || { : > "$TK_PROP"; return 0; }
  while IFS='|' read -r tk_k tk_v; do
    [ -n "$tk_k" ] || continue
    if [ -n "$tk_v" ]; then
      if command -v resetprop >/dev/null 2>&1; then resetprop "$tk_k" "$tk_v" 2>/dev/null; else setprop "$tk_k" "$tk_v" 2>/dev/null; fi
    else resetprop --delete "$tk_k" 2>/dev/null || setprop "$tk_k" "" 2>/dev/null; fi
  done < "$TK_PROP"
  : > "$TK_PROP"
}
tk_override() { [ "$(getprop ro.build.version.sdk)" -ge 30 ] 2>/dev/null && cmd thermalservice override-status 0 >/dev/null 2>&1; return 0; }

# ---------------- lapis kernel ----------------
tk_kernel_apply() {
  [ "${TK_KERNEL:-1}" = 1 ] || return 0
  # a) MTK PPM: matikan policy THERMAL
  if [ -r /proc/ppm/policy_status ]; then
    tkk_i=$(grep -i -m1 'policy_thermal' /proc/ppm/policy_status 2>/dev/null | sed -n 's/^[^0-9]*\([0-9][0-9]*\).*/\1/p')
    if [ -n "$tkk_i" ]; then
      grep -q '^ppm|' "$TK_KERN" 2>/dev/null || echo "ppm|$tkk_i" >> "$TK_KERN"
      { echo "$tkk_i 0" > /proc/ppm/policy_status; } 2>/dev/null
    fi
  fi
  # b) naikkan trip passive/active zona SoC (tidak pernah menurunkan, tidak menyentuh critical/hot)
  [ -s "$SCANDIR/zones" ] || return 0
  tkk_tgt=$(( ${TK_TRIP_C:-90} * 1000 ))
  while IFS='|' read -r tkk_z tkk_t tkk_c tkk_e tkk_tp; do
    [ "$tkk_c" = soc ] || continue
    tkk_d=$(zone_dir "$tkk_z")
    for tkk_ty in "$tkk_d"/trip_point_*_type; do
      [ -e "$tkk_ty" ] || continue
      case "$(read1 "$tkk_ty")" in passive|active) ;; *) continue ;; esac
      tkk_f=${tkk_ty%_type}_temp
      tkk_cur=$(read1 "$tkk_f")
      case "$tkk_cur" in ''|*[!0-9]*) continue ;; esac
      [ "$tkk_cur" -lt "$tkk_tgt" ] || continue
      grep -qxF "$tkk_f|$tkk_cur" "$TK_KERN" 2>/dev/null || grep -q "^$tkk_f|" "$TK_KERN" 2>/dev/null || echo "$tkk_f|$tkk_cur" >> "$TK_KERN"
      { echo "$tkk_tgt" > "$tkk_f"; } 2>/dev/null
    done
  done < "$SCANDIR/zones"
}
tk_kernel_revert() {
  [ -s "$TK_KERN" ] || { : > "$TK_KERN"; return 0; }
  while IFS='|' read -r tkr_k tkr_v; do
    [ -n "$tkr_k" ] || continue
    if [ "$tkr_k" = ppm ]; then { echo "$tkr_v 1" > /proc/ppm/policy_status; } 2>/dev/null
    else { echo "$tkr_v" > "$tkr_k"; } 2>/dev/null; fi
  done < "$TK_KERN"
  : > "$TK_KERN"
}

# ---------------- loop penjaga ----------------
tk_loop_alive() { tk_p=$(cat "$TK_PID" 2>/dev/null); [ -n "$tk_p" ] && kill -0 "$tk_p" 2>/dev/null; }
tk_loop_start() {
  tk_loop_alive && return 0
  # jalankan di mount namespace init (PID 1) supaya bind-mount BLOCK berlaku global
  if command -v nsenter >/dev/null 2>&1; then
    nohup nsenter -t 1 -m -- sh "$MODDIR/lib/tkloop.sh" >/dev/null 2>&1 &
  else
    nohup sh "$MODDIR/lib/tkloop.sh" >/dev/null 2>&1 &
  fi
}
tk_loop_stop() {
  tk_p=$(cat "$TK_PID" 2>/dev/null)
  [ -n "$tk_p" ] && kill "$tk_p" 2>/dev/null
  rm -f "$TK_PID"
}

# pengaman suhu; return 1 = trip (sudah dikembalikan)
TK_HOT_T0=0
tk_safety() {
  thermal_limits_init; temps_read
  tk_hot=""
  [ -n "$T_BATT" ] && [ "$T_BATT" -ge "${TK_BATT_MAX:-45}" ] && tk_hot="baterai ${T_BATT}C"
  [ -n "$T_SKIN" ] && [ "$T_SKIN" -ge "${TK_SKIN_MAX:-47}" ] && tk_hot="$tk_hot skin ${T_SKIN}C"
  [ -n "$T_SOC" ] && [ "$T_SOC" -ge "$SOC_LIM" ] && tk_hot="$tk_hot SoC ${T_SOC}C"
  if [ -z "$tk_hot" ]; then TK_HOT_T0=0; return 0; fi
  tk_now=$(uptime_s)
  [ "$TK_HOT_T0" = 0 ] && TK_HOT_T0=$tk_now
  if [ $((tk_now - TK_HOT_T0)) -ge "${TK_HOT_SEC:-10}" ]; then
    log_msg "TKILL: PANAS ($tk_hot) >= ${TK_HOT_SEC:-10}s -> thermal dikembalikan, THERMAL_KILL=0"
    notify "Disable Thermal dimatikan otomatis: $tk_hot"
    tk_restore_all; tk_setconf THERMAL_KILL 0
    return 1
  fi
  return 0
}

tk_restore_all() {
  tk_unblock
  tk_kernel_revert
  if [ -s "$TK_SVC" ]; then
    while read -r tk_s; do [ -n "$tk_s" ] && start "$tk_s" 2>/dev/null; done < "$TK_SVC"
  fi
  : > "$TK_SVC"
  tk_props_revert
  rm -f "$RUNDIR"/tkrs.* 2>/dev/null
  [ "$(getprop ro.build.version.sdk)" -ge 30 ] 2>/dev/null && cmd thermalservice reset >/dev/null 2>&1
  return 0
}

tk_on() {
  load_conf
  if [ "$BYPASS_THERMAL" = 1 ]; then
    echo "DITOLAK: Bypass Thermal sedang aktif. Matikan Bypass Thermal dulu (thermalx bypass off) baru Disable Thermal boleh dinyalakan."
    return 1
  fi
  scan_if_needed >/dev/null 2>&1; load_conf; thermal_limits_init; temps_read
  if [ -z "$T_BATT" ] && [ -z "$T_SOC" ]; then
    echo "DITOLAK: suhu baterai & SoC tidak terbaca -> tanpa pengaman suhu fitur ini tidak diaktifkan"; return 1
  fi
  tk_setconf THERMAL_KILL 1
  : > "$DATADIR/tk_block_fail"
  tk_props_apply; tk_override; tk_kernel_apply
  tk_enforce; tk_kill_procs
  tk_loop_start
  sleep 2; tk_enforce; tk_kill_procs
  sleep 2
  # masih ada yang hidup setelah 2 putaran -> langsung BLOCK (agresif)
  [ -n "$(tk_list_running)" ] && { tk_enforce force; sleep 2; tk_enforce; }
  echo "Disable Thermal AGRESIF: AKTIF (watchdog ${TK_TICK_EFF:-2} dtk, BLOCK respawn, tahan reboot)"
  tk_status
}
tk_off() {
  tk_setconf THERMAL_KILL 0
  tk_loop_stop
  tk_restore_all
  echo "Disable Thermal: MATI (BLOCK dilepas, service thermal dihidupkan kembali)"
  sleep 2; tk_status
}
tk_now() { # paksa satu putaran penuh sekarang (tanpa menunggu loop)
  load_conf; tk_override; tk_kernel_apply; tk_enforce force; tk_kill_procs; sleep 2; tk_enforce force
  tk_status
}
tk_status() {
  echo "THERMAL_KILL=$THERMAL_KILL  loop=$(tk_loop_alive && echo jalan || echo mati)  block=$(grep -c . "$TK_MNT" 2>/dev/null || echo 0)"
  echo "--- status service thermal (init.svc.*) ---"
  tk_list_all
  tk_n=$(tk_list_running | wc -l)
  echo "--- masih running/restarting: $tk_n ---"
  for tk_s in $(tk_list_running); do
    tk_pp=$(getprop "init.svc_debug_pid.$tk_s" 2>/dev/null)
    echo "  $tk_s pid=${tk_pp:-?} exe=$( [ -n "$tk_pp" ] && readlink "/proc/$tk_pp/exe" 2>/dev/null)"
  done
  [ -s "$TK_MNT" ] && { echo "--- BLOCK aktif ---"; cat "$TK_MNT"; }
  if [ -s "$DATADIR/tk_block_fail" ]; then
    echo "--- BLOCK GAGAL (service tetap hidup karena ini) ---"
    while IFS='|' read -r tbf_n tbf_b tbf_e; do
      [ -n "$tbf_n" ] && echo "  $tbf_n ($tbf_b): $tbf_e"
    done < "$DATADIR/tk_block_fail"
    echo "  -> cek juga: dmesg | grep -i denied | grep -i mount   (SELinux avc)"
  fi
  return 0
}
