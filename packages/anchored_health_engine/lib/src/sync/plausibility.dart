import '../models.dart';

enum PlausibilityResult {
  /// Birth year and sex match (as far as both sides have values).
  match,

  /// Mismatch => the app should warn before connecting.
  mismatch,

  /// Not checkable (profile without data, permission denied, Android) => continue silently.
  unknown,
}

/// Plausibility check before connecting (iOS only): compares only birth year
/// and sex; nothing of it is stored. [compare] also accepts common German
/// spellings for the profile sex.
class PlausibilityCheck {
  const PlausibilityCheck();

  PlausibilityResult compare({
    required int? profileBirthYear,
    required String? profileSex,
    required HealthCharacteristics? health,
  }) {
    if (health == null || profileBirthYear == null || profileSex == null) {
      return PlausibilityResult.unknown;
    }
    var compared = false;
    if (health.birthYear != null) {
      compared = true;
      if (health.birthYear != profileBirthYear) return PlausibilityResult.mismatch;
    }
    final hs = health.biologicalSex;
    final ps = _normSex(profileSex);
    if (hs != null && ps != null) {
      compared = true;
      if (hs != ps) return PlausibilityResult.mismatch;
    }
    return compared ? PlausibilityResult.match : PlausibilityResult.unknown;
  }

  String? _normSex(String s) {
    switch (s.toLowerCase()) {
      case 'female':
      case 'f':
      case 'w':
      case 'weiblich':
        return 'female';
      case 'male':
      case 'm':
      case 'männlich':
        return 'male';
      case 'other':
      case 'divers':
      case 'd':
        return 'other';
      default:
        return null;
    }
  }
}
