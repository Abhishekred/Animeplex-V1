import 'package:hive/hive.dart';

/// Device-local notification choices. Stored in the already-open subscriptions
/// box so preferences survive restarts without a new initialization step.
class NotificationPrefs {
  static const _prefix = 'notification_pref_';
  static const episode = 'episode';
  static const chapter = 'chapter';
  static const updates = 'updates';

  static bool enabled(String kind) {
    if (!Hive.isBoxOpen('subscriptions')) return true;
    return Hive.box('subscriptions').get('$_prefix$kind', defaultValue: true) != false;
  }

  static Future<void> setEnabled(String kind, bool value) async {
    await Hive.box('subscriptions').put('$_prefix$kind', value);
  }
}
