package com.spyou.watch_app.cloudstream

import android.content.Context
import android.os.Bundle
import androidx.fragment.app.DialogFragment
import androidx.fragment.app.Fragment
import androidx.fragment.app.FragmentActivity
import androidx.fragment.app.FragmentManager

/** Suppress only the Phisher funding popup embedded in CloudStream extensions. */
object PhisherPopupGuard {
    fun suppress(context: Context) {
        // Phisher's DonationManager reads this cooldown before starting its
        // popup/network work. A future timestamp keeps it in cooldown.
        context.getSharedPreferences("phisher_donation_prefs", Context.MODE_PRIVATE)
            .edit().putLong("phisher_donation_last_shown_v2", Long.MAX_VALUE).apply()
    }

    fun attach(activity: FragmentActivity) {
        suppress(activity)
        // Also catch versions that bypass the cooldown. Other plugin dialogs,
        // including settings and Cloudflare verification, remain unaffected.
        activity.supportFragmentManager.registerFragmentLifecycleCallbacks(
            object : FragmentManager.FragmentLifecycleCallbacks() {
                override fun onFragmentCreated(
                    fm: FragmentManager,
                    fragment: Fragment,
                    savedInstanceState: Bundle?,
                ) {
                    if (fragment is DialogFragment &&
                        (fragment.javaClass.name == "com.phisher98.donation.DonationDialogFragment" ||
                            fragment.tag == "phisher_donation_floating_dialog")
                    ) {
                        fragment.setShowsDialog(false)
                        fragment.dismissAllowingStateLoss()
                    }
                }
            },
            true,
        )
    }
}
