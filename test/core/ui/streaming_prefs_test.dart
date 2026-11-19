import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/ui/streaming_prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('streaming_prefs');
    Hive.init(dir.path);
    await StreamingPrefs.init();
    StreamingPrefs.deviceRegion = () => 'IN';
  });

  tearDown(() async {
    StreamingPrefs.resetDeviceRegionForTest();
    await Hive.close();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('region falls back to the device locale until it is set', () {
    expect(StreamingPrefs.region, 'IN');
  });

  test('a set region wins over the locale, and survives', () async {
    await StreamingPrefs.setRegion('us');
    expect(StreamingPrefs.region, 'US', reason: 'normalised to upper case');
  });

  test('a junk stored region falls back rather than reaching the API', () async {
    Hive.box(StreamingPrefs.boxName).put('region', 'not-a-country');
    expect(StreamingPrefs.region, 'IN');
  });

  test('writing bumps the revision so Home can reload', () async {
    final before = StreamingPrefs.revision.value;
    await StreamingPrefs.setRegion('GB');
    expect(StreamingPrefs.revision.value, greaterThan(before));
  });

  test('an invalid region is refused rather than stored', () async {
    await StreamingPrefs.setRegion('GB');
    await StreamingPrefs.setRegion('XYZ');
    expect(StreamingPrefs.region, 'GB');
  });

  test('admin locks region even if viewer previously picked another country', () async {
    await StreamingPrefs.setRegion('US');
    await StreamingPrefs.applyAdminRegion(
      enabled: true, regionCode: 'IN', allowCustomization: false,
    );
    expect(StreamingPrefs.region, 'IN');
    expect(StreamingPrefs.regionLocked, isTrue);
    await StreamingPrefs.setRegion('GB');
    expect(StreamingPrefs.region, 'IN', reason: 'locked viewers cannot override');
    await StreamingPrefs.applyAdminRegion(
      enabled: false, regionCode: 'IN', allowCustomization: false,
    );
    expect(StreamingPrefs.region, 'US', reason: 'original personal region preserved');
  });

  test('admin region is default when viewer has not chosen a region', () async {
    await StreamingPrefs.applyAdminRegion(
      enabled: true, regionCode: 'JP', allowCustomization: true,
    );
    expect(StreamingPrefs.region, 'JP');
    expect(StreamingPrefs.regionLocked, isFalse);
    await StreamingPrefs.setRegion('KR');
    expect(StreamingPrefs.region, 'KR');
  });

  test('admin region change emits revision when effective country changes', () async {
    final before = StreamingPrefs.revision.value;
    await StreamingPrefs.applyAdminRegion(
      enabled: true, regionCode: 'CA', allowCustomization: false,
    );
    expect(StreamingPrefs.region, 'CA');
    expect(StreamingPrefs.revision.value, greaterThan(before));
  });

  test('reads before init() do not throw', () async {
    await Hive.close();
    expect(StreamingPrefs.region, 'IN');
  });

  test('every shipped region code is one the store will accept', () async {
    for (final code in kStreamingRegions) {
      await StreamingPrefs.setRegion(code);
      expect(StreamingPrefs.region, code, reason: '$code was rejected');
    }
  });
}
