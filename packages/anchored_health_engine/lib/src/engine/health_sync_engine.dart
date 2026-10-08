import '../bridge/health_bridge.dart';
import '../mapping/type_catalog.dart';
import '../mapping/vital_record.dart';
import '../models.dart';
import '../state/sync_state_store.dart';
import '../sync/blood_pressure.dart';
import '../sync/dedupe.dart';
import '../sync/echo_filter.dart';
import '../sync/series.dart';
import '../types.dart';
import '../upload/health_uploader.dart';

/// A connection device <-> profile.
class HealthLink {
  const HealthLink({
    required this.linkId,
    required this.userId,
    required this.profileId,
    required this.platform,
  });
  final String linkId;
  final String userId;
  final String profileId;
  final HealthPlatform platform;

  SyncScope get scope => SyncScope(userId: userId, profileId: profileId, platform: platform);
}

/// Current app session (signed-in user and active profile).
abstract class SessionProvider {
  String? get currentUserId;
  String? get currentProfileId;
}

class FixedSession implements SessionProvider {
  const FixedSession(this.currentUserId, this.currentProfileId);
  @override
  final String? currentUserId;
  @override
  final String? currentProfileId;
}

class EngineConfig {
  const EngineConfig({
    this.ownSourcePackages = const {defaultOwnSourcePackage},
    this.syncIdentifierPrefix = defaultSyncIdentifierPrefix,
    this.chunkSize = 200,
    this.seriesChunkSize = 1000,
    this.deletionChunkSize = 2000,
    this.pageLimit = 1000,
    this.tokenMaxAge = const Duration(days: 25),
    this.rereadWindow = const Duration(days: 30),
    this.androidFirstRunWindow = const Duration(days: 30),
    this.minRunIntervalHealthConnect = const Duration(minutes: 15),
    this.runLockTimeout = const Duration(minutes: 10),
    this.seriesBackfillWindow = const Duration(days: 7),
  })  : assert(chunkSize > 0 && chunkSize <= 200),
        assert(seriesChunkSize >= 1 && seriesChunkSize <= 2000);

  /// Placeholder default for [ownSourcePackages].
  static const defaultOwnSourcePackage = 'com.example.app';

  /// The app's own bundle/package ids (echo stage 1). Apps must set their
  /// real ids (iOS bundle id, Android package name).
  final Set<String> ownSourcePackages;

  /// Prefix of the sync identifiers the app writes (echo stage 2). Must match
  /// [HealthWriteRequest.syncIdentifierPrefix].
  final String syncIdentifierPrefix;
  final int chunkSize;
  final int seriesChunkSize;
  final int deletionChunkSize;
  final int pageLimit;
  final Duration tokenMaxAge;
  final Duration rereadWindow;
  final Duration androidFirstRunWindow;
  final Duration minRunIntervalHealthConnect;
  final Duration runLockTimeout;
  final Duration seriesBackfillWindow;
}

class SyncRunResult {
  SyncRunResult(this.outcome, {Map<String, int>? counters, List<String>? failedTypes})
      : counters = counters ?? {},
        failedTypes = failedTypes ?? [];
  final SyncOutcome outcome;

  /// Counters for the run log (no values).
  final Map<String, int> counters;
  final List<String> failedTypes;
  final Set<String> detectedSources = {};
  final List<LedgerPatch> ledgerPatches = [];

  int operator [](String key) => counters[key] ?? 0;
}

/// Engine for the import direction. No export and no assessment of values:
/// only values, provenance and counters are moved.
class HealthSyncEngine {
  HealthSyncEngine({
    required this.bridge,
    required this.catalog,
    required this.state,
    required this.uploader,
    required this.ledger,
    required this.session,
    required this.config,
    SeriesPreferenceStore? preferences,
    DedupeIndex dedupeIndex = const EmptyDedupeIndex(),
    DateTime Function()? clock,
  })  : preferences = preferences ?? InMemorySeriesPreferenceStore(),
        _deduper = Deduper(index: dedupeIndex),
        _clock = clock ?? DateTime.now,
        _echo = EchoFilter(
          ownSourcePackages: config.ownSourcePackages,
          ledger: ledger,
          syncIdentifierPrefix: config.syncIdentifierPrefix,
        );

  final HealthBridge bridge;
  final TypeCatalog catalog;
  final SyncStateStore state;
  final HealthUploader uploader;
  final ExportLedger ledger;
  final SessionProvider session;
  final EngineConfig config;
  final SeriesPreferenceStore preferences;
  final Deduper _deduper;
  final EchoFilter _echo;
  final DateTime Function() _clock;
  final _mapper = const VitalMapper();
  final _classifier = const SeriesClassifier();
  final _sourceFilter = const SeriesSourceFilter();

  bool _sessionMatches(HealthLink link) =>
      session.currentUserId == link.userId && session.currentProfileId == link.profileId;

  /// One run over [types] (platform types). Anchors/tokens per type only
  /// advance after a successful upload.
  Future<SyncRunResult> syncNow(
    HealthLink link, {
    required Set<String> types,
    SyncTrigger trigger = SyncTrigger.manual,
  }) async {
    if (link.platform != bridge.platform) {
      throw ArgumentError('Connection ${link.platform.id} does not match bridge ${bridge.platform.id}');
    }
    if (!_sessionMatches(link)) return SyncRunResult(SyncOutcome.sessionMismatch);
    final scope = link.scope;
    final now = _clock();

    if (bridge.platform == HealthPlatform.healthConnect && trigger != SyncTrigger.manual) {
      final last = await state.lastRunAt(scope);
      if (last != null && now.difference(last) < config.minRunIntervalHealthConnect) {
        return SyncRunResult(SyncOutcome.throttled);
      }
    }
    if (!await state.acquireRunLock(scope, now, timeout: config.runLockTimeout)) {
      return SyncRunResult(SyncOutcome.locked);
    }

    final run = _RunCounters();
    final failed = <String>[];
    final result = SyncRunResult(SyncOutcome.success, counters: run.c, failedTypes: failed);
    try {
      for (final type in types) {
        final entries = catalog.forPlatformType(link.platform, type).where((e) => e.importSupported).toList();
        if (entries.isEmpty) {
          failed.add(type);
          run.add('unsupported_types');
          continue;
        }
        try {
          await _syncType(link, type, entries, run, result);
        } catch (_) {
          failed.add(type);
        }
      }
      await state.setLastRunAt(scope, now);
    } finally {
      await state.releaseRunLock(scope);
    }

    final outcome = failed.isEmpty
        ? SyncOutcome.success
        : (failed.length == types.length ? SyncOutcome.error : SyncOutcome.partial);
    final out = SyncRunResult(outcome, counters: run.c, failedTypes: failed)
      ..detectedSources.addAll(result.detectedSources)
      ..ledgerPatches.addAll(result.ledgerPatches);
    await _log(link, trigger, out, types.toList());
    return out;
  }

  Future<void> _log(HealthLink link, SyncTrigger trigger, SyncRunResult r, List<String> types) async {
    try {
      await uploader.logRun(
        link.linkId,
        SyncRunLog(
          trigger: trigger,
          outcome: r.outcome,
          types: types,
          counters: Map.of(r.counters),
          errorCode: r.failedTypes.isEmpty ? null : 'types_failed',
        ),
      );
      for (final src in r.detectedSources) {
        await uploader.logRun(
          link.linkId,
          SyncRunLog(
            trigger: trigger,
            outcome: r.outcome,
            types: [src],
            counters: const {},
            event: 'source_detected',
          ),
        );
      }
    } catch (_) {
      // The run log is a convenience; an error here must not fail the run.
    }
  }

  /// Start time of the first run per type: discrete = everything (null),
  /// aggregate = cap, series only = default window.
  DateTime? _firstRunFrom(List<TypeMappingEntry> entries, DateTime now) {
    if (entries.any((e) => e.backfillClass == BackfillClass.discrete)) return null;
    final days = entries
        .map((e) => e.backfillDefaultDays ?? e.backfillCapDays)
        .whereType<int>()
        .fold<int>(0, (a, b) => a > b ? a : b);
    return days == 0 ? null : now.subtract(Duration(days: days));
  }

  DateTime? _seriesNotBefore(List<TypeMappingEntry> entries, DateTime now) {
    final s = entries.where((e) => e.backfillClass == BackfillClass.series).toList();
    if (s.isEmpty) return null;
    final days = s.first.backfillDefaultDays ?? s.first.backfillCapDays;
    return days == null ? null : now.subtract(Duration(days: days));
  }

  Future<void> _syncType(
    HealthLink link,
    String type,
    List<TypeMappingEntry> entries,
    _RunCounters run,
    SyncRunResult result,
  ) async {
    final scope = link.scope;
    final now = _clock();
    var tok = await state.token(scope, type);

    // Android: token older than tokenMaxAge => re-read window.
    if (tok != null && !bridge.firstRunIncludesHistory && now.difference(tok.createdAt) > config.tokenMaxAge) {
      await _reread(link, type, entries, run, result);
      tok = await state.token(scope, type);
    }

    DateTime? firstFrom;
    if (tok == null) {
      firstFrom = bridge.firstRunIncludesHistory
          ? _firstRunFrom(entries, now)
          : (_firstRunFrom(entries, now) ?? now.subtract(config.androidFirstRunWindow));
      if (!bridge.firstRunIncludesHistory) {
        // Android: token first (no gap), then backfill, then changes.
        final baseline = await bridge.baselineToken(type);
        if (baseline == null) throw StateError('no baseline token for $type');
        final hist = await bridge.read(type, from: firstFrom!, to: now);
        await _process(link, type, entries, hist, const [], run, result,
            seriesNotBefore: _seriesNotBefore(entries, now));
        tok = SyncToken(value: baseline, createdAt: now);
        await state.saveToken(scope, type, tok);
        firstFrom = null;
      }
    } else if (!tok.firstRunComplete) {
      firstFrom = tok.firstRunFrom;
    }

    final inFirstRun = tok == null || !tok.firstRunComplete;
    final seriesNotBefore = inFirstRun ? _seriesNotBefore(entries, now) : null;
    var current = tok;
    while (true) {
      final page = await bridge.changes(
        type,
        token: current?.value,
        from: inFirstRun ? firstFrom : null,
        limit: config.pageLimit,
      );
      if (page.tokenExpired) {
        await _reread(link, type, entries, run, result);
        return;
      }
      await _process(link, type, entries, page.samples, page.deletions, run, result,
          seriesNotBefore: seriesNotBefore);
      final next = page.nextToken;
      if (next != null) {
        current = SyncToken(
          value: next,
          createdAt: bridge.firstRunIncludesHistory ? (current?.createdAt ?? now) : now,
          firstRunFrom: inFirstRun && page.hasMore ? firstFrom : null,
          firstRunComplete: !(inFirstRun && page.hasMore),
        );
        await state.saveToken(scope, type, current);
      }
      if (!page.hasMore) break;
    }
  }

  /// Re-read window (Android): read the window again + dedupe, then a new token.
  Future<void> _reread(
    HealthLink link,
    String type,
    List<TypeMappingEntry> entries,
    _RunCounters run,
    SyncRunResult result,
  ) async {
    final scope = link.scope;
    final now = _clock();
    await state.clearToken(scope, type);
    run.add('reread');
    final baseline = await bridge.baselineToken(type);
    final samples = await bridge.read(type, from: now.subtract(config.rereadWindow), to: now);
    await _process(link, type, entries, samples, const [], run, result);
    if (baseline != null) {
      await state.saveToken(scope, type, SyncToken(value: baseline, createdAt: now));
    }
  }

  /// Loads an older window in windows <= [EngineConfig.seriesBackfillWindow],
  /// newest first, resumable via the cursor. Anchors/tokens stay untouched.
  Future<SyncRunResult> extendBackfill(
    HealthLink link,
    String type, {
    required DateTime from,
    required DateTime to,
  }) async {
    if (!_sessionMatches(link)) return SyncRunResult(SyncOutcome.sessionMismatch);
    final scope = link.scope;
    final entries = catalog.forPlatformType(link.platform, type).where((e) => e.importSupported).toList();
    if (entries.isEmpty) return SyncRunResult(SyncOutcome.error, failedTypes: [type]);
    if (!await state.acquireRunLock(scope, _clock(), timeout: config.runLockTimeout)) {
      return SyncRunResult(SyncOutcome.locked);
    }
    final run = _RunCounters();
    final result = SyncRunResult(SyncOutcome.success, counters: run.c);
    var outcome = SyncOutcome.success;
    try {
      var cursor = await state.backfillCursor(scope, type) ??
          BackfillCursor.split(from, to, maxWindow: config.seriesBackfillWindow);
      await state.saveBackfillCursor(scope, type, cursor);
      while (!cursor.isComplete) {
        final w = cursor.windows[cursor.done];
        try {
          final samples = await bridge.read(type, from: w.from, to: w.to);
          await _process(link, type, entries, samples, const [], run, result);
        } catch (_) {
          outcome = cursor.done == 0 ? SyncOutcome.error : SyncOutcome.partial;
          break;
        }
        cursor = cursor.advance();
        run.add('windows_done');
        await state.saveBackfillCursor(scope, type, cursor);
      }
      if (cursor.isComplete) await state.clearBackfillCursor(scope, type);
    } finally {
      await state.releaseRunLock(scope);
    }
    final out = SyncRunResult(outcome, counters: run.c,
        failedTypes: outcome == SyncOutcome.success ? [] : [type])
      ..detectedSources.addAll(result.detectedSources)
      ..ledgerPatches.addAll(result.ledgerPatches);
    await _log(link, SyncTrigger.backfill, out, [type]);
    return out;
  }

  /// One page: pair blood pressure -> echo filter -> series classification ->
  /// series source filter -> mapping -> dedupe -> upload -> deletions.
  /// Throws on upload errors (the anchor then stays where it was).
  Future<void> _process(
    HealthLink link,
    String type,
    List<TypeMappingEntry> entries,
    List<HealthSample> samples,
    List<HealthDeletion> deletions,
    _RunCounters run,
    SyncRunResult result, {
    DateTime? seriesNotBefore,
  }) async {
    var input = samples;
    if (entries.any((e) => e.vitalKey == VitalKey.bloodPressure)) {
      final pr = BloodPressurePairing(pairedType: type).pairBySameId(input);
      input = pr.samples;
      run.add('unpaired', pr.unpaired.length);
    }

    final echo = await _echo.apply(link.platform, input);
    run.add('echo_dropped', echo.droppedTotal);
    result.ledgerPatches.addAll(echo.ledgerPatches);

    // Series target: either the only entry is `series` (e.g. heart rate) or
    // there are single and series targets (glucose) => classification.
    final seriesEntries = entries.where((e) => e.backfillClass == BackfillClass.series).toList();
    final singleEntries = entries.where((e) => e.backfillClass != BackfillClass.series).toList();
    var single = echo.kept;
    var series = <HealthSample>[];
    TypeMappingEntry? sEntry;
    if (seriesEntries.isNotEmpty) {
      sEntry = seriesEntries.first;
      if (singleEntries.isEmpty) {
        series = single;
        single = const [];
      } else {
        final sticky = await state.seriesSources(link.scope);
        final cls = _classifier.classify(samples: echo.kept, seriesEntry: sEntry, stickySources: sticky);
        await state.addSeriesSources(link.scope, cls.newlyStickySources);
        single = cls.single;
        series = cls.series;
      }
      if (seriesNotBefore != null) {
        final before = series.length;
        series = [for (final s in series) if (!s.start.isBefore(seriesNotBefore)) s];
        run.add('skipped_outside_window', before - series.length);
      }
      // Exactly one series source per profile × type.
      final pref = await preferences.preferredSource(link.profileId, sEntry.vitalKey);
      final decision = _sourceFilter.apply(series: series, preferredSource: pref);
      if (decision.preferenceIsNew && decision.preferredSource != null) {
        await preferences.setPreferredSource(link.profileId, sEntry.vitalKey, decision.preferredSource!);
      }
      series = decision.kept;
      run.add('skipped_other_source', decision.skippedOtherSource);
      result.detectedSources.addAll(decision.detectedOtherSources);
    }

    final singleRecords = <VitalRecord>[];
    final singleEntry = singleEntries.isEmpty ? null : singleEntries.first;
    for (final s in single) {
      final m = _mapper.map(s, singleEntry);
      if (m.record != null) {
        singleRecords.add(m.record!);
      } else {
        run.add('unmapped');
      }
    }
    final seriesRecords = <VitalRecord>[];
    for (final s in series) {
      final m = _mapper.map(s, sEntry);
      if (m.record != null) {
        seriesRecords.add(m.record!);
      } else {
        run.add('unmapped');
      }
    }

    final d1 = await _deduper.dedupe(singleRecords);
    final d2 = await _deduper.dedupe(seriesRecords);
    run.add('duplicates', d1.duplicates + d2.duplicates);
    run.add('skipped_deleted', d1.skippedDeleted + d2.skippedDeleted);

    for (var i = 0; i < d1.kept.length; i += config.chunkSize) {
      final chunk = d1.kept.sublist(i, _min(i + config.chunkSize, d1.kept.length));
      final r = await uploader.importBatch(link.linkId, chunk);
      run.add('imported', r.inserted);
      run.add('updated', r.updated);
      run.add('duplicates', r.duplicates);
      run.add('skipped_deleted', r.skippedDeleted);
      run.add('unknown_fields', r.unknownFields);
    }

    final groups = <String, List<VitalRecord>>{};
    for (final r in d2.kept) {
      groups.putIfAbsent('${r.vitalTypeId}|${r.sourcePackage}', () => []).add(r);
    }
    for (final g in groups.values) {
      g.sort((a, b) => a.measuredAt.compareTo(b.measuredAt));
      for (var i = 0; i < g.length; i += config.seriesChunkSize) {
        final chunk = g.sublist(i, _min(i + config.seriesChunkSize, g.length));
        final r = await uploader.importSeriesBatch(
          link.linkId,
          SeriesBatch(
            vitalTypeId: chunk.first.vitalTypeId,
            sourcePackage: chunk.first.sourcePackage,
            records: chunk,
            timezoneId: chunk.first.timezoneId,
            sourceDeviceName: chunk.first.sourceDeviceName,
          ),
        );
        run.add('imported', r.inserted);
        run.add('duplicates', r.duplicates);
        run.add('skipped_deleted', r.skippedDeleted);
        run.add('skipped_compacted', r.skippedCompacted);
        run.add('skipped_other_source', r.skippedOtherSource);
      }
    }

    if (deletions.isNotEmpty) {
      final ids = deletions.map((d) => d.externalId).toSet().toList();
      for (var i = 0; i < ids.length; i += config.deletionChunkSize) {
        run.add('deleted',
            await uploader.applyDeletions(link.linkId, ids.sublist(i, _min(i + config.deletionChunkSize, ids.length))));
      }
    }
  }
}

int _min(int a, int b) => a < b ? a : b;

class _RunCounters {
  final Map<String, int> c = {};
  void add(String k, [int n = 1]) {
    if (n == 0) return;
    c[k] = (c[k] ?? 0) + n;
  }
}
