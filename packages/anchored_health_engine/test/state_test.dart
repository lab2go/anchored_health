import 'package:flutter_test/flutter_test.dart';
import 'package:anchored_health_engine/anchored_health_engine.dart';

void main() {
  const scopeA = SyncScope(userId: 'user-a', profileId: 'profile-a', platform: HealthPlatform.appleHealth);
  const scopeB = SyncScope(userId: 'user-b', profileId: 'profile-b', platform: HealthPlatform.appleHealth);
  final now = DateTime.utc(2026, 10, 8, 12);

  test('key layout <uid>/<pid>/<platform>/sync_token/<platform_type>', () async {
    final kv = InMemoryKeyValueStore();
    final st = SyncStateStore(kv);
    await st.saveToken(scopeA, 'bodyMass', SyncToken(value: 'QUJD', createdAt: now));
    expect(kv.data.keys, contains('user-a/profile-a/apple_health/sync_token/bodyMass'));
    final t = await st.token(scopeA, 'bodyMass');
    expect(t!.value, 'QUJD');
    expect(t.createdAt, now);
    expect(t.firstRunComplete, isTrue);
    expect(await st.token(scopeB, 'bodyMass'), isNull, reason: 'separate per user/profile');
  });

  test('token JSON carries the first-run window', () {
    final t = SyncToken(value: 'x', createdAt: now, firstRunFrom: now.subtract(const Duration(days: 14)), firstRunComplete: false);
    final back = SyncToken.fromJson(t.toJson());
    expect(back.firstRunFrom, t.firstRunFrom);
    expect(back.firstRunComplete, isFalse);
  });

  test('resetUser deletes only <uid>/..., device id stays', () async {
    final kv = InMemoryKeyValueStore();
    final st = SyncStateStore(kv);
    final device = await st.deviceId();
    await st.saveToken(scopeA, 'bodyMass', SyncToken(value: 'a', createdAt: now));
    await st.addSeriesSources(scopeA, {'com.dexcom.g7app'});
    await st.saveToken(scopeB, 'bodyMass', SyncToken(value: 'b', createdAt: now));
    expect(await st.resetUser('user-a'), 2);
    expect(await st.token(scopeA, 'bodyMass'), isNull);
    expect(await st.seriesSources(scopeA), isEmpty);
    expect(await st.token(scopeB, 'bodyMass'), isNotNull);
    expect(await st.deviceId(), device);
    expect(device, hasLength(32));
    expect(kv.data.keys, contains(SyncStateStore.defaultDeviceIdKey));
  });

  test('device id key is configurable', () async {
    final kv = InMemoryKeyValueStore();
    final st = SyncStateStore(kv, deviceIdKey: 'my_app/health_device_id');
    final id = await st.deviceId();
    expect(kv.data['my_app/health_device_id'], id);
  });

  test('run lock: second trigger rejected, can be taken over after timeout', () async {
    final st = SyncStateStore(InMemoryKeyValueStore());
    expect(await st.acquireRunLock(scopeA, now), isTrue);
    expect(await st.acquireRunLock(scopeA, now.add(const Duration(minutes: 5))), isFalse);
    expect(await st.acquireRunLock(scopeA, now.add(const Duration(minutes: 11))), isTrue);
    await st.releaseRunLock(scopeA);
    expect(await st.acquireRunLock(scopeA, now), isTrue);
  });

  test('backfill cursor: 7-day windows, newest first, resumable', () async {
    final c = BackfillCursor.split(now.subtract(const Duration(days: 20)), now);
    expect(c.windows, hasLength(3));
    expect(c.windows.first.to, now);
    expect(c.windows.last.from, now.subtract(const Duration(days: 20)));
    final st = SyncStateStore(InMemoryKeyValueStore());
    await st.saveBackfillCursor(scopeA, 'bloodGlucose', c.advance());
    final back = await st.backfillCursor(scopeA, 'bloodGlucose');
    expect(back!.done, 1);
    expect(back.windows[1].from, c.windows[1].from);
  });
}
