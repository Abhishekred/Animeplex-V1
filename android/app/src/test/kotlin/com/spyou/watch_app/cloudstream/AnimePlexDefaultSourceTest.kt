package com.spyou.watch_app.cloudstream

import android.content.Context
import androidx.fragment.app.DialogFragment
import androidx.fragment.app.Fragment
import androidx.fragment.app.FragmentActivity
import androidx.test.core.app.ApplicationProvider
import java.io.File
import java.util.zip.ZipFile
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class AnimePlexDefaultSourceTest {
    private lateinit var context: Context
    private lateinit var repo: RepoManager

    @Before
    fun reset() {
        context = ApplicationProvider.getApplicationContext()
        context.getSharedPreferences("animeplex_defaults", Context.MODE_PRIVATE).edit().clear().commit()
        context.getSharedPreferences("phisher_donation_prefs", Context.MODE_PRIVATE).edit().clear().commit()
        File(context.filesDir, "cs3").deleteRecursively()
        repo = RepoManager(context)
    }

    @Test
    fun `bundled MovieBox is installed without network on first launch`() {
        repo.ensureBundledMovieBox()
        val plugin = repo.cachedFiles().single()
        assertEquals("MovieBoxProvider@41@${RepoManager.repoTag(RepoManager.DEFAULT_REPO_URL)}.cs3", plugin.name)
        assertArrayEquals(
            context.assets.open("preinstalled/MovieBoxProvider.cs3").use { it.readBytes() },
            plugin.readBytes(),
        )
        ZipFile(plugin).use { assertNotNull(it.getEntry("classes.dex")) }
    }

    @Test
    fun `a user uninstall is not undone on the next launch`() {
        repo.ensureBundledMovieBox()
        assertEquals(true, repo.cachedFiles().single().delete())
        repo.ensureBundledMovieBox()
        assertEquals(0, repo.cachedFiles().size)
    }

    @Test
    fun `only the Phisher popup is dismissed`() {
        val activity = Robolectric.buildActivity(FragmentActivity::class.java).setup().get()
        PhisherPopupGuard.attach(activity)
        val prefs = context.getSharedPreferences("phisher_donation_prefs", Context.MODE_PRIVATE)
        assertEquals(Long.MAX_VALUE, prefs.getLong("phisher_donation_last_shown_v2", 0))

        val manager = activity.supportFragmentManager
        val other = Fragment()
        manager.beginTransaction().add(other, "other").commitNow()
        val phisher = DialogFragment()
        manager.beginTransaction().add(phisher, "phisher_donation_floating_dialog").commitNow()
        manager.executePendingTransactions()

        assertFalse(phisher.getShowsDialog())
        assertNull(manager.findFragmentByTag("phisher_donation_floating_dialog"))
        assertNotNull(manager.findFragmentByTag("other"))
    }
}
