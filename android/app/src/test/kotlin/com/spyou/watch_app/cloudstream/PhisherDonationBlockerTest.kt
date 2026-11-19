package com.spyou.watch_app.cloudstream

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PhisherDonationBlockerTest {
    @Test fun blocksOnlyKnownPhisherDonationFragments() {
        assertTrue(PhisherDonationBlocker.isBlockedDialogClassName(
            "com.phisher98.donation.DonationDialogFragment"))
        assertTrue(PhisherDonationBlocker.isBlockedDialogClassName(
            "com.phisher98.donation.DonationBottomSheet"))
        assertFalse(PhisherDonationBlocker.isBlockedDialogClassName(
            "com.phisher98.settings.PluginSettingsDialog"))
        assertFalse(PhisherDonationBlocker.isBlockedDialogClassName(
            "com.cncverse.cloudflare.CloudflareDialogFragment"))
        assertFalse(PhisherDonationBlocker.isBlockedDialogClassName(
            "com.other.donation.DonationDialogFragment"))
    }
}
