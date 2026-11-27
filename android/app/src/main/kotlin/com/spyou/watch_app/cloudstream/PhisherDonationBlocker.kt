package com.spyou.watch_app.cloudstream

import android.util.Log

/**
 * Block only the donation overlay shipped inside Phisher98 CloudStream .cs3
 * plugins. The extension's MainAPI, network, playback, Cloudflare verification
 * and its other dialogs are not modified.
 */
internal object PhisherDonationBlocker {
    private const val TAG = "PhisherDonationBlocker"
    private const val MANAGER_CLASS = "com.phisher98.donation.DonationManager"

    /**
     * The verified Phisher98 plugin's DonationManager has a static volatile
     * isDialogShowing flag checked before starting a dialog. Mark it true
     * after plugin.load() so the donation path is skipped at its source.
     * The extension dialog lifecycle callbacks are a second guard for
     * already-queued or later-reset dialogs.
     */
    fun suppressManager(loader: ClassLoader) {
        val managerClass = try {
            Class.forName(MANAGER_CLASS, false, loader)
        } catch (_: ClassNotFoundException) {
            return // Most installed plugins do not bundle this manager.
        } catch (t: Throwable) {
            Log.w(TAG, "Could not inspect extension donation manager", t)
            return
        }
        // Never touch app classes or another extension's class loader.
        if (managerClass.classLoader !== loader) return
        runCatching {
            val field = managerClass.getDeclaredField("isDialogShowing")
            field.isAccessible = true
            field.setBoolean(null, true)
        }.onFailure {
            Log.w(TAG, "Could not suppress extension donation manager", it)
        }
    }
}
