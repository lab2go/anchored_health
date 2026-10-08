import '../mapping/type_catalog.dart';
import '../models.dart';
import '../types.dart';

/// Series classification for glucose: allowlist of series sources **or**
/// density (>= [minSamples] values of the same source within [window]). The
/// detection is sticky per source ([stickySources]) so that a small delta
/// after a gap does not flip back to single readings.
class SeriesClassifier {
  const SeriesClassifier({
    this.minSamples = 6,
    this.window = const Duration(minutes: 60),
  });

  final int minSamples;
  final Duration window;

  /// Splits [samples] of a platform type with single and series targets.
  SeriesClassification classify({
    required List<HealthSample> samples,
    required TypeMappingEntry seriesEntry,
    required Set<String> stickySources,
  }) {
    final bySource = <String, List<HealthSample>>{};
    for (final s in samples) {
      bySource.putIfAbsent(s.sourcePackage, () => []).add(s);
    }
    final seriesSources = <String>{};
    final newlySticky = <String>{};
    for (final entry in bySource.entries) {
      final src = entry.key;
      if (stickySources.contains(src)) {
        seriesSources.add(src);
      } else if (seriesEntry.matchesSeriesSource(src) || isDense(entry.value)) {
        seriesSources.add(src);
        newlySticky.add(src);
      }
    }
    return SeriesClassification(
      single: [for (final s in samples) if (!seriesSources.contains(s.sourcePackage)) s],
      series: [for (final s in samples) if (seriesSources.contains(s.sourcePackage)) s],
      newlyStickySources: newlySticky,
    );
  }

  /// >= [minSamples] values within a window of [window] (inclusive).
  bool isDense(List<HealthSample> sameSource) {
    if (sameSource.length < minSamples) return false;
    final times = sameSource.map((s) => s.start.toUtc().millisecondsSinceEpoch).toList()..sort();
    final w = window.inMilliseconds;
    for (var i = 0; i + minSamples - 1 < times.length; i++) {
      if (times[i + minSamples - 1] - times[i] <= w) return true;
    }
    return false;
  }
}

class SeriesClassification {
  const SeriesClassification({
    required this.single,
    required this.series,
    required this.newlyStickySources,
  });
  final List<HealthSample> single;
  final List<HealthSample> series;
  final Set<String> newlyStickySources;
}

/// Series source filter: exactly **one** series source per profile × type.
/// Without a preference, the first detected source becomes the default.
class SeriesSourceFilter {
  const SeriesSourceFilter();

  SeriesSourceDecision apply({
    required List<HealthSample> series,
    required String? preferredSource,
  }) {
    if (series.isEmpty) {
      return SeriesSourceDecision(
          kept: const [], skippedOtherSource: 0, preferredSource: preferredSource, detectedOtherSources: const {});
    }
    final preferred = preferredSource ?? series.first.sourcePackage;
    final kept = <HealthSample>[];
    final others = <String>{};
    var skipped = 0;
    for (final s in series) {
      if (s.sourcePackage == preferred) {
        kept.add(s);
      } else {
        skipped++;
        others.add(s.sourcePackage);
      }
    }
    return SeriesSourceDecision(
      kept: kept,
      skippedOtherSource: skipped,
      preferredSource: preferred,
      detectedOtherSources: others,
      preferenceIsNew: preferredSource == null,
    );
  }
}

class SeriesSourceDecision {
  const SeriesSourceDecision({
    required this.kept,
    required this.skippedOtherSource,
    required this.preferredSource,
    required this.detectedOtherSources,
    this.preferenceIsNew = false,
  });
  final List<HealthSample> kept;
  final int skippedOtherSource;
  final String? preferredSource;

  /// Further series sources => run log event `source_detected`.
  final Set<String> detectedOtherSources;
  final bool preferenceIsNew;
}

/// Store of the preferred series source per profile and vital type.
abstract class SeriesPreferenceStore {
  Future<String?> preferredSource(String profileId, VitalKey key);
  Future<void> setPreferredSource(String profileId, VitalKey key, String sourcePackage);
}

class InMemorySeriesPreferenceStore implements SeriesPreferenceStore {
  final Map<String, String> _m = {};
  @override
  Future<String?> preferredSource(String profileId, VitalKey key) async => _m['$profileId/${key.name}'];
  @override
  Future<void> setPreferredSource(String profileId, VitalKey key, String sourcePackage) async =>
      _m['$profileId/${key.name}'] = sourcePackage;
}
