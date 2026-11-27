package com.spyou.watch_app.cloudstream

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PhisherDonationBlockerTest {
    @Test fun blocksOnlyKnownExtensionDonationFragments() {
        assertTrue(ExtensionDonationDialogs.isBlockedDialogClassName(
            "com.phisher98.donation.DonationDialogFragment"))
        assertTrue(ExtensionDonationDialogs.isBlockedDialogClassName(
            "com.phisher98.donation.DonationBottomSheet"))
        assertTrue(ExtensionDonationDialogs.isBlockedDialogClassName(
            "com.cncverse.donation.DonationDialogFragment"))
        assertFalse(ExtensionDonationDialogs.isBlockedDialogClassName(
            "com.phisher98.settings.PluginSettingsDialog"))
        assertFalse(ExtensionDonationDialogs.isBlockedDialogClassName(
            "com.cncverse.cloudflare.CloudflareDialogFragment"))
        assertFalse(ExtensionDonationDialogs.isBlockedDialogClassName(
            "com.other.donation.DonationDialogFragment"))
    }
}
