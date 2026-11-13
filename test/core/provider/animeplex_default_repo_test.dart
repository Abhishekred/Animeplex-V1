import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/provider/cloudstream_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late CloudStreamManager manager;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('animeplex-repo');
    Hive.init(directory.path);
    await CloudStreamManager.init();
    manager = CloudStreamManager();
    await manager.loadInstalled();
  });

  tearDown(() async {
    manager.dispose();
    await Hive.deleteFromDisk();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('default repository and MovieBox catalog are ready offline', () async {
    await manager.ensureDefaultRepo();
    expect(manager.hasRepo(CloudStreamManager.defaultRepoUrl), isTrue);
    final repo = manager.repoGroups.single;
    expect(repo.name, 'Stream-1');
    final moviebox = repo.catalog.singleWhere(
      (plugin) => plugin.internalName == 'MovieBoxProvider',
    );
    expect(moviebox.version, 41);
    expect(moviebox.url, contains('/Strem1/builds/MovieBoxProvider.cs3'));

    await manager.loadInstalled();
    expect(manager.repoGroups.single.catalog.length, greaterThan(1));
  });

  test('a deliberately removed default repo is not added again', () async {
    await manager.ensureDefaultRepo();
    await manager.deleteRepo(CloudStreamManager.defaultRepoUrl);
    await manager.loadInstalled();
    await manager.ensureDefaultRepo();
    expect(manager.hasRepo(CloudStreamManager.defaultRepoUrl), isFalse);
  });
}
