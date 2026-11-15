import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../../core/ui/settings_widgets.dart';

import '../../core/announce/announcement.dart';
import '../../core/app_mode.dart';
import '../../core/di/injector.dart';
import '../../core/models/media_item.dart';
import '../../core/models/provider_info.dart';
import '../../core/notify/cs_notify.dart';
import '../../core/notify/notification_prefs.dart';
import '../../core/notify/push_service.dart';
import '../../core/notify/subscription_checker.dart';
import '../../core/notify/subscription_store.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/states.dart';
import '../announce/announcement_sheet.dart';
import '../detail/detail_screen.dart';
import 'subscriptions_screen_tv.dart';
import '../../l10n/l10n.dart';

/// The Notifications screen: developer announcements (history) on top, then the
/// "new episode" subscriptions (the shows the bell on Detail subscribed to).
/// Opening it clears the announcement badge.
class SubscriptionsScreen extends StatefulWidget {
  const SubscriptionsScreen({super.key});

  @override
  State<SubscriptionsScreen> createState() => _SubscriptionsScreenState();
}

class _SubscriptionsScreenState extends State<SubscriptionsScreen> {
  SubscriptionStore get _store => sl<SubscriptionStore>();
  AnnouncementStore get _announcements => sl<AnnouncementStore>();

  @override
  void initState() {
    super.initState();
    // Viewing the list clears the "new announcement" badge.
    _announcements.markAllSeen();
  }

  Future<void> _openDetail(Subscription s) async {
    await Navigator.of(context).push(
      DetailScreen.route(
        MediaItem(
          id: s.url,
          title: s.title,
          url: s.url,
          type: ProviderType.anime,
          sourceId: s.sourceId,
          cover: s.cover,
          coverHeaders: s.coverHeaders,
        ),
      ),
    );
    if (mounted) setState(() {}); // reflect an unsubscribe done from the detail
  }

  Future<void> _remove(Subscription s) async {
    await _store.remove(s.sourceId, s.url);
    await CsNotify.sync(_store.all()); // drop it from the native worker too
    if (mounted) setState(() {});
  }

  Future<void> _checkNow() async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(content: Text(context.l10n.checkingForNewEpisodes)),
    );
    await sl<SubscriptionChecker>().checkAll(); // JS sources
    await CsNotify.checkNow(); // CS sources (native worker)
    if (mounted) setState(() {});
  }

  Future<void> _setPreference(String kind, bool enabled) async {
    await NotificationPrefs.setEnabled(kind, enabled);
    if (kind == NotificationPrefs.updates) {
      await PushService.instance.syncUpdatePreference();
    }
    if (mounted) setState(() {});
  }

  Widget _preference(String kind, String title, String subtitle) =>
      SwitchListTile(
        title: Text(title, style: AppText.body),
        subtitle: Text(subtitle, style: AppText.caption),
        value: NotificationPrefs.enabled(kind),
        onChanged: (value) => _setPreference(kind, value),
      );

  String _sourceLabel(String sourceId) =>
      sourceId.startsWith('cs:') ? sourceId.substring(3) : sourceId;

  @override
  Widget build(BuildContext context) {
    if (sl<AppMode>().isTv) return const SubscriptionsScreenTv();
    final subs = _store.all();
    final announcements = _announcements.all();
    final empty = subs.isEmpty && announcements.isEmpty;
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: settingsAppBar(
        context.l10n.notifications,
        actions: [
          if (subs.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.refresh_rounded),
              tooltip: context.l10n.checkNow,
              onPressed: _checkNow,
            ),
        ],
      ),
      body: false && empty
          ? EmptyState(
              icon: Icons.notifications_none_rounded,
              message: context.l10n.noNotificationsYet,
            )
          : ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                _header('Notification preferences'),
                _preference(NotificationPrefs.episode, 'New episodes',
                    'Alerts for subscribed anime'),
                _preference(NotificationPrefs.chapter, 'New chapters',
                    'Alerts for subscribed manga and novels'),
                _preference(NotificationPrefs.updates, 'App updates',
                    'Firebase notifications when a new APK is published'),
                const Divider(),
                if (announcements.isNotEmpty) ...[
                  _header(context.l10n.announcements),
                  for (final a in announcements) _announcementTile(a),
                ],
                if (subs.isNotEmpty) ...[
                  if (announcements.isNotEmpty) const SizedBox(height: 8),
                  _header(context.l10n.subscribedShows),
                  for (final s in subs) _subscriptionTile(s),
                ],
              ],
            ),
    );
  }

  Widget _header(String label) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
    child: Text(
      label.toUpperCase(),
      style: AppText.caption.copyWith(
        color: AppColors.textSecondary,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.6,
      ),
    ),
  );

  Widget _announcementTile(Announcement a) {
    final (icon, tint) = switch (a.type) {
      'warning' => (Icons.warning_amber_rounded, const Color(0xFFF2B01E)),
      'update' => (Icons.system_update_rounded, AppColors.accent),
      _ => (Icons.campaign_rounded, AppColors.accent),
    };
    final iconAvatar = CircleAvatar(
      radius: 20,
      backgroundColor: tint.withValues(alpha: 0.14),
      child: Icon(icon, color: tint, size: 20),
    );
    final hasImage = a.imageUrl != null && a.imageUrl!.isNotEmpty;
    return ListTile(
      // Re-open the full message (with its action button) in the sheet.
      onTap: () => showAnnouncementSheet(context, a),
      leading: hasImage
          ? ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 44,
                height: 44,
                child: CachedNetworkImage(
                  imageUrl: a.imageUrl!,
                  fit: BoxFit.cover,
                  // 44x44 icon: decode small.
                  memCacheWidth: 132,
                  errorWidget: (_, _, _) => iconAvatar,
                ),
              ),
            )
          : iconAvatar,
      title: Text(
        a.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: AppText.body.copyWith(
          color: AppColors.textPrimary,
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: a.body.isEmpty
          ? null
          : Text(
              a.body,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppText.caption,
            ),
    );
  }

  Widget _subscriptionTile(Subscription s) => ListTile(
    onTap: () => _openDetail(s),
    leading: ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: 44,
        height: 62,
        child: (s.cover != null && s.cover!.isNotEmpty)
            ? CachedNetworkImage(
                imageUrl: s.cover!,
                httpHeaders: s.coverHeaders,
                fit: BoxFit.cover,
                // 44x62 thumb: decode small, not full poster.
                memCacheWidth: 132,
                errorWidget: (_, _, _) => ColoredBox(color: AppColors.surface2),
              )
            : ColoredBox(color: AppColors.surface2),
      ),
    ),
    title: Text(
      s.title,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: AppText.body.copyWith(color: AppColors.textPrimary),
    ),
    subtitle: Text(_sourceLabel(s.sourceId), style: AppText.caption),
    trailing: IconButton(
      icon: const Icon(
        Icons.notifications_off_outlined,
        color: AppColors.textSecondary,
      ),
      tooltip: context.l10n.turnOff,
      onPressed: () => _remove(s),
    ),
  );
}
