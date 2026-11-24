import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import '../hive/safe_box.dart';
import '../supabase/supabase_service.dart';
import '../provider/provider_repo_registry.dart';
import '../provider/provider_registry.dart';
import '../aniyomi/aniyomi_repo.dart';
import '../aniyomi/aniyomi_extension_service.dart';
import '../provider/provider_manager.dart';
import '../mihon/mihon_repo.dart';
import '../mihon/mihon_extension_service.dart';
import '../mihon/mihon_manager.dart';
import '../lnreader/lnreader_extension_service.dart';
import '../mangayomi/mangayomi_manager.dart';
import '../stremio/stremio_manager.dart';

/// An admin-selected source, not proof that it has been installed on a device.
/// Only enabled, auto-install entries are processed by the remote sync.
@immutable
class RemoteSelectedSource {
  const RemoteSelectedSource({
    required this.kind,
    required this.repoUrl,
    required this.pluginId,
  });

  final String kind;
  final String repoUrl;
  final String pluginId;

  static const kinds = <String>{
    'zangetsu', 'mangayomi', 'aniyomi', 'mihon', 'lnreader', 'stremio',
  };

  static RemoteSelectedSource? fromJson(Map<String, dynamic> row) {
    final kind = row['kind'];
    final url = row['repo_url'];
    final id = row['plugin_id'];
    if (kind is! String || !kinds.contains(kind) ||
        url is! String || id is! String ||
        row['enabled'] != true || row['auto_install'] != true ||
        !RegExp(r'^[A-Za-z0-9_./:-]{1,220}$').hasMatch(id) ||
        !isPublicHttpsRepoUrl(url)) {
      return null;
    }
    return RemoteSelectedSource(kind: kind, repoUrl: url, pluginId: id);
  }

  static bool isPublicHttpsRepoUrl(String value) {
    if (value.length > 700) return false;
    final uri = Uri.tryParse(value);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty ||
        uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment ||
        uri.hasPort || InternetAddress.tryParse(uri.host) != null ||
        !uri.host.contains('.') || uri.host.endsWith('.local') ||
        uri.host.endsWith('.internal') || uri.host == 'localhost') {
      return false;
    }
    return true;
  }
}

/// Sync each supported extension ecosystem with the existing install APIs.
/// Runs off the boot path. A network error in one repository never prevents
/// another one from loading. No unselected extensions are downloaded.
class RemoteSelectedProviderSync {
  RemoteSelectedProviderSync._();

  static Future<void> apply({
    required SupabaseService supabase,
    required ProviderReposRegistry zangetsuRepos,
    required ProviderRegistry zangetsuRegistry,
    required AniyomiManager aniyomi,
    required MihonManager mihon,
    required LnReaderExtensionService lnreader,
    required MangayomiManager mangayomi,
    required StremioManager stremio,
  }) async {
    if (!Platform.isAndroid) return;
    final response = await supabase.client
        .from('animeplex_managed_providers')
        .select('kind,repo_url,plugin_id,enabled,auto_install')
        .eq('enabled', true)
        .eq('auto_install', true)
        .neq('kind', 'cloudstream')
        .limit(150);

    final groups = <String, List<RemoteSelectedSource>>{};
    for (final raw in response) {
      if (RemoteSelectedSource.fromJson(raw)
          case final RemoteSelectedSource selection) {
        groups.putIfAbsent(
          '${selection.kind}|\u0000${selection.repoUrl}', () => [],
        ).add(selection);
      }
    }
    for (final group in groups.values) {
      if (group.isEmpty) continue;
      final head = group.first;
      try {
        switch (head.kind) {
          case 'zangetsu':
            final repo = await zangetsuRepos.fetchAndCache(head.repoUrl);
            final installed = zangetsuRegistry.getAll();
            for (final row in group) {
              for (final source in repo.sources.where((s) => s.id == row.pluginId)) {
                if (installed.any((p) =>
                    p.originRepoUrl == head.repoUrl && p.name == source.id)) {
                  continue;
                }
                await zangetsuRegistry.install(
                  sourceId: source.id,
                  fileUrl: zangetsuRepos.resolveFileUrl(repo, source),
                  repoUrl: head.repoUrl,
                  displayName: source.name,
                  version: source.version,
                  logoUrl: ProviderReposRegistry.resolveLogoUrl(repo, source) ?? '',
                );
              }
            }
            break;
          case 'aniyomi':
            await _rememberRepo('aniyomi_repos', head.repoUrl);
            await _ensureInstalledBox(AniyomiExtensionService.installedBoxName);
            final entries = await AniyomiRepo.fetchIndex(head.repoUrl);
            final selected = group.map((p) => p.pluginId).toSet();
            for (final entry in entries.where((e) => selected.contains(e.pkg))) {
              if (Hive.box<dynamic>(
                  AniyomiExtensionService.installedBoxName).containsKey(entry.pkg)) {
                continue;
              }
              await AniyomiExtensionService().installFromRepo(
                entry, manager: aniyomi,
              );
            }
            break;
          case 'mihon':
            await _rememberRepo('mihon_repos', head.repoUrl);
            await _ensureInstalledBox(MihonExtensionService.installedBoxName);
            final entries = await MihonRepo.fetchIndex(head.repoUrl);
            final selected = group.map((p) => p.pluginId).toSet();
            for (final entry in entries.where((e) => selected.contains(e.pkg))) {
              if (Hive.box<dynamic>(
                  MihonExtensionService.installedBoxName).containsKey(entry.pkg)) {
                continue;
              }
              await MihonExtensionService().installFromRepo(
                entry, manager: mihon,
              );
            }
            break;
          case 'lnreader':
            await _rememberRepo('lnreader_repos', head.repoUrl);
            final entries = await lnreader.fetchIndex(head.repoUrl);
            final installed = lnreader.installed().map((p) => p.id).toSet();
            final selected = group.map((p) => p.pluginId).toSet();
            for (final entry in entries.where((e) =>
                selected.contains(e.id) && !installed.contains(e.id))) {
              await lnreader.install(entry);
            }
            break;
          case 'mangayomi':
            final uri = Uri.parse(head.repoUrl);
            final entries = mangayomi.repositories.contains(uri)
                ? await mangayomi.refreshRepository(uri)
                : await mangayomi.addRepository(uri);
            final selected = group.map((p) => p.pluginId).toSet();
            final installed = mangayomi.installed.map((p) => p.source.key).toSet();
            for (final source in entries) {
              // A Mangayomi extension key includes its source numeric ID.
              final parts = source.key.split(':');
              final catalogId = parts.length == 5
                  ? parts.skip(2).join(':')
                  : source.key;
              if (!selected.contains(source.key) &&
                  !selected.contains(catalogId)) continue;
              if (!installed.contains(source.key)) {
                await mangayomi.install(source);
              }
            }
            break;
          case 'stremio':
            final existing = stremio.installations.map((p) => p.manifestId).toSet();
            if (group.any((p) => !existing.contains(p.pluginId))) {
              await stremio.install(head.repoUrl);
            }
            break;
        }
      } catch (error) {
        debugPrint('[admin-provider-sync] ${head.kind} repo failed: $error');
      }
    }
  }

  static Future<void> _ensureInstalledBox(String name) async {
    if (!Hive.isBoxOpen(name)) await openBoxSafely<dynamic>(name);
  }

  static Future<void> _rememberRepo(String boxName, String url) async {
    if (!Hive.isBoxOpen(boxName)) await openBoxSafely<String>(boxName);
    final box = Hive.box<String>(boxName);
    if (!box.values.contains(url)) await box.add(url);
  }
}
