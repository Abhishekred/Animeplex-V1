import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import '../admin/user_runtime_controls.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:watch_app/core/hive/safe_box.dart';
import 'package:hive/hive.dart';

/// Holds the id of the currently-active content source (e.g. 'allanime',
/// 'netmirror_pv') and **persists** it so the user's pick survives restarts.
///
/// The chosen id is written to a tiny Hive box on every change and read back at
/// construction. If the saved id is no longer valid (the provider was disabled
/// or uninstalled), it falls back to [fallback] so the app never boots pointing
/// at a source that isn't loaded.
class ActiveSourceCubit extends Cubit<String> {
  ActiveSourceCubit({
    Box? box,
    String fallback = 'allanime',
    Set<String>? valid,
  })  : _box = box,
        super(_restore(box, fallback, valid));

  static const String boxName = 'app_prefs';
  static const String _key = 'active_source';

  final Box? _box;

  /// Opens the prefs box. Call once during app bootstrap before constructing.
  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) {
      await openBoxSafely(boxName);
    }
  }

  static String _restore(Box? box, String fallback, Set<String>? valid) {
    final saved = box?.get(_key) as String?;
    if (saved != null &&
        saved.isNotEmpty &&
        (valid == null || valid.contains(saved))) {
      debugPrint(
        '[active-source] _restore · saved="$saved" → kept '
        '(valid=${valid?.length ?? "any"})',
      );
      return saved;
    }
    debugPrint(
      '[active-source] _restore · saved="$saved" → fallback="$fallback" '
      '(valid=${valid?.length ?? "any"} validSet=${valid?.take(5).toList()})',
    );
    return fallback;
  }

  void setSource(String id) {
    if (!UserRuntimeControls.maySelect(id)) {
      debugPrint('[active-source] Manual source change blocked by admin lock');
      return;
    }
    if (id == state) return;
    _applySource(id);
    unawaited(UserRuntimeControls.reportManualSelection(id));
  }

  /// Trusted app-side application of a server-selected provider. This does
  /// not call the manual-switch RPC or allow the user to bypass a lock.
  void setSourceFromAdmin(String id) {
    if (id == state) return;
    _applySource(id);
  }

  void _applySource(String id) {
    emit(id);
    _box?.put(_key, id);
  }

  /// Re-applies the persisted pick when it becomes valid *after* boot.
  ///
  /// Aniyomi sources load asynchronously, so a saved `ani:` source isn't in the
  /// valid set when [_restore] runs at construction — we fall back to a JS source
  /// then. Once the extensions register, the boot step calls this so the user's
  /// actual pick is honored instead of the fallback. Returns true if it changed.
  bool reapplySaved(bool Function(String id) isNowValid) {
    final saved = _box?.get(_key) as String?;
    if (saved == null || saved.isEmpty || saved == state) {
      debugPrint(
        '[active-source] reapplySaved · skip '
        '(saved="$saved" current="${state}" same=${saved == state})',
      );
      return false;
    }
    if (!isNowValid(saved)) {
      debugPrint('[active-source] reapplySaved · "$saved" not yet valid');
      return false;
    }
    debugPrint('[active-source] reapplySaved · "$saved" → applied');
    emit(saved);
    return true;
  }
}
