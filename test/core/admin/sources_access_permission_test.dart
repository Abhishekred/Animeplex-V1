import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/admin/sources_access_permission.dart';

void main() {
  test('Sources hidden by default and without verified account', () {
    expect(SourcesAccessPermission.canShow(
      currentUserId: 'a', verifiedUserId: null, granted: true), false);
    expect(SourcesAccessPermission.canShow(
      currentUserId: 'a', verifiedUserId: 'a', granted: false), false);
    expect(SourcesAccessPermission.canShow(
      currentUserId: null, verifiedUserId: null, granted: true), false);
  });
  test('Sources permission never leaks across users', () {
    expect(SourcesAccessPermission.canShow(
      currentUserId: 'b', verifiedUserId: 'a', granted: true), false);
    expect(SourcesAccessPermission.canShow(
      currentUserId: 'a', verifiedUserId: 'a', granted: true), true);
  });
}
