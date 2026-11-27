package com.spyou.watch_app.cloudstream

import android.content.Context
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import androidx.fragment.app.DialogFragment
import androidx.fragment.app.Fragment
import androidx.fragment.app.FragmentManager

/** Suppress the optional support prompts bundled in these CloudStream plugins. */
internal object ExtensionDonationDialogs : FragmentManager.FragmentLifecycleCallbacks() {
    private val dialogClasses = setOf(
        "com.phisher98.donation.DonationDialogFragment",
        "com.phisher98.donation.DonationBottomSheet",
        "com.cncverse.donation.DonationDialogFragment",
    )

    fun isBlockedDialogClassName(name: String): Boolean = name in dialogClasses

    fun install(manager: FragmentManager) {
        manager.registerFragmentLifecycleCallbacks(this, true)
    }

    override fun onFragmentPreAttached(fm: FragmentManager, f: Fragment, context: Context) {
        if (f is DialogFragment && isBlockedDialogClassName(f.javaClass.name)) {
            f.showsDialog = false
        }
    }

    override fun onFragmentCreated(fm: FragmentManager, f: Fragment, savedInstanceState: Bundle?) {
        if (f !is DialogFragment || !isBlockedDialogClassName(f.javaClass.name)) return
        // DialogFragment resets showsDialog in onCreate, before creating its window.
        f.showsDialog = false
        Handler(Looper.getMainLooper()).post {
            if (f.isAdded && !fm.isDestroyed) f.dismissAllowingStateLoss()
        }
    }
}
