#!/system/bin/sh
# ThermalX - tkloop.sh : watchdog agresif; menjaga service thermal tetap mati selama THERMAL_KILL=1
MODDIR=${0%/*}; MODDIR=${MODDIR%/lib}
export MODDIR
. "$MODDIR/common.sh"
load_conf
tk_p=$(cat "$TK_PID" 2>/dev/null)
[ -n "$tk_p" ] && [ "$tk_p" != "$$" ] && kill -0 "$tk_p" 2>/dev/null && exit 0
echo $$ > "$TK_PID"
trap 'rm -f "$TK_PID"' EXIT
log_msg "TKILL: loop agresif start pid=$$"
scan_if_needed >/dev/null 2>&1
tk_props_apply; tk_override; tk_kernel_apply
tk_i=0
while :; do
  # tick efektif maksimal 2 dtk (nilai TK_TICK lebih besar dari 2 diabaikan)
  TK_TICK_EFF=${TK_TICK:-2}; case "$TK_TICK_EFF" in ''|*[!0-9]*|0) TK_TICK_EFF=2 ;; esac
  [ "$TK_TICK_EFF" -gt 2 ] && TK_TICK_EFF=2
  [ $((tk_i % 5)) = 0 ] && load_conf
  [ "$THERMAL_KILL" = 1 ] || break
  [ -f "$MODDIR/disable" ] && break
  tk_enforce
  [ $((tk_i % 3)) = 0 ] && { tk_kill_procs; tk_safety || break; }
  [ $((tk_i % 10)) = 0 ] && { tk_override; tk_kernel_apply; }
  tk_i=$((tk_i + 1))
  sleep "$TK_TICK_EFF"
done
log_msg "TKILL: loop selesai"
