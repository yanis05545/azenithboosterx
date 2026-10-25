# AzenithBoosterX — Aplikasi (bukan modul)

Port dari modul root AzenithBoosterX/ThermalX Gaming Booster v2.6.0 menjadi
**aplikasi Android mandiri** yang meminta akses root sendiri lewat `su`
(pakai library [libsu](https://github.com/topjohnwu/libsu)), tanpa perlu
diflash lewat Magisk/KernelSU/APatch.

Semua script root asli (`common.sh`, `support.sh`, `lib/*.sh`, CLI `thermalx`)
tidak diubah logikanya — hanya dipindah ke `app/src/main/assets/scripts/`
dan dideploy app ke `/data/local/tmp/azenith_scripts` saat app dibuka.
WebUI lama (`webroot/index.html`) juga dipakai ulang, disajikan dari
`file:///android_asset/webroot/index.html`, dengan shim kecil di bagian
`<head>` yang mengarahkan `ksu.exec(...)` ke jembatan root milik app sendiri
(lihat `WebAppInterface.kt`).

## 1. Build langsung di Termux (tanpa PC)

```bash
pkg update && pkg upgrade
pkg install openjdk-17 gradle git -y

# clone / masuk ke folder project ini
cd AzenithBoosterX-App

# build APK debug (sudah bisa diinstall & dites)
gradle assembleDebug --no-daemon

# APK ada di:
# app/build/outputs/apk/debug/app-debug.apk
```

Install ke perangkat (Termux harus punya akses storage, atau pakai `adb` lewat `pkg install android-tools`):

```bash
termux-setup-storage
cp app/build/outputs/apk/debug/app-debug.apk /sdcard/Download/
# lalu install manual lewat file manager / tap notifikasi
```

Kalau RAM Termux pas-pasan, kecilkan heap Gradle di `gradle.properties`
(`-Xmx2048m` → `-Xmx1024m`) dan tutup app lain saat build.

## 2. Push ke GitHub

```bash
pkg install git -y
git init
git add .
git commit -m "Initial AzenithBoosterX app"
git branch -M main
git remote add origin https://github.com/USERNAME/AzenithBoosterX-App.git
git push -u origin main
```

## 3. Build otomatis via GitHub Actions

Workflow `.github/workflows/build-apk.yml` sudah disiapkan: setiap `git push`
ke branch `main`, GitHub otomatis build APK debug & release (unsigned), lalu
APK bisa diunduh dari tab **Actions → (run terbaru) → Artifacts** di repo.

Tidak perlu `gradlew`/Gradle Wrapper — workflow memakai
`gradle/actions/setup-gradle` yang menginstal Gradle sendiri di runner.

## 4. Menandatangani APK release (opsional, biar bisa update tanpa uninstall)

APK release dari langkah di atas belum ditandatangani. Supaya bisa diupdate
di perangkat yang sama, generate keystore sekali (simpan baik-baik, jangan
di-commit ke repo publik):

```bash
keytool -genkeypair -v -keystore azenith.keystore -alias azenith \
  -keyalg RSA -keysize 2048 -validity 10000
```

Lalu tanda tangani manual dengan `apksigner` (ada di `android-tools`/Android
SDK build-tools), atau tambahkan signing config di `app/build.gradle.kts`
dan simpan password sebagai **GitHub Secrets**, bukan di file.

## Struktur project

```
AzenithBoosterX-App/
├── app/
│   ├── build.gradle.kts            # dependency: libsu, coroutines, appcompat
│   └── src/main/
│       ├── AndroidManifest.xml
│       ├── java/com/azettech/azenithboosterx/
│       │   ├── MainActivity.kt     # load WebView + minta root saat app dibuka
│       │   ├── RootShell.kt        # eksekusi perintah root via libsu
│       │   └── WebAppInterface.kt  # jembatan JS (window.AzenithApp) <-> Kotlin
│       ├── res/                    # layout WebView fullscreen, tema gelap
│       └── assets/
│           ├── scripts/            # persis isi modul lama: common.sh, support.sh,
│           │                       # lib/*.sh, thermalx (CLI), *.conf
│           └── webroot/index.html  # WebUI lama + shim ksu.exec -> AzenithApp
├── .github/workflows/build-apk.yml
└── build.gradle.kts / settings.gradle.kts / gradle.properties
```

## Alur kerja app saat dibuka

1. `MainActivity` minta akses `su` lewat `RootShell.isRootAvailable()`.
2. Jika root diberikan, `RootShell.deployScripts()` menyalin
   `assets/scripts/**` ke `/data/local/tmp/azenith_scripts` (dengan `chmod 755`).
3. WebView memuat `webroot/index.html`. Setiap tombol di WebUI yang
   sebelumnya memanggil `ksu.exec(...)` sekarang otomatis lewat shim ke
   `AzenithApp.runCommand(...)`, yang menjalankan `su -c "..."` lewat libsu.
4. CLI asli `thermalx status|on|off|preset|...` tetap dipanggil sama persis,
   hanya `MODDIR` diarahkan ke `/data/local/tmp/azenith_scripts`.

## Catatan

- `applicationId` / package: `com.azettech.azenithboosterx` — ganti sesuai
  kebutuhan di `app/build.gradle.kts` dan path folder Kotlin kalau mau beda.
- Ikon masih placeholder (`res/drawable/ic_launcher.xml`) — ganti sebelum rilis.
- File yang sebelumnya dibaca modul dari `/data/adb/thermalx/...` (konfigurasi,
  log, dsb.) kemungkinan perlu disesuaikan path-nya di `common.sh` kalau kamu
  ingin semua data app tersimpan di `/data/local/tmp/azenith_scripts` juga,
  supaya tidak tercampur sisa data modul lama (kalau modul lama masih terpasang).
