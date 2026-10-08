// Example and probe app for anchored_health_native (no real data).
// Shows availability, requests permissions and reads one type via an
// anchored query. Useful for manual checks on a real device.
import 'package:flutter/material.dart';
import 'package:anchored_health_native/anchored_health_native.dart';

void main() {
  runApp(const ProbeApp());
}

class ProbeApp extends StatefulWidget {
  const ProbeApp({super.key});

  @override
  State<ProbeApp> createState() => _ProbeAppState();
}

class _ProbeAppState extends State<ProbeApp> {
  final _native = AnchoredHealthNative();
  final _log = <String>[];
  String? _anchor;

  static const _read = [
    'bloodPressure',
    'heartRate',
    'bodyMass',
    'bloodGlucose',
  ];
  static const _write = ['bloodPressure', 'bodyMass'];

  void _add(String line) => setState(() => _log.insert(0, line));

  Future<void> _run(String label, Future<Object?> Function() f) async {
    try {
      final r = await f();
      _add('$label: $r');
    } catch (e) {
      _add('$label ERROR: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('anchored_health_native probe')),
        body: Column(
          children: [
            Wrap(
              spacing: 8,
              children: [
                ElevatedButton(
                  onPressed: () =>
                      _run('available', _native.isHealthDataAvailable),
                  child: const Text('Available?'),
                ),
                ElevatedButton(
                  onPressed: () => _run(
                      'authorization',
                      () => _native.requestAuthorization(
                          read: _read, write: _write, characteristics: true)),
                  child: const Text('Authorize'),
                ),
                ElevatedButton(
                  onPressed: () => _run('read blood pressure', () async {
                    final r = await _native.anchoredQuery(
                        type: 'bloodPressure', anchor: _anchor, limit: 100);
                    _anchor = r.nextAnchor;
                    return '${r.samples.length} samples, ${r.deleted.length} deleted';
                  }),
                  child: const Text('Read blood pressure'),
                ),
              ],
            ),
            Expanded(
              child: ListView(
                children: [for (final l in _log) ListTile(title: Text(l))],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
