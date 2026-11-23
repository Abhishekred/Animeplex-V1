import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/admin/managed_provider_sync.dart';

void main() {
  const repo =
      'https://raw.githubusercontent.com/Abhishekred/Stream-1/test/repo.json';

  Map<String, dynamic> input({
    String url = repo,
    String plugin = 'MovieBoxProvider',
    bool enabled = true,
    bool autoInstall = true,
    bool isDefault = false,
    int priority = 50,
  }) => {
    'id': '00000000-0000-4000-8000-000000000001',
    'repo_url': url,
    'plugin_id': plugin,
    'enabled': enabled,
    'auto_install': autoInstall,
    'is_default': isDefault,
    'priority': priority,
  };

  test('accepts trusted repo entries and preserves install flags', () {
    final provider = ManagedProviderDefinition.fromJson(
      input(isDefault:true,priority:5));
    expect(provider, isNotNull);
    expect(provider!.repoUrl, repo);
    expect(provider.pluginId, 'MovieBoxProvider');
    expect(provider.autoInstall, isTrue);
    expect(provider.isDefault, isTrue);
    expect(provider.priority, 5);
  });

  test('enables multiple distinct repo plugins without key collisions', () {
    final a = ManagedProviderDefinition.fromJson(input());
    final b = ManagedProviderDefinition.fromJson(input(plugin:'SecondProvider'));
    expect(a, isNotNull);
    expect(b, isNotNull);
    expect(a!.key, isNot(b!.key));
  });

  test('rejects disabled providers and untrusted hosts', () {
    expect(ManagedProviderDefinition.fromJson(input(enabled:false)),isNull);
    for (final bad in [
      'https://evil.example/repo.json',
      'http://raw.githubusercontent.com/u/r/main/repo.json',
      'https://raw.githubusercontent.com/u/r/main/repo.json?q=1',
      'https://raw.githubusercontent.com/u/r/main/../repo.json',
    ]) {
      expect(ManagedProviderDefinition.isAllowedRepoUrl(bad),isFalse);
    }
  });

  test('rejects invalid plugin identifiers', () {
    expect(ManagedProviderDefinition.fromJson(
      input(plugin:'../../malicious')), isNull);
  });
}
