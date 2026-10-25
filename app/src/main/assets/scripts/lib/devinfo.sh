#!/system/bin/sh
# =====================================================================
#  ThermalX - lib/devinfo.sh
#  Info perangkat untuk kartu "Status Perangkat" di WebUI (format key=value).
#    devinfo_all   : semua (statis + live)         -> thermalx devinfo
#    devinfo_live  : hanya yang berubah-ubah (cepat, tanpa getprop/dumpsys)
#  Semua nilai dibaca langsung dari device (getprop, /proc, /sys, df) - tidak
#  ada tabel perangkat bawaan. Klasifikasi ROM (stock/aosp/port/gsi) adalah
#  HEURISTIK dari sinyal struktural Android, bukan jaminan 100%; alasan dan
#  tingkat keyakinannya ikut ditampilkan (rom_why / rom_conf).
# =====================================================================

dv_p() { printf '%s=%s\n' "$1" "$(printf '%s' "$2" | tr -d '\r\n')"; }
dv_first() { # nilai prop pertama yang tidak kosong
  for dv_k in "$@"; do dv_v=$(getprop "$dv_k" 2>/dev/null); [ -n "$dv_v" ] && { printf '%s' "$dv_v"; return 0; }; done
  return 0
}
dv_cat() { [ -r "$1" ] || return 0; read -r dv_l < "$1" 2>/dev/null; printf '%s' "$dv_l"; }
dv_lc() { printf '%s' "$*" | tr 'A-Z' 'a-z'; }

# ------------------------------ GPU -----------------------------------
dv_gpu_node() { # set DV_GN ke direktori devfreq/kgsl GPU (kosong kalau tidak ada)
  DV_GN=""
  for dv_d in "$R"/sys/class/devfreq/*; do
    [ -d "$dv_d" ] || continue
    case "${dv_d##*/}" in *mali*|*gpu*|*g3d*|*kgsl*|*gpufreq*) DV_GN=$dv_d; return 0 ;; esac
  done
  [ -d "$R/sys/class/kgsl/kgsl-3d0" ] && DV_GN="$R/sys/class/kgsl/kgsl-3d0"
  return 0
}
dv_gpu_hz() { # dv_gpu_hz cur|max
  dv_gpu_node
  [ -n "$DV_GN" ] || return 0
  if [ "$1" = cur ]; then
    dv_x=$(dv_cat "$DV_GN/cur_freq"); [ -n "$dv_x" ] || dv_x=$(dv_cat "$DV_GN/gpuclk")
  else
    dv_x=$(dv_cat "$DV_GN/max_freq"); [ -n "$dv_x" ] || dv_x=$(dv_cat "$DV_GN/max_gpuclk")
    [ -n "$dv_x" ] || dv_x=$(tr ' ' '\n' < "$DV_GN/available_frequencies" 2>/dev/null | grep '^[0-9]' | sort -n | tail -n 1)
  fi
  printf '%s' "$dv_x"
}

# ------------------------------ ROM -----------------------------------
dv_skin() { # dv_skin Nama "regex_brand" prop...  (set rd_* bila prop ada)
  [ -n "$rd_name" ] && return 0
  ds_n=$1; ds_b=$2; shift 2
  ds_v=$(dv_first "$@")
  [ -n "$ds_v" ] || return 0
  rd_name=$ds_n; rd_ver=$ds_v; rd_kind=skin; rd_skinbrand=$ds_b
}
dv_fpdev() { printf '%s' "$1" | cut -d/ -f3 | cut -d: -f1; }

dv_rom() {
  rd_name=""; rd_ver=""; rd_kind=""; rd_skinbrand=""
  rb=$(dv_lc "$(getprop ro.product.brand 2>/dev/null)")
  [ -n "$rb" ] || rb=$(dv_lc "$(getprop ro.product.manufacturer 2>/dev/null)")
  tags=$(getprop ro.build.tags 2>/dev/null); btype=$(getprop ro.build.type 2>/dev/null)
  fp=$(getprop ro.build.fingerprint 2>/dev/null)

  # 1) custom ROM berbasis AOSP: dikenali dari prop versi khasnya
  for e in lineage:LineageOS crdroid:crDroid pixelexperience:PixelExperience evolution:EvolutionX \
           aospa:ParanoidAndroid rice:RiceDroid derp:DerpFest havoc:Havoc arrow:ArrowOS superior:SuperiorOS \
           pixelos:PixelOS voltage:VoltageOS yaap:YAAP matrixx:MatrixxOS cherish:CherishOS bliss:BlissROM \
           corvus:CorvusOS spark:SparkOS ancient:AncientOS nusantara:Nusantara potato:PotatoOS \
           infinity:InfinityX lunaris:LunarisAOSP; do
    k=${e%%:*}; n=${e#*:}; v=$(getprop "ro.$k.version" 2>/dev/null)
    [ -n "$v" ] && { rd_name=$n; rd_ver=$v; rd_kind=custom; break; }
  done
  # ro.modversion = paling umum (LineageOS lama & banyak custom ROM lain).
  # ro.rom.version / ro.custom.version = dipakai beberapa custom ROM lain yang
  # tidak punya prop ro.<nama>.version sendiri di daftar di atas.
  [ -n "$rd_name" ] || { v=$(dv_first ro.modversion ro.rom.version ro.custom.version); [ -n "$v" ] && { rd_name="Custom ROM"; rd_ver=$v; rd_kind=custom; }; }

  # 2) skin/ROM bawaan vendor (dicocokkan dengan brand fisik device)
  dv_skin HyperOS "xiaomi|redmi|poco|blackshark" ro.mi.os.version.name
  dv_skin MIUI "xiaomi|redmi|poco|blackshark" ro.miui.ui.version.name
  dv_skin ColorOS "oppo|realme|oneplus" ro.build.version.oplusrom ro.build.version.opporom
  dv_skin "realme UI" "realme|oppo" ro.build.version.realmeui
  # ro.build.version.oneui = nama resmi sekarang; ro.build.version.sep = prop lama
  # "Samsung Experience" dari sebelum rebrand One UI, masih ada di sebagian build.
  dv_skin "One UI" "samsung" ro.build.version.oneui ro.build.version.sep
  dv_skin "Funtouch/OriginOS" "vivo|iqoo" ro.vivo.os.version
  dv_skin "HiOS/XOS/itel OS" "tecno|infinix|itel|transsion" ro.tranos.version ro.transsion.os.version ro.tranos.type
  dv_skin MagicOS "honor" ro.build.version.magic
  dv_skin EMUI "huawei|honor" ro.build.version.emui

  # 3) sinyal lain
  sysdev=$(dv_lc "$(dv_first ro.product.system.device ro.product.system_ext.device)")
  vdev=$(dv_lc "$(dv_first ro.product.vendor.device ro.product.odm.device ro.product.device)")
  sfp=$(getprop ro.system.build.fingerprint 2>/dev/null); vfp=$(getprop ro.vendor.build.fingerprint 2>/dev/null)
  sfd=$(dv_lc "$(dv_fpdev "$sfp")"); vfd=$(dv_lc "$(dv_fpdev "$vfp")")
  # ro.product.bootimage.device: device yang DIKLAIM boot.img (bagian dari image
  # system/port yang dipasang). ro.boot.device: dibaca bootloader dari DTB/cmdline
  # saat itu juga, jadi ini sinyal HARDWARE ASLI, beda sumber dari sysdev/vdev di
  # atas (yang sama-sama dari prop .device build, bisa dua2nya ikut diubah porter).
  bidev=$(dv_lc "$(getprop ro.product.bootimage.device 2>/dev/null)")
  hwdev=$(dv_lc "$(dv_first ro.boot.device ro.boot.hardware)")
  devmis=0; devwhy=""
  if [ -n "$sysdev" ] && [ -n "$vdev" ] && [ "$sysdev" != "$vdev" ] && [ "$sysdev" != generic ]; then
    devmis=1; devwhy="kode device partisi system ('$sysdev') beda dari vendor ('$vdev')"
  elif [ -n "$sfd" ] && [ -n "$vfd" ] && [ "$sfd" != "$vfd" ] && [ "$sfd" != generic ]; then
    devmis=1; devwhy="fingerprint system ('$sfd') beda device dari fingerprint vendor ('$vfd')"
  elif [ -n "$bidev" ] && [ -n "$hwdev" ] && [ "$bidev" != "$hwdev" ] && [ "$bidev" != generic ]; then
    devmis=1; devwhy="device di boot image ('$bidev') beda dari hardware asli yang dilaporkan bootloader ('$hwdev')"
  fi
  skinmis=0
  if [ "$rd_kind" = skin ] && ! printf '%s' "$rb" | grep -Eq "^($rd_skinbrand)"; then skinmis=1; fi
  looks_stock=0
  case "$tags" in *release-keys*) [ "$btype" = user ] && looks_stock=1 ;; esac
  gsi=0
  case "$fp" in generic/*|*/aosp_*|*/gsi_*) gsi=1 ;; esac
  case "$sfp" in generic/*|*/aosp_*|*/gsi_*) gsi=1 ;; esac
  case "$(dv_lc "$(getprop ro.product.system.name 2>/dev/null)")" in generic|gsi_*|aosp_arm*|aosp_x86*) gsi=1 ;; esac

  rt=unknown; rc=rendah; rw="fingerprint build tidak terbaca"
  if [ "$gsi" = 1 ]; then
    rt=gsi; rc=tinggi; rw="nama produk/fingerprint berpola generic/aosp_/gsi_ (Treble GSI)"
    [ -n "$rd_name" ] || { rd_name="AOSP GSI"; rd_ver=""; }
  elif [ "$looks_stock" = 1 ] && [ "$skinmis" = 0 ] && { [ -z "$rd_kind" ] || [ "$rd_kind" = skin ]; }; then
    rt=stock; rc=tinggi; rw="release-keys + build user, tanpa tanda ROM pihak ketiga"
    [ "$devmis" = 1 ] && { rc=sedang; rw="$rw (catatan: $devwhy; bisa varian region)"; }
    [ -n "$rd_name" ] || { rd_name=$(getprop ro.build.display.id 2>/dev/null); }
  elif [ "$skinmis" = 1 ]; then
    rt=port; rc=tinggi; rw="ada prop $rd_name tapi brand device '$rb' bukan brand asli ROM itu"
  elif [ "$devmis" = 1 ]; then
    rt=port; rc=sedang; rw="$devwhy, dan build bukan release-keys/user pabrik"
  elif [ "$rd_kind" = custom ]; then
    rt=aosp; rc=tinggi; rw="prop versi khas $rd_name terdeteksi (custom ROM berbasis AOSP)"
  elif [ "$rd_kind" = skin ]; then
    rt=stock-mod; rc=sedang; rw="skin $rd_name cocok dengan brand tapi build bukan release-keys/user (ROM bawaan yang dimodifikasi)"
  elif [ -n "$fp" ]; then
    rt=aosp; rc=sedang; rw="build ${tags:-?}/${btype:-?} tanpa skin vendor - kemungkinan AOSP/custom build"
    bu=$(dv_lc "$(getprop ro.build.user 2>/dev/null)")
    case "$bu" in *jenkins*|*android-build*|*buildkite*|*ci*) rw="$rw (ro.build.user='$bu', pola builder CI - memperkuat dugaan bukan build pabrik)" ;; esac
    [ -n "$rd_name" ] || rd_name="AOSP/Custom"
  fi
  RD_TYPE=$rt; RD_CONF=$rc; RD_WHY=$rw
}

# ------------------------------ Root ----------------------------------
dv_root() {
  rt_n=""; rt_v=""
  if [ -d "$R/data/adb/ap" ] || [ -e "$R/data/adb/apd" ]; then
    rt_n=APatch; rt_v=$(dv_cat "$R/data/adb/ap/version")
  elif [ -d "$R/data/adb/ksu" ] || [ -e "$R/data/adb/ksud" ]; then
    rt_n=KernelSU; rt_v=$("$R/data/adb/ksud" -V 2>/dev/null | head -n 1)
    [ -n "$rt_v" ] || rt_v=$(ksud -V 2>/dev/null | head -n 1)
  elif command -v magisk >/dev/null 2>&1; then
    rt_n=Magisk; rt_v=$(magisk -v 2>/dev/null | head -n 1)
  elif [ -d "$R/data/adb/magisk" ]; then
    rt_n=Magisk
  fi
  dv_p root "$rt_n"; dv_p root_ver "$rt_v"
}

# --------------------------- Bagian LIVE ------------------------------
devinfo_live() {
  if [ -r "$R/proc/meminfo" ]; then
    while read -r dk dval _; do
      case "$dk" in
        MemTotal:) dv_p mem_total_kb "$dval" ;;
        MemFree:) dv_p mem_free_kb "$dval" ;;
        MemAvailable:) dv_p mem_avail_kb "$dval" ;;
        Buffers:) dv_p mem_buf_kb "$dval" ;;
        Cached:) dv_p mem_cache_kb "$dval" ;;
        SwapTotal:) dv_p swap_total_kb "$dval" ;;
        SwapFree:) dv_p swap_free_kb "$dval" ;;
      esac
    done < "$R/proc/meminfo"
  fi
  # ambil 5 kolom TERAKHIR (blok, terpakai, tersedia) supaya tahan nama device panjang / df yang membungkus baris
  set -- $(df -k "$R/data" 2>/dev/null | awk 'END{ if (NF >= 5) print $(NF-4), $(NF-3), $(NF-2) }')
  [ "$#" -ge 3 ] && { dv_p data_total_kb "$1"; dv_p data_used_kb "$2"; dv_p data_avail_kb "$3"; }

  bp="$R/sys/class/power_supply/battery"
  [ -d "$bp" ] || bp="$R/sys/class/power_supply/Battery"
  dv_p bat_level "$(dv_cat "$bp/capacity")"
  dv_p bat_status "$(dv_cat "$bp/status")"
  dv_p bat_health "$(dv_cat "$bp/health")"
  dv_p bat_temp "$(dv_cat "$bp/temp")"
  dv_p bat_volt "$(dv_cat "$bp/voltage_now")"
  dv_p bat_cycle "$(dv_cat "$bp/cycle_count")"

  cf=""
  for p in "$R"/sys/devices/system/cpu/cpufreq/policy*; do
    [ -d "$p" ] || continue
    cf="$cf${cf:+,}$(dv_cat "$p/scaling_cur_freq")"
  done
  dv_p cpu_cur_khz "$cf"
  dv_p gpu_cur_hz "$(dv_gpu_hz cur)"
  dv_p uptime_s "$(uptime_s)"
}

# --------------------------- Bagian STATIS ----------------------------
devinfo_static() {
  # --- identitas perangkat
  dv_p brand "$(getprop ro.product.brand 2>/dev/null)"
  dv_p manufacturer "$(getprop ro.product.manufacturer 2>/dev/null)"
  dv_p model "$(dv_first ro.product.model ro.product.vendor.model)"
  dv_p marketname "$(dv_first ro.product.marketname ro.product.vendor.marketname ro.product.odm.marketname ro.config.marketing_name ro.vendor.oplus.market.name)"
  dv_p codename "$(dv_first ro.product.device ro.product.vendor.device)"
  dv_p board "$(dv_first ro.product.board ro.board.platform)"

  # --- SoC / CPU
  dv_p soc_mfr "$(dv_first ro.soc.manufacturer ro.vendor.soc.manufacturer)"
  dv_p soc_model "$(dv_first ro.soc.model ro.vendor.soc.model ro.hardware.chipname ro.mediatek.platform)"
  dv_p platform "$(getprop ro.board.platform 2>/dev/null)"
  dv_p hardware "$(dv_first ro.hardware ro.boot.hardware)"
  dv_p abi "$(getprop ro.product.cpu.abi 2>/dev/null)"
  dv_p cores "$(grep -c '^processor' "$R/proc/cpuinfo" 2>/dev/null)"
  dv_p cpu_impl "$(sed -n 's/^CPU implementer[[:space:]]*:[[:space:]]*0x//p' "$R/proc/cpuinfo" 2>/dev/null | head -n 1)"
  dv_p cpu_parts "$(sed -n 's/^CPU part[[:space:]]*:[[:space:]]*0x//p' "$R/proc/cpuinfo" 2>/dev/null | tr '\n' ',')"
  pl=""
  for p in "$R"/sys/devices/system/cpu/cpufreq/policy*; do
    [ -d "$p" ] || continue
    rcpu=$(dv_cat "$p/related_cpus"); [ -n "$rcpu" ] || rcpu=$(dv_cat "$p/affected_cpus")
    fc=${rcpu%% *}; nn=$(printf '%s\n' $rcpu | wc -l)
    pl="$pl${pl:+|}$fc:$nn:$(dv_cat "$p/cpuinfo_max_freq")"
  done
  dv_p cpu_policies "$pl"

  # --- GPU
  dv_gpu_node
  gname=$(dv_cat "$R/sys/class/kgsl/kgsl-3d0/gpu_model")
  glraw=""
  if command -v dumpsys >/dev/null 2>&1; then
    if command -v timeout >/dev/null 2>&1; then glraw=$(timeout 4 dumpsys SurfaceFlinger 2>/dev/null | grep -m1 'GLES:')
    else glraw=$(dumpsys SurfaceFlinger 2>/dev/null | grep -m1 'GLES:'); fi
  fi
  glraw=$(printf '%s' "$glraw" | sed 's/^[^:]*:[[:space:]]*//')
  dv_p gpu_name "$gname"
  dv_p gl_renderer "$(printf '%s' "$glraw" | cut -d, -f2 | sed 's/^[[:space:]]*//')"
  dv_p gl_vendor "$(printf '%s' "$glraw" | cut -d, -f1)"
  dv_p gl_version "$(printf '%s' "$glraw" | cut -d, -f3- | sed 's/^[[:space:]]*//')"
  dv_p gpu_node "${DV_GN##*/}"
  dv_p gpu_max_hz "$(dv_gpu_hz max)"

  # --- ROM penyimpanan (kapasitas blok terbesar = partisi user, bukan hanya /data)
  dv_p disk_sectors "$(cat "$R"/sys/block/sd[a-z]/size "$R"/sys/block/mmcblk[0-9]/size "$R"/sys/block/nvme[0-9]n[0-9]/size 2>/dev/null | sort -n | tail -n 1)"
  bd=$(dv_lc "$(getprop ro.boot.bootdevice 2>/dev/null)")
  case "$bd" in
    *ufs*) st=UFS ;;
    *mmc*|*sdhci*|*sdcc*) st=eMMC ;;
    *) if [ -e "$R/sys/block/sda" ]; then st=UFS; elif [ -e "$R/sys/block/mmcblk0" ]; then st=eMMC; else st=""; fi ;;
  esac
  dv_p storage_type "$st"

  # --- layar
  dv_p wm_size "$(wm size 2>/dev/null | sed -n 's/^Physical size:[[:space:]]*//p' | head -n 1)"
  dv_p wm_density "$(wm density 2>/dev/null | sed -n 's/^Physical density:[[:space:]]*//p' | head -n 1)"
  bp="$R/sys/class/power_supply/battery"; [ -d "$bp" ] || bp="$R/sys/class/power_supply/Battery"
  dv_p bat_design_uah "$(dv_cat "$bp/charge_full_design")"
  dv_p bat_tech "$(dv_cat "$bp/technology")"

  # --- Android / ROM
  dv_p android "$(getprop ro.build.version.release 2>/dev/null)"
  dv_p sdk "$(getprop ro.build.version.sdk 2>/dev/null)"
  dv_p patch "$(getprop ro.build.version.security_patch 2>/dev/null)"
  dv_p display_id "$(getprop ro.build.display.id 2>/dev/null)"
  dv_p incremental "$(getprop ro.build.version.incremental 2>/dev/null)"
  dv_p fingerprint "$(getprop ro.build.fingerprint 2>/dev/null)"
  dv_p build_tags "$(getprop ro.build.tags 2>/dev/null)"
  dv_p build_type "$(getprop ro.build.type 2>/dev/null)"
  dv_p build_utc "$(getprop ro.build.date.utc 2>/dev/null)"
  dv_rom
  dv_p rom_type "$RD_TYPE"; dv_p rom_name "$rd_name"; dv_p rom_ver "$rd_ver"
  dv_p rom_conf "$RD_CONF"; dv_p rom_why "$RD_WHY"
  dv_p treble "$(getprop ro.treble.enabled 2>/dev/null)"
  dv_p dynparts "$(getprop ro.boot.dynamic_partitions 2>/dev/null)"
  dv_p slot "$(getprop ro.boot.slot_suffix 2>/dev/null)"
  dv_p vboot "$(getprop ro.boot.verifiedbootstate 2>/dev/null)"
  dv_p bl_locked "$(getprop ro.boot.flash.locked 2>/dev/null)"
  dv_p selinux "$(getenforce 2>/dev/null)"
  dv_root

  # --- kernel
  dv_p kernel_rel "$(uname -r 2>/dev/null)"
  dv_p kernel_ver "$(uname -v 2>/dev/null)"
  dv_p kernel_arch "$(uname -m 2>/dev/null)"
  dv_p kernel_cc "$(grep -Eo '(clang|gcc)[^)]*version[^)]*' "$R/proc/version" 2>/dev/null | head -n 1)"
}

devinfo_all() { devinfo_static; devinfo_live; }
