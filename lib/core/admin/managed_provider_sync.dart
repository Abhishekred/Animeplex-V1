import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import '../provider/cloudstream_provider.dart';
import '../state/active_source_cubit.dart';
import '../supabase/supabase_service.dart';
import '../zmode/source_order_prefs.dart';
import '../zmode/zmode_ids.dart';

/// Remote, admin-managed CloudStream plugins. Only enabled public configuration
/// rows are read; secrets, app accounts and user content are never uploaded.
/// Network failures preserve installed extensions and their current state.
class ManagedProviderDefinition {
  const ManagedProviderDefinition({
    required this.id, required this.repoUrl, required this.pluginId,
    required this.priority, required this.autoInstall, required this.isDefault,
  });
  final String id;
  final String repoUrl;
  final String pluginId;
  final int priority;
  final bool autoInstall;
  final bool isDefault;

  String get key => repoUrl + '|' + pluginId;

  static ManagedProviderDefinition? fromJson(Map<String, dynamic> row) {
    final id = row['id'];
    final url = row['repo_url'];
    final plugin = row['plugin_id'];
    if (id is! String || id.isEmpty ||
        url is! String || plugin is! String ||
        !isAllowedRepoUrl(url) ||
        !RegExp(r'^[A-Za-z0-9_.-]{1,120}$').hasMatch(plugin) ||
        row['enabled'] != true) {
      return null;
    }
    return ManagedProviderDefinition(
      id: id, repoUrl: url, pluginId: plugin,
      priority: (row['priority'] as num?)?.toInt() ?? 100,
      autoInstall: row['auto_install'] == true,
      isDefault: row['is_default'] == true,
    );
  }

  static bool isAllowedRepoUrl(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null || uri.scheme != 'https' ||
        uri.host != 'raw.githubusercontent.com' ||
        uri.hasQuery || uri.hasFragment || uri.userInfo.isNotEmpty ||
        uri.pathSegments.length < 4 ||
        uri.pathSegments.last != 'repo.json' ||
        uri.pathSegments.any((part) => part == '..' || part.isEmpty) ||
        value.length > 500) return false;
    return uri.pathSegments.every((part) =>
      RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(part));
  }
}

class ManagedProviderSync {
  ManagedProviderSync._();

  static const _box = 'app_prefs';
  static const _managedKey = 'animeplex.managed.provider.plugins.v1';
  static const _defaultKey = 'animeplex.managed.provider.default.v1';

  static Future<void> apply({
    required CloudStreamManager manager,
    required SupabaseService supabase,
    required ActiveSourceCubit active,
    SourceOrderPrefs? orderPrefs,
  }) async {
    if (!Platform.isAndroid) return;

    // The enabled-only filter matters even for an admin who signs in to the
    // Android app (admin users can otherwise read disabled management rows).
    final data = await supabase.client
        .from('animeplex_managed_providers')
        .select('id,repo_url,plugin_id,enabled,auto_install,is_default,priority')
        .eq('enabled', true)
        .order('priority', ascending: true)
        .limit(40);

    final definitions = <ManagedProviderDefinition>[
      for (final item in data)
        if (ManagedProviderDefinition.fromJson(item) case final value?)
          value,
    ]..sort((a,b) => a.priority.compareTo(b.priority));

    final prefs = Hive.isBoxOpen(_box) ? Hive.box(_box) : null;
    final old = (prefs?.get(_managedKey) as List?)
        ?.whereType<String>().toSet() ?? <String>{};
    final current = <String>{};
    final preferredIds = <String>[];
    String? remoteDefaultId;
    String? remoteDefaultSource;

    for (final p in definitions) {
      current.add(p.key);
      try {
        if (!manager.hasRepo(p.repoUrl)) {
          await manager.addRepo(p.repoUrl)
              .timeout(const Duration(seconds: 15));
        }
        await manager.ensureCatalog(p.repoUrl)
            .timeout(const Duration(seconds: 15));
        final groups = manager.repoGroups
            .where((g) => g.url == p.repoUrl);
        if (groups.isEmpty) continue;
        var group = groups.first;
        final plugins = group.catalog.where((plugin) =>
            plugin.internalName.toLowerCase() == p.pluginId.toLowerCase());
        if (plugins.isEmpty) continue;
        final plugin = plugins.first;
        if (p.autoInstall &&
            !manager.isPluginInstalled(plugin.internalName,repoUrl:p.repoUrl)) {
          await manager.installPlugin(plugin, repoUrl:p.repoUrl)
              .timeout(const Duration(seconds: 25));
        }
        final refreshed = manager.repoGroups
            .where((g) => g.url == p.repoUrl);
        if (refreshed.isEmpty) continue;
        group = refreshed.first;
        final sources = group.sources.where((source) =>
          source.sourcePlugin?.split('@').first.toLowerCase() ==
              p.pluginId.toLowerCase()).toList();
        for (final source in sources) {
          await manager.setEnabled(source.sourceId, true);
          preferredIds.add(source.sourceId);
        }
        if (p.isDefault && sources.isNotEmpty) {
          remoteDefaultId = p.id;
          remoteDefaultSource = sources.first.sourceId;
        }
      } catch (error) {
        debugPrint('[managed-providers] Could not activate ' +
            p.pluginId + ': ' + error.toString());
        // A failing plugin never prevents the remaining entries from syncing.
      }
    }
    // Retired or disabled admin-managed plugins remain on disk, but are not
    // offered to the viewer. Never uninstall an extension on a remote delete.
    for (final key in old.difference(current)) {
      final delimiter = key.lastIndexOf('|');
      if (delimiter < 1) continue;
      final repo = key.substring(0, delimiter);
      final plugin = key.substring(delimiter + 1).toLowerCase();
      for (final group in manager.repoGroups.where((g) => g.url == repo)) {
        for (final source in group.sources) {
          if (source.sourcePlugin?.split('@').first.toLowerCase() == plugin) {
            await manager.setEnabled(source.sourceId,false);
          }
        }
      }
    }

    // Apply configured order to Auto Resolve, not just display the priority
    // number in the dashboard. Unmanaged sources retain their relative order.
    if (orderPrefs != null && preferredIds.isNotEmpty) {
      final existing = orderPrefs.get(ZKind.anime);
      await orderPrefs.set(ZKind.anime, [
        ...preferredIds.toSet(),
        ...existing.where((id) => !preferredIds.contains(id)),
      ]);
    }
    // Default is changed only when the admin selects a different default.
    if (remoteDefaultId != null &&
        remoteDefaultSource != null &&
        prefs?.get(_defaultKey) != remoteDefaultId) {
      active.setSource(remoteDefaultSource);
      await prefs?.put(_defaultKey,remoteDefaultId);
    }
    if (remoteDefaultId == null) await prefs?.delete(_defaultKey);
    await prefs?.put(_managedKey,current.toList());
  }
}
