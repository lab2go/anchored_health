# Sleep #36 - author draft

Base 970357196147fb1163640db706af37f9b303b50e. Old patch b7e925673cae8b02d64a272892d87b3b applied by three-way merge; H1 SDNN LOINC null and VO2 unit composition retained.

Flutter 3.41.9/Dart 3.11.5 engine tests: 74/74, -j 2. Engine analyzer: no issues. Native Dart tests recorded in app delivery. Swift sources plus complete RunnerTests: iOS simulator SDK typecheck exit 0, no test execution. XCTest execution is REQUIRED through Mobile/Planner with the shared simulator lock. This worker does not claim it ran XCTest. No tag, deployment, or main push.

Review fix P1 (19.10.2026): time zone offsets GMT/UTC +-hh[:mm] are normalised to GMT+-hh:mm instead of dropped; engine 74/74, native Dart 3/3, analyzer clean. XCTest (RunnerTests.testTimeZoneMetadataIanaAndNormalisedOffsets) still to be run by Mobile with the simulator lock.
