import '../di/injector.dart';
import '../supabase/supabase_service.dart';

/// Restricts the Sources settings section to accounts explicitly authorized
/// by the AnimePlex admin. No local setting can grant access.
class SourcesAccessPermission {
  SourcesAccessPermission._();

  static bool canShow({
    required String? currentUserId,
    required String? verifiedUserId,
    required bool granted,
  }) =>
      granted &&
      currentUserId != null &&
      currentUserId.isNotEmpty &&
      currentUserId == verifiedUserId;

  static Future<bool> fetchForUser(String? userId) async {
    if (userId == null || userId.isEmpty ||
        !sl.isRegistered<SupabaseService>()) return false;
    try {
      final supabase = sl<SupabaseService>();
      if (supabase.currentUserId() != userId) return false;
      final row = await supabase.client
          .from('animeplex_user_permissions')
          .select('sources_access')
          .eq('user_id', userId)
          .maybeSingle();
      return supabase.currentUserId() == userId &&
          row?['sources_access'] == true;
    } catch (_) {
      // Deny on network/auth failures, never fall back to a stale grant.
      return false;
    }
  }
}
