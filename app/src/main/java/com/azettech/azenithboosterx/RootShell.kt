package com.azettech.azenithboosterx

import android.content.Context
import android.content.res.AssetManager
import com.topjohnwu.superuser.Shell
import java.io.File

/**
 * Menjembatani app ke akses root (su), menggantikan posisi modul Magisk.
 * Struktur script asli (common.sh, support.sh, folder lib, thermalx CLI) dibundel
 * sebagai asset lalu dideploy apa adanya ke /data/local/tmp/azenith_scripts,
 * supaya CLI "thermalx" dan common.sh (yang saling memanggil pakai $MODDIR/lib/...)
 * tetap jalan tanpa perlu diubah.
 */
object RootShell {

    const val REMOTE_DIR = "/data/local/tmp/azenith_scripts"
    private const val ASSET_ROOT = "scripts"

    init {
        Shell.enableVerboseLogging = false
        Shell.setDefaultBuilder(
            Shell.Builder.create()
                .setFlags(Shell.FLAG_REDIRECT_STDERR)
                .setTimeout(15)
        )
    }

    fun isRootAvailable(): Boolean = Shell.getShell().isRoot

    /** Jalankan satu perintah shell sebagai root, kembalikan output gabungan. */
    fun run(command: String): String {
        val result = Shell.cmd(command).exec()
        return result.out.joinToString("\n")
    }

    /** Salin seluruh assets/scripts (termasuk folder lib) ke filesDir app, lalu push ke root. */
    fun deployScripts(context: Context): String {
        val localRoot = File(context.filesDir, ASSET_ROOT)
        if (localRoot.exists()) localRoot.deleteRecursively()
        localRoot.mkdirs()
        copyAssetDirRecursive(context.assets, ASSET_ROOT, localRoot)

        return run(
            "rm -rf $REMOTE_DIR && mkdir -p $REMOTE_DIR && " +
                "cp -rf ${localRoot.absolutePath}/. $REMOTE_DIR/ && " +
                "chmod -R 755 $REMOTE_DIR"
        )
    }

    /** Panggil CLI "thermalx" asli lewat MODDIR yang diarahkan ke direktori deploy. */
    fun cli(vararg args: String): String {
        val argStr = args.joinToString(" ")
        return run("MODDIR=$REMOTE_DIR sh $REMOTE_DIR/thermalx $argStr")
    }

    private fun copyAssetDirRecursive(assets: AssetManager, assetPath: String, outDir: File) {
        val entries = assets.list(assetPath) ?: return
        for (entry in entries) {
            val childAssetPath = "$assetPath/$entry"
            val childEntries = assets.list(childAssetPath)
            if (!childEntries.isNullOrEmpty()) {
                val childDir = File(outDir, entry)
                childDir.mkdirs()
                copyAssetDirRecursive(assets, childAssetPath, childDir)
            } else {
                assets.open(childAssetPath).use { input ->
                    File(outDir, entry).outputStream().use { output -> input.copyTo(output) }
                }
            }
        }
    }
}
