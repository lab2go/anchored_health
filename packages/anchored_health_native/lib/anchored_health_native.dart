/// HealthKit bridge (Pigeon API `AnchoredHealthApi`).
///
/// Only iOS has an implementation. On every other platform each method throws
/// [HealthPlatformUnsupported] (use the package `health` on Android).
library;

import 'package:flutter/foundation.dart';

import 'src/messages.g.dart';

export 'src/messages.g.dart'
    show
        HkRequestStatus,
        HkWriteStatus,
        HkSource,
        HkDevice,
        HkBloodPressure,
        HkSample,
        HkDeletedObject,
        HkAnchoredQueryRequest,
        HkAnchoredQueryResult,
        HkSaveRequest,
        HkCharacteristics,
        AnchoredHealthApi;

/// Thrown on platforms without an implementation.
class HealthPlatformUnsupported extends UnsupportedError {
  HealthPlatformUnsupported(String platform)
      : super('anchored_health_native: $platform is not supported '
            '(iOS only; use the package health on Android)');
}

/// Facade over the Pigeon API. [api] is injectable for tests.
class AnchoredHealthNative {
  AnchoredHealthNative({AnchoredHealthApi? api, bool? isSupportedPlatform})
      : _api = api ?? AnchoredHealthApi(),
        _supported = isSupportedPlatform ??
            (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS);

  final AnchoredHealthApi _api;
  final bool _supported;

  bool get isSupportedPlatform => _supported;

  AnchoredHealthApi get _checked {
    if (!_supported) {
      throw HealthPlatformUnsupported(
          kIsWeb ? 'web' : defaultTargetPlatform.name);
    }
    return _api;
  }

  /// Returns `false` instead of throwing on unsupported platforms.
  Future<bool> isHealthDataAvailable() async =>
      _supported ? _api.isHealthDataAvailable() : false;

  Future<List<String>> supportedTypes() => _checked.supportedTypes();

  Future<String> unitFor(String type) => _checked.unitFor(type);

  Future<HkRequestStatus> requestStatus({
    required List<String> read,
    required List<String> write,
    bool characteristics = false,
    bool includeBloodPressureCorrelation = true,
  }) =>
      _checked.requestStatus(
          read, write, characteristics, includeBloodPressureCorrelation);

  Future<bool> requestAuthorization({
    required List<String> read,
    required List<String> write,
    bool characteristics = false,
    bool includeBloodPressureCorrelation = true,
  }) =>
      _checked.requestAuthorization(
          read, write, characteristics, includeBloodPressureCorrelation);

  Future<HkWriteStatus> writeStatus(String type) => _checked.writeStatus(type);

  Future<HkAnchoredQueryResult> anchoredQuery({
    required String type,
    String? anchor,
    int limit = 1000,
    DateTime? from,
    DateTime? to,
  }) =>
      _checked.anchoredQuery(HkAnchoredQueryRequest(
        type: type,
        anchor: anchor,
        limit: limit,
        fromMs: from?.toUtc().millisecondsSinceEpoch,
        toMs: to?.toUtc().millisecondsSinceEpoch,
      ));

  Future<List<String>> save(List<HkSaveRequest> samples) =>
      _checked.save(samples);

  Future<int> delete(String type, List<String> uuids) =>
      _checked.delete(type, uuids);

  Future<HkCharacteristics> characteristics() => _checked.characteristics();
}
