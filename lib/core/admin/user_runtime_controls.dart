import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Non-privileged, read-only snapshot of account restrictions.
@immutable
class UserRuntimeSnapshot {
  const UserRuntimeSnapshot({
    this.userId,
    this.currentProviderId,
    this.forcedProviderId,
    this.providerLocked = false,
    this.isBanned = false,
    this.banReason,
  });

  final String? userId;
  final String? currentProviderId;
  final String? forcedProviderId;
  final bool providerLocked;
  final bool isBanned;
  final String? banReason;

  factory UserRuntimeSnapshot.fromMap(String id, Map<String, dynamic>? row) =>
      UserRuntimeSnapshot(
        userId: id,
        currentProviderId: row?['current_provider_id'] as String?,
        forcedProviderId: row?['forced_provider_id'] as String?,
        providerLocked: row?['provider_locked'] == true,
        isBanned: row?['is_banned'] == true,
        banReason: row?['ban_reason'] as String?,
      );
}

/// The admin is authoritative for bans and locks. User changes are reported
/// through an authenticated RPC, where lock/ban status is rechecked by Postgres.
/// The app never carries service-role credentials or writes control columns.
class UserRuntimeControls {
  UserRuntimeControls._();

  static final ValueNotifier<UserRuntimeSnapshot> state =
      ValueNotifier<UserRuntimeSnapshot>(const UserRuntimeSnapshot());
  static bool _refreshing = false;

  static bool maySelect(String sourceId) {
    final row = state.value;
    if (row.isBanned) return false;
    return !row.providerLocked ||
        (row.forcedProviderId != null && row.forcedProviderId == sourceId);
  }

  static bool get manualSwitchLocked =>
      state.value.providerLocked && state.value.userId != null;

  /// Adopt the cached restrictions as soon as the authenticated profile loads.
  static void adoptUser(String uid) {
    if (state.value.userId != uid) state.value = _fromCache(uid);
  }


  static void resetOnLogout() {
    state.value = const UserRuntimeSnapshot();
  }

  static UserRuntimeSnapshot _fromCache(String uid) {
    try {
      final box = Hive.isBoxOpen('app_prefs') ? Hive.box('app_prefs') : null;
      final data = box?.get('animeplex.user.access.$uid');
      if (data is Map) {
        return UserRuntimeSnapshot(
          userId: uid,
          isBanned: data['is_banned'] == true,
          banReason: data['ban_reason'] is String ? data['ban_reason'] as String : null,
          providerLocked: data['provider_locked'] == true,
          forcedProviderId: data['forced_provider_id'] as String?,
        );
      }
    } catch (_) {}
    return UserRuntimeSnapshot(userId: uid);
  }

  static Future<void> _cache(UserRuntimeSnapshot current) async {
    final uid = current.userId;
    if (uid == null || !Hive.isBoxOpen('app_prefs')) return;
    try {
      await Hive.box('app_prefs').put('animeplex.user.access.$uid', {
        'is_banned': current.isBanned,
        'ban_reason': current.banReason,
        'provider_locked': current.providerLocked,
        'forced_provider_id': current.forcedProviderId,
      });
    } catch (_) {}
  }

  /// Read the signed-in user's own restricted state via RLS.
  /// Offline failures do not clear a known ban/lock.
  static Future<UserRuntimeSnapshot?> refresh() async {
    final client = Supabase.instance.client;
    final uid = client.auth.currentUser?.id;
    if (uid == null) return null;
    if (state.value.userId != uid) state.value = _fromCache(uid);
    if (_refreshing) return state.value;
    _refreshing = true;
    try {
      final row = await client
          .from('animeplex_user_runtime_controls')
          .select('current_provider_id,forced_provider_id,provider_locked,is_banned,ban_reason')
          .eq('user_id',uid)
          .maybeSingle()
          .timeout(const Duration(seconds: 8));
      if (client.auth.currentUser?.id != uid) return null;
      final next=UserRuntimeSnapshot.fromMap(uid,row);
      state.value=next;
      unawaited(_cache(next));
      return next;
    } catch (error) {
      debugPrint('[account-controls] Status unavailable: $error');
      return state.value;
    } finally {
      _refreshing=false;
    }
  }

  /// RPC enforces that the caller isn't banned/locked, and checks that
  /// the selected ID is in the device's most recent reported install list.
  static Future<void> reportManualSelection(String sourceId) async {
    if (!maySelect(sourceId)) return;
    final client = Supabase.instance.client;
    if (client.auth.currentUser == null) return;
    try {
      await client.rpc('animeplex_user_choose_source',
        params: {'p_source_id':sourceId},
      ).timeout(const Duration(seconds: 8));
    } catch (error) {
      debugPrint('[account-controls] Source change not accepted remotely: $error');
      unawaited(refresh());
    }
  }

  /// Only report installed, enabled providers. This is device telemetry:
  /// it does not mean the admin can install a source from a remote webpage.
  static Future<void> reportAvailable({
    required String currentSourceId,
    required List<({String id, String name})> sources,
  }) async {
    final client=Supabase.instance.client;
    final uid=client.auth.currentUser?.id;
    if (uid == null || state.value.isBanned) return;
    final seen=<String>{};
    final items=<Map<String,String>>[];
    for(final item in sources){
      if(!RegExp(r'^[A-Za-z0-9_./:@+-]{1,220}$').hasMatch(item.id))continue;
      if(!seen.add(item.id))continue;
      if(item.name.trim().isEmpty)continue;
      items.add({'id':item.id,'name':item.name.trim().substring(
        0,item.name.trim().length>120?120:item.name.trim().length)});
      if(items.length>=150)break;
    }
    try {
      await client.rpc('animeplex_user_report_sources',params:{
        'p_current_provider_id':currentSourceId,
        'p_sources':items,
      }).timeout(const Duration(seconds: 12));
    } catch (error) {
      debugPrint('[account-controls] Installed source report unavailable: $error');
    }
  }
}
