import 'dart:async';

import '../engine/health_sync_engine.dart';
import '../mapping/type_catalog.dart';
import '../types.dart';
import '../state/sync_state_store.dart';
import 'activity_bridge.dart';
import 'activity_ingest.dart';
import 'activity_state.dart';
import 'local_day.dart';

/// Look-back when nothing else is asked (first connection).
const defaultActivityLookbackDays = 365;

/// Upper limit of the look-back (5 years); the server rejects older days.
const maxActivityLookbackDays = 1825;

/// A daily sum for display or upload.
class ActivityDayTotal {
  const ActivityDayTotal({required this.day, required this.value, required this.complete});
  final LocalDay day;
  final double value;

  /// `false` for today: the day is not over, so the sum is partial and must
  /// not count as a full day in an average.
  final bool complete;
}

/// Removes floating point noise of apportioned sums (6 decimals are plenty for
/// steps, meters, kilocalories and minutes).
double _roundDaily(double v) => double.parse(v.toStringAsFixed(6));

void _checkLookback(int days) {
  if (days < 1 || days > maxActivityLookbackDays) {
    throw ArgumentError.value(days, 'lookbackDays', 'must be 1..$maxActivityLookbackDays');
  }
}

void _checkActivityType(String platformType) {
  if (!activityPlatformTypes.contains(platformType)) {
    throw ArgumentError.value(platformType, 'platformType', 'not a daily total type');
  }
}

/// Reads daily totals for a period. Stateless: nothing is stored, nothing
/// uploaded. Days without data are missing in the result (never 0).
class ActivityDailyReader {
  ActivityDailyReader({
    required this.bridge,
    this.calendar = const DeviceDayCalendar(),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final ActivityDailyBridge bridge;
  final DayCalendar calendar;
  final DateTime Function() _clock;

  /// The last [lookbackDays] days including today (default 365, at most 1825),
  /// or the explicit period [from]..[to] (both inclusive; then [lookbackDays]
  /// is ignored; the period must not be longer than 1825 days).
  Future<List<ActivityDayTotal>> readDailyTotals(
    String platformType, {
    int lookbackDays = defaultActivityLookbackDays,
    LocalDay? from,
    LocalDay? to,
  }) async {
    _checkActivityType(platformType);
    final today = calendar.dayOf(_clock());
    final end = to ?? today;
    final LocalDay start;
    if (from != null) {
      start = from;
    } else {
      _checkLookback(lookbackDays);
      start = end.addDays(-(lookbackDays - 1));
    }
    if (start.isAfter(end)) throw ArgumentError('from is after to: $start > $end');
    if (start.daysUntil(end) + 1 > maxActivityLookbackDays) {
      throw ArgumentError('period longer than $maxActivityLookbackDays days');
    }
    final page = await bridge.dailyTotals(platformType, from: start, to: end);
    final days = [
      for (final d in page.days)
        if (!d.day.isBefore(start) && !d.day.isAfter(end) && d.value.isFinite && d.value >= 0)
          ActivityDayTotal(day: d.day, value: _roundDaily(d.value), complete: d.day.isBefore(today))
    ]..sort((a, b) => a.day.compareTo(b.day));
    return days;
  }
}

/// Settings of [ActivityDailySync].
class ActivityDailyConfig {
  const ActivityDailyConfig({
    this.sourcePackage = defaultActivitySourcePackage,
    this.sourceName = 'Apple Health',
    this.defaultLookbackDays = defaultActivityLookbackDays,
    this.indexDays = 7,
    this.refsPageLimit = 5000,
    this.batchSize = 2000,
    this.batchSpanDays = 45,
    this.lockTimeout = const Duration(minutes: 10),
  });

  /// **Fixed** name of the merged HealthKit sum, sent as `source_package`.
  /// Never change it for an existing profile: a new name is a new source for
  /// the server (second row per day, one of them held back). Must not be one
  /// of the app's own packages (the server drops those as echo).
  final String sourcePackage;

  /// Display name of the source.
  final String sourceName;
  final int defaultLookbackDays;

  /// How many recent days the UUID -> day index covers (default 7: late samples
  /// of a watch arrive within days; the index is health data and kept small).
  /// Deletions of older or unknown samples trigger a read of the whole look-back
  /// and a comparison with the sent values (never a delete): one statistics
  /// query, an upload only for days that really changed.
  final int indexDays;
  final int refsPageLimit;

  /// Batch limits (server: 2000 per call; period limited, see
  /// [buildActivityBatches]).
  final int batchSize;
  final int batchSpanDays;
  final Duration lockTimeout;
}

/// Default of [ActivityDailyConfig.sourcePackage].
const defaultActivitySourcePackage = 'healthkit.statistics.merged';

/// What a run found for one type, before anything is uploaded or stored.
class ActivityTypePlan {
  ActivityTypePlan._({
    required this.scope,
    required this.platformType,
    required this.entry,
    required this.windowFrom,
    required this.windowTo,
    required this.lookbackDays,
    required this.fullWindow,
    required this.upload,
    required this.emptied,
    required this.nextAnchor,
    required this.timeZoneId,
    required this.indexAdd,
    required this.indexRemove,
    required this.unknownDeletions,
  });

  final SyncScope scope;
  final String platformType;
  final TypeMappingEntry entry;
  final LocalDay windowFrom;
  final LocalDay windowTo;
  final int lookbackDays;

  /// The whole look-back was read (first run, unknown deletion, zone change,
  /// forced), otherwise only the touched days.
  final bool fullWindow;

  /// Days with a new or changed sum, ascending.
  final List<DailyTotal> upload;

  /// Days the server holds a sum for but that have no data any more (all
  /// samples deleted). **Reported only**: nothing is sent for them, there is
  /// no automatic delete and no 0. The app decides (explicit user wish).
  final List<LocalDay> emptied;
  final String? nextAnchor;
  final String? timeZoneId;
  final Map<String, Set<LocalDay>> indexAdd;
  final Set<String> indexRemove;

  /// Number of deleted UUIDs the index did not know.
  final int unknownDeletions;
}

/// Progress of a run, reported after every accepted batch (and once before the
/// first one of a type). Numbers only, no values.
class ActivityProgress {
  const ActivityProgress({
    required this.platformType,
    required this.typeIndex,
    required this.typeCount,
    required this.batchesDone,
    required this.batchesTotal,
    required this.daysDone,
    required this.daysTotal,
  });
  final String platformType;

  /// 0-based position of the type in this run and the number of types.
  final int typeIndex;
  final int typeCount;

  /// Batches of this type: accepted so far / to send in this run.
  final int batchesDone;
  final int batchesTotal;

  /// Days of this type: accepted so far / to send in this run.
  final int daysDone;
  final int daysTotal;
}

typedef ActivityProgressCallback = void Function(ActivityProgress progress);

/// Why a type failed (see [ActivitySyncResult.failureReasons]).
class ActivityFailure {
  /// The server turned elements down (inactive mapping, type switched off for
  /// the connection, consent missing, wrong unit, ...). Nothing of the batch
  /// was stored; neither the batch nor the anchor was committed.
  static const rejected = 'rejected';

  /// The server dropped elements as echo of the app's own packages.
  static const echo = 'echo';

  /// The server's counters do not add up to the batch (answer not trusted).
  static const answerMismatch = 'answer_mismatch';

  /// The type has no server id in the catalog.
  static const noVitalTypeId = 'no_vital_type_id';

  /// Network, server error, bridge error.
  static const error = 'error';
}

class ActivitySyncResult {
  ActivitySyncResult(this.outcome,
      {Map<String, int>? counters, List<String>? failedTypes, Map<String, String>? failureReasons})
      : counters = counters ?? {},
        failedTypes = failedTypes ?? [],
        failureReasons = failureReasons ?? {};
  final SyncOutcome outcome;

  /// Counters (no values).
  final Map<String, int> counters;
  final List<String> failedTypes;

  /// Per failed type: one of the [ActivityFailure] constants.
  final Map<String, String> failureReasons;

  /// `shouldStop` ended the run early. Batches the server had accepted are kept
  /// (their values are stored as sent), the anchors of unfinished types are not
  /// advanced; the next run goes on with the rest. [outcome] is `partial`
  /// unless a type failed.
  bool stopped = false;

  /// Types that did not finish because of [stopped].
  final List<String> incompleteTypes = [];

  /// Per platform type: days that have no data any more but were sent before.
  final Map<String, List<LocalDay>> emptiedDays = {};

  /// The server reported a different day time zone: the whole look-back was
  /// sent again.
  bool timezoneChanged = false;
  String? timezoneId;

  int operator [](String key) => counters[key] ?? 0;
}

/// Daily totals of the cumulative activity types for the app's backend.
///
/// One run per type: (1) find the touched days (anchored reference query;
/// first run: the whole look-back), (2) read the totals of exactly those days
/// (`HKStatisticsCollectionQuery`, local day boundaries), (3) compare with the
/// last accepted value, (4) upload changed days in batches, (5) store the
/// anchor only after every batch of the type succeeded.
///
/// Rules:
/// * One merged sum per type and day under one fixed `source_package`
///   (HealthKit already removes iPhone/Watch overlap).
/// * A day without data is never uploaded as 0 and never deleted: an empty
///   read changes nothing on the server. Days that lost all data are only
///   reported ([ActivitySyncResult.emptiedDays]).
/// * Deletions of samples recompute the affected days (UUID -> day index);
///   an unknown UUID triggers a recompute of the whole look-back.
/// * A late sample (old start, new insertion) recomputes its old day.
/// * No `external_version`.
class ActivityDailySync {
  ActivityDailySync({
    required this.bridge,
    required this.catalog,
    required this.state,
    required this.uploader,
    required this.session,
    this.config = const ActivityDailyConfig(),
    this.calendar = const DeviceDayCalendar(),
    DateTime Function()? clock,
  })  : _clock = clock ?? DateTime.now,
        store = ActivityDailyState(state);

  final ActivityDailyBridge bridge;
  final TypeCatalog catalog;
  final SyncStateStore state;
  final ActivityDailyUploader uploader;
  final SessionProvider session;
  final ActivityDailyConfig config;
  final DayCalendar calendar;
  final ActivityDailyState store;
  final DateTime Function() _clock;

  bool _sessionMatches(HealthLink link) =>
      session.currentUserId == link.userId && session.currentProfileId == link.profileId;

  TypeMappingEntry? _entry(HealthPlatform platform, String platformType) {
    for (final e in catalog.dailySumEntries(platform)) {
      if (e.platformType == platformType) return e;
    }
    return null;
  }

  /// Consent revoked / connection removed / type switched off: forget the local
  /// anchors, sent values and the UUID index (all types, or only [types]).
  /// Nothing is deleted on the server.
  Future<void> forget(SyncScope scope, {Iterable<String>? types}) async {
    if (types == null) {
      await store.clearAll(scope);
    } else {
      for (final t in types) {
        await store.clearType(scope, t);
      }
    }
  }

  /// Stores the zone the server reported. Returns `true` if it differs from
  /// the stored one: the caller has to send the whole look-back again
  /// ([syncNow] does this itself).
  Future<bool> noteServerTimeZone(SyncScope scope, String? timezoneId) async {
    if (timezoneId == null || timezoneId.isEmpty) return false;
    final old = await store.serverTimeZone(scope);
    if (old != timezoneId) await store.saveServerTimeZone(scope, timezoneId);
    return old != null && old != timezoneId;
  }

  /// Finds the days to send for one type. Reads only; stores nothing until
  /// [commit]. [resendAll] ignores the last accepted values (zone change).
  Future<ActivityTypePlan> collect(
    SyncScope scope,
    String platformType, {
    int? lookbackDays,
    bool forceFull = false,
    bool resendAll = false,
  }) async {
    _checkActivityType(platformType);
    final entry = _entry(scope.platform, platformType);
    if (entry == null) throw ArgumentError.value(platformType, 'platformType', 'no daily total entry in the catalog');
    final lb = lookbackDays ?? config.defaultLookbackDays;
    _checkLookback(lb);
    final cap = entry.backfillCapDays ?? maxActivityLookbackDays;
    if (lb > cap) throw ArgumentError.value(lb, 'lookbackDays', 'above the cap of $cap days');

    final today = calendar.dayOf(_clock());
    final windowFrom = today.addDays(-(lb - 1));
    final indexFrom = today.addDays(-(config.indexDays - 1));
    final rec = await store.anchor(scope, platformType);
    final sent = resendAll ? <LocalDay, double>{} : await store.sent(scope, platformType);

    var fullWindow = forceFull || rec == null || rec.anchor == null || lb > rec.lookbackDays;
    final touched = <LocalDay>{};
    final indexAdd = <String, Set<LocalDay>>{};
    final deleted = <String>{};
    String? anchor = rec?.anchor;
    final baseline = anchor == null;

    // (1) references since the anchor (baseline: the index window only)
    var pages = 0;
    while (true) {
      final page = await bridge.sampleRefs(
        platformType,
        anchor: anchor,
        from: baseline ? calendar.startOf(indexFrom) : null,
        limit: config.refsPageLimit,
      );
      for (final r in page.refs) {
        final days = _daysOfRef(r);
        if (days.isEmpty) continue;
        if (!baseline) touched.addAll(days);
        if (!days.last.isBefore(indexFrom)) indexAdd[r.uuid] = days.toSet();
      }
      deleted.addAll(page.deletedUuids);
      final next = page.nextAnchor;
      final more = page.hasMore && next != null && next != anchor;
      anchor = next ?? anchor;
      if (!more || ++pages > 10000) break;
    }

    // deletions -> days (index); unknown UUID -> whole look-back
    var unknown = 0;
    if (deleted.isNotEmpty) {
      final known = await store.lookup(scope, platformType, deleted);
      for (final u in deleted) {
        final d = known[u] ?? indexAdd[u];
        if (d != null) {
          touched.addAll(d);
        } else {
          unknown++;
        }
      }
      if (unknown > 0) fullWindow = true;
    }

    // (2) totals of the touched days (or the whole look-back)
    DailyTotalsPage? totals;
    var considered = <LocalDay>{};
    if (fullWindow) {
      totals = await bridge.dailyTotals(platformType, from: windowFrom, to: today);
    } else {
      considered = {
        for (final d in touched)
          if (!d.isBefore(windowFrom) && !d.isAfter(today)) d
      };
      if (considered.isNotEmpty) {
        final sorted = considered.toList()..sort();
        totals = await bridge.dailyTotals(platformType, from: sorted.first, to: sorted.last);
        final tz = totals.timeZoneId;
        if (rec?.timeZoneId != null && tz != null && tz != rec!.timeZoneId) {
          // the device zone changed: all day boundaries moved
          fullWindow = true;
          totals = await bridge.dailyTotals(platformType, from: windowFrom, to: today);
        }
      }
    }

    // (3) compare with the last accepted values
    final byDay = <LocalDay, double>{
      if (totals != null)
        for (final t in totals.days)
          if (!t.day.isBefore(windowFrom) && !t.day.isAfter(today) && t.value.isFinite && t.value >= 0)
            t.day: _roundDaily(t.value)
    };
    final candidates = fullWindow ? {...byDay.keys, ...sent.keys.where((d) => !d.isBefore(windowFrom))} : considered;
    final upload = <DailyTotal>[];
    final emptied = <LocalDay>[];
    for (final d in candidates.toList()..sort()) {
      final v = byDay[d];
      if (v != null) {
        final old = sent[d];
        if (old == null || (old - v).abs() > 1e-6) upload.add(DailyTotal(day: d, value: v));
      } else if (sent.containsKey(d)) {
        emptied.add(d); // reported only
      }
    }

    return ActivityTypePlan._(
      scope: scope,
      platformType: platformType,
      entry: entry,
      windowFrom: windowFrom,
      windowTo: today,
      lookbackDays: lb,
      fullWindow: fullWindow,
      upload: upload,
      emptied: emptied,
      nextAnchor: anchor,
      timeZoneId: totals?.timeZoneId ?? rec?.timeZoneId,
      indexAdd: indexAdd,
      indexRemove: deleted,
      unknownDeletions: unknown,
    );
  }

  /// Stores anchor, accepted values and index after the **whole** plan was
  /// uploaded (not before).
  Future<void> commit(ActivityTypePlan plan) async {
    final scope = plan.scope;
    final type = plan.platformType;
    final sent = await store.sent(scope, type);
    for (final d in plan.upload) {
      sent[d.day] = d.value;
    }
    sent.removeWhere((d, _) => d.isBefore(plan.windowFrom));
    await store.saveSent(scope, type, sent);
    await store.updateIndex(scope, type,
        add: plan.indexAdd,
        remove: plan.indexRemove,
        keepFrom: plan.windowTo.addDays(-(config.indexDays - 1)));
    final old = await store.anchor(scope, type);
    await store.saveAnchor(
        scope,
        type,
        ActivityAnchor(
          anchor: plan.nextAnchor ?? old?.anchor,
          timeZoneId: plan.timeZoneId ?? old?.timeZoneId,
          lookbackDays: plan.fullWindow || old == null ? plan.lookbackDays : old.lookbackDays,
        ));
  }

  /// Elements for the upload of a plan (types without a server id are skipped).
  List<ActivityIngestElement> elementsOf(ActivityTypePlan plan) {
    final id = plan.entry.vitalTypeId;
    if (id == null) return const [];
    return [
      for (final d in plan.upload)
        ActivityIngestElement(
          vitalTypeId: id,
          platformType: plan.platformType,
          vitalKey: plan.entry.vitalKey,
          day: d.day,
          valueNumeric: plan.entry.toCanonical(d.value),
          sourcePackage: config.sourcePackage,
          unit: plan.entry.unitCanonical,
          sourceName: config.sourceName,
          mapVersion: plan.entry.mapVersion,
        )
    ];
  }

  /// One run over [types] (HealthKit platform types, e.g. `stepCount`).
  /// Anchors only advance after the whole type was accepted by the server.
  ///
  /// * A batch the server turned down (`rejected` > 0, echo, counters that do
  ///   not add up) is **not** stored as sent: the type fails (see
  ///   [ActivitySyncResult.failureReasons]) and the next run sends the days again
  ///   (review A1).
  /// * Every accepted batch is stored as sent at once, so that a failure or an
  ///   abort in batch n of 41 loses only the rest (review A2).
  /// * [onProgress] is called before the first batch of a type and after every
  ///   accepted batch; [shouldStop] is asked before every batch and type
  ///   (watchdog or "Cancel" of the app); `true` ends the run cleanly.
  Future<ActivitySyncResult> syncNow(
    HealthLink link, {
    required Set<String> types,
    int? lookbackDays,
    bool forceFull = false,
    ActivityProgressCallback? onProgress,
    bool Function()? shouldStop,
  }) async {
    if (link.platform != bridge.platform) {
      throw ArgumentError('Connection ${link.platform.id} does not match bridge ${bridge.platform.id}');
    }
    if (lookbackDays != null) _checkLookback(lookbackDays);
    for (final t in types) {
      _checkActivityType(t);
    }
    if (!_sessionMatches(link)) return ActivitySyncResult(SyncOutcome.sessionMismatch);
    final scope = link.scope;
    if (!await state.acquireRunLock(scope, _clock(), timeout: config.lockTimeout)) {
      return ActivitySyncResult(SyncOutcome.locked);
    }
    final result = ActivitySyncResult(SyncOutcome.success);
    final failed = <String>[];
    final ctl = _RunControl(types.length, onProgress, shouldStop);
    try {
      try {
        // state of an earlier version (SharedPreferences) moves to the state store
        final moved = await store.migrateLegacy(scope);
        _add(result, 'migrated_keys', moved);
      } catch (_) {
        _add(result, 'migration_failed', 1);
      }
      // A zone change seen in an earlier run whose resend did not finish: send the whole look-back again now.
      final pendingBefore = await store.pendingTimeZone(scope);
      if (pendingBefore != null) {
        result.timezoneChanged = true;
        result.counters['timezone_resend'] = 1;
        await store.clearAnchorsAndSent(scope, types);
      }
      final tzChanged = await _runTypes(link, types, result, failed, ctl,
          lookbackDays: lookbackDays, forceFull: forceFull || pendingBefore != null, resendAll: pendingBefore != null);
      var resendDone = pendingBefore != null;
      if (pendingBefore == null && tzChanged && failed.isEmpty && !result.stopped) {
        // The server cut the days in another zone: send the whole look-back again.
        result.timezoneChanged = true;
        result.counters['timezone_resend'] = 1;
        await store.clearAnchorsAndSent(scope, types);
        await _runTypes(link, types, result, failed, ctl,
            lookbackDays: lookbackDays, forceFull: true, resendAll: true);
        resendDone = true;
      }
      // The new zone counts only after the resend went through. Until then the open resend is kept, so that an
      // abort or an error in between does not lose it.
      final tz = result.timezoneId ?? pendingBefore;
      if (resendDone && failed.isEmpty && !result.stopped) {
        if (tz != null) await store.saveServerTimeZone(scope, tz);
        await store.clearPendingTimeZone(scope);
      }
    } finally {
      await state.releaseRunLock(scope);
    }
    final outcome = failed.isEmpty
        ? (result.stopped ? SyncOutcome.partial : SyncOutcome.success)
        : (failed.length >= types.length ? SyncOutcome.error : SyncOutcome.partial);
    return ActivitySyncResult(outcome,
        counters: result.counters, failedTypes: failed, failureReasons: result.failureReasons)
      ..emptiedDays.addAll(result.emptiedDays)
      ..timezoneChanged = result.timezoneChanged
      ..timezoneId = result.timezoneId
      ..stopped = result.stopped
      ..incompleteTypes.addAll(result.incompleteTypes);
  }

  /// Zone of the server's answer against the stored one. Stores the very first
  /// value; a **different** one is only noted as an open resend (see [syncNow]),
  /// the stored zone changes when the resend is done.
  Future<bool> _zoneDiffers(SyncScope scope, String? tz) async {
    if (tz == null || tz.isEmpty) return false;
    final old = await store.serverTimeZone(scope);
    if (old == null) {
      await store.saveServerTimeZone(scope, tz);
      return false;
    }
    if (old == tz) return false;
    if (await store.pendingTimeZone(scope) == null) await store.savePendingTimeZone(scope, tz);
    return true;
  }

  /// `null` = the answer says the batch was taken; otherwise an [ActivityFailure].
  String? _batchProblem(ActivityIngestResult r, int sent) {
    if (r.rejected > 0) return ActivityFailure.rejected;
    if (r.echo > 0) return ActivityFailure.echo;
    final accounted = r.inserted + r.updated + r.deleted + r.duplicates + r.skippedDeleted;
    if (accounted < sent) return ActivityFailure.answerMismatch;
    return null;
  }

  /// Returns `true` if the server reported another zone than the stored one.
  Future<bool> _runTypes(
    HealthLink link,
    Set<String> types,
    ActivitySyncResult result,
    List<String> failed,
    _RunControl ctl, {
    int? lookbackDays,
    required bool forceFull,
    required bool resendAll,
  }) async {
    var tzChanged = false;
    final scope = link.scope;
    for (final (ti, type) in types.indexed) {
      if (failed.contains(type)) continue;
      if (result.stopped || ctl.stop()) {
        result.stopped = true;
        result.incompleteTypes.add(type);
        continue;
      }
      try {
        if (_entry(link.platform, type)?.vitalTypeId == null) {
          _add(result, 'no_vital_type_id', 1);
          result.failureReasons[type] = ActivityFailure.noVitalTypeId;
          failed.add(type);
          continue;
        }
        final plan = await collect(scope, type,
            lookbackDays: lookbackDays, forceFull: forceFull, resendAll: resendAll);
        final elements = elementsOf(plan);
        final planValue = {for (final u in plan.upload) u.day: u.value}; // platform unit, as `sent` keeps it
        final batches = buildActivityBatches(elements, maxSize: config.batchSize, maxSpanDays: config.batchSpanDays);
        var batchesDone = 0, daysDone = 0;
        void report() => ctl.progress?.call(ActivityProgress(
            platformType: type,
            typeIndex: ti,
            typeCount: ctl.typeCount,
            batchesDone: batchesDone,
            batchesTotal: batches.length,
            daysDone: daysDone,
            daysTotal: elements.length));
        report();
        var stoppedHere = false;
        for (final batch in batches) {
          if (ctl.stop()) {
            stoppedHere = true;
            break;
          }
          final r = await uploader.ingestDaily(link.linkId, batch);
          _add(result, 'days_sent', batch.length);
          _add(result, 'inserted', r.inserted);
          _add(result, 'updated', r.updated);
          _add(result, 'duplicates', r.duplicates);
          _add(result, 'rejected', r.rejected);
          _add(result, 'echo', r.echo);
          _add(result, 'skipped_deleted', r.skippedDeleted);
          _add(result, 'unknown_fields', r.unknownFields);
          if (r.timezoneId != null) {
            result.timezoneId = r.timezoneId;
            if (await _zoneDiffers(scope, r.timezoneId)) tzChanged = true;
          }
          final problem = _batchProblem(r, batch.length);
          if (problem != null) {
            // Not taken by the server: nothing is stored as sent, the anchor stays.
            result.failureReasons[type] = problem;
            failed.add(type);
            break;
          }
          // taken: remember it now, a later failure or abort must not send it again
          await store.addSent(
              scope,
              type,
              {for (final e in batch) e.day: planValue[e.day]!},
              keepFrom: plan.windowFrom);
          await state.renewRunLock(scope, _clock());
          batchesDone++;
          daysDone += batch.length;
          report();
        }
        if (failed.contains(type)) continue;
        if (stoppedHere) {
          result.stopped = true;
          result.incompleteTypes.add(type);
          continue;
        }
        await commit(plan);
        if (plan.emptied.isNotEmpty) result.emptiedDays[type] = plan.emptied;
        _add(result, 'emptied_days', plan.emptied.length);
        _add(result, 'unknown_deletions', plan.unknownDeletions);
        if (plan.fullWindow) _add(result, 'full_window_reads', 1);
      } catch (_) {
        result.failureReasons.putIfAbsent(type, () => ActivityFailure.error);
        if (!failed.contains(type)) failed.add(type);
      }
    }
    return tzChanged;
  }

  void _add(ActivitySyncResult r, String k, int n) {
    if (n == 0) return;
    r.counters[k] = (r.counters[k] ?? 0) + n;
  }

  /// Days a sample touches: from the day of its start to the day of its last
  /// instant (the end is exclusive).
  List<LocalDay> _daysOfRef(ActivitySampleRef r) {
    final first = calendar.dayOf(r.start);
    final lastInstant = r.end.isAfter(r.start) ? r.end.subtract(const Duration(milliseconds: 1)) : r.start;
    var last = calendar.dayOf(lastInstant);
    if (last.isBefore(first)) last = first;
    if (first.daysUntil(last) > 366) last = first.addDays(366);
    return [...daysInRange(first, last)];
  }
}

/// Callbacks of one run.
class _RunControl {
  _RunControl(this.typeCount, this.progress, this._shouldStop);
  final int typeCount;
  final ActivityProgressCallback? progress;
  final bool Function()? _shouldStop;
  bool stop() => _shouldStop?.call() ?? false;
}
