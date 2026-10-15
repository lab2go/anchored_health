import 'package:flutter_test/flutter_test.dart';
import 'package:anchored_health_engine/anchored_health_engine.dart';
import 'support/fakes.dart';

void main() {
  test('counter observer reports completed windows after upload and exact read count', () async {
    final h = EngineHarness();
    final now = h.clockNow;
    h.bridge.addAll([for (var d=1;d<=14;d++) sample(id:'g$d',at:now.subtract(Duration(days:d)),unit:'kg')]);
    final events=<BackfillProgress>[];
    final rows=<int>[];
    final r=await h.engine.extendBackfill(h.link,'bodyMass',from:now.subtract(const Duration(days:14)),to:now,
      onProgress:(p){ events.add(p); rows.add(h.uploader.rows.length); });
    expect(r.outcome,SyncOutcome.success);
    expect(events.map((p)=>p.windowsDone),[0,1,2]);
    expect(events.map((p)=>p.totalWindows),[2,2,2]);
    expect(events.map((p)=>p.valuesRead),[0,7,14]);
    expect(rows,[0,7,14]);
    expect(events.every((p)=>p.type=='bodyMass'),isTrue);
    expect(await h.state.backfillCursor(h.link.scope,'bodyMass'),isNull);
    expect(await h.state.token(h.link.scope,'bodyMass'),isNull);
  });
  test('observer exceptions cannot turn successful uploads into partial runs', () async {
    final h=EngineHarness(); final now=h.clockNow;
    h.bridge.add(sample(id:'one',at:now.subtract(const Duration(days:1)),unit:'kg'));
    final r=await h.engine.extendBackfill(h.link,'bodyMass',from:now.subtract(const Duration(days:7)),to:now,
      onProgress:(_)=>throw StateError('synthetic observer failure'));
    expect(r.outcome,SyncOutcome.success); expect(h.uploader.rows,hasLength(1));
    expect(await h.state.backfillCursor(h.link.scope,'bodyMass'),isNull);
    expect(await h.state.acquireRunLock(h.link.scope,now),isTrue);
  });
  test('resumed counters distinguish old windows from this invocation values', () async {
    final h=EngineHarness();final now=h.clockNow;
    final cursor=BackfillCursor.split(now.subtract(const Duration(days:14)),now,maxWindow:const Duration(days:7)).advance();
    await h.state.saveBackfillCursor(h.link.scope,'bodyMass',cursor);
    h.bridge.add(sample(id:'old',at:now.subtract(const Duration(days:10)),unit:'kg'));
    final events=<BackfillProgress>[];
    await h.engine.extendBackfill(h.link,'bodyMass',from:now.subtract(const Duration(days:14)),to:now,onProgress:events.add);
    expect(events.map((p)=>p.windowsDone),[1,2]);
    expect(events.map((p)=>p.valuesRead),[0,1]);
  });
  test('default API without observer remains compatible; no event on invalid session', () async {
    final h=EngineHarness(session:const FixedSession('other','profile-a'));final events=<BackfillProgress>[];
    final r=await h.engine.extendBackfill(h.link,'bodyMass',from:h.clockNow.subtract(const Duration(days:7)),to:h.clockNow,onProgress:events.add);
    expect(r.outcome,SyncOutcome.sessionMismatch);expect(events,isEmpty);
  });
}
