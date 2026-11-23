import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/profiles/profile_picker_artwork.dart';
import 'package:watch_app/core/app_config.dart';

void main() {
  late Directory directory;
  late Box box;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('profile_picker_art');
    Hive.init(directory.path);
    box = await Hive.openBox('profile_picker_art');
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('rotates through at most three safe image names on our R2 host', () async {
    final artwork = ProfilePickerArtwork(
      box: box,
      fetchManifest: () async => {
        'images': [
          'one.webp',
          '../outside.webp',
          'script.svg',
          'two.jpg',
          'three.png',
          'four.webp',
        ],
      },
    );
    final first = await artwork.next();
    final second = await artwork.next();
    final third = await artwork.next();
    final wrapped = await artwork.next();

    final prefix = kProfilePickerArtworkManifestUrl.replaceFirst('manifest.json', '');
    expect(first, startsWith(prefix));
    expect(first, endsWith('/profile-picker/one.webp'));
    expect(second, endsWith('/profile-picker/two.jpg'));
    expect(third, endsWith('/profile-picker/three.png'));
    expect(wrapped, first);
    expect(artwork.cachedUrl, first);
  });

  test('fetches the manifest once while rotating', () async {
    var fetches = 0;
    final artwork = ProfilePickerArtwork(
      box: box,
      fetchManifest: () async {
        fetches++;
        return {'images': ['one.webp','two.webp','three.webp']};
      },
    );
    for (var i = 0; i < 4; i++) {
      await artwork.next();
    }
    expect(fetches, 1);
  });

  test('retains a current-host cached backdrop when offline', () async {
    const cachedUrl =
        'https://pub-31b012ff212e4f15934133826c1d9570.r2.dev/profile-picker/cached.webp';
    await box.put(ProfilePickerArtwork.lastUrlKey, cachedUrl);
    final artwork = ProfilePickerArtwork(
      box: box,
      fetchManifest: () async => throw const SocketException('offline'),
    );
    expect(await artwork.next(), cachedUrl);
    expect(artwork.cachedUrl, cachedUrl);
  });

  test('ignores legacy R2 and unrelated cached URLs', () async {
    final artwork = ProfilePickerArtwork(
      box: box,
      fetchManifest: () async => {'images': []},
    );
    for (final url in [
      'https://pub-a8b67f6edb404cb1b7545e19bc2b5b94.r2.dev/profile-picker/old.webp',
      'https://avatars.zangetsu.online/profile-picker/old.webp',
      'https://other.example/profile-picker/old.webp',
    ]) {
      await box.put(ProfilePickerArtwork.lastUrlKey, url);
      expect(artwork.cachedUrl, isNull);
      expect(await artwork.next(), isNull);
    }
  });
}
