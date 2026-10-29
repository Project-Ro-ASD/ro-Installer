import 'session_report.dart';

typedef ObservationSink = Future<void> Function(Map<String, dynamic> request);

/// Timings belong to this engine only. No wall-clock arithmetic or raw text.
/// Every observer call is isolated from installation control flow.
class InstallObservation {
  InstallObservation({ObservationSink? sink, int Function()? microseconds})
    : _sink = sink,
      _read = microseconds ?? _clock() {
    _started = _now();
  }
  static int Function() _clock() {
    final watch = Stopwatch()..start();
    return () => watch.elapsedMicroseconds;
  }

  final ObservationSink? _sink;
  final int Function() _read;
  late final int _started;
  int _lastTime = 0;
  int _now() {
    try {
      _lastTime = _read();
    } catch (_) {
      available = false;
    }
    return _lastTime;
  }

  bool available = true;
  int lastSuccessfulStage = 0;
  int? failedStage;
  final _stages = <int, int>{};
  final _spans = <String, int>{};
  int _ms(int start) => (_now() - start).clamp(0, 86400000000) ~/ 1000;
  Future<void> _send(Map<String, dynamic> value) async {
    if (!available || _sink == null) return;
    try {
      await _sink(value).timeout(const Duration(milliseconds: 500));
    } catch (_) {
      available = false;
    }
  }

  Future<void> event(
    String type, {
    int? stage,
    String operation = 'stage.command',
    String status = 'running',
    int? duration,
    int? exitCode,
    String? error,
  }) async {
    final payload = <String, dynamic>{
      'eventType': type,
      'stageId': stage,
      'operationId': operation,
      'status': status,
      'durationMs': duration,
      'exitCode': exitCode,
      'errorCode': error,
    };
    if (!validSchema(payload, ['object', 'payload'])) {
      available = false;
      return;
    }
    await _send({'op': 'observe', 'event': payload});
  }

  Future<void> beginStage(int stage) async {
    _stages[stage] = _now();
    await event('stage.start', stage: stage, duration: 0);
  }

  Future<void> endStage(int stage, bool success, {String? error}) async {
    final start = _stages.remove(stage);
    if (start == null) return;
    if (success) {
      lastSuccessfulStage = stage;
    } else {
      failedStage = stage;
    }
    await event(
      'stage.end',
      stage: stage,
      status: success ? 'success' : 'failed',
      duration: _ms(start),
      error: error,
    );
  }

  Future<T> span<T>(
    String operation,
    Future<T> Function() action, {
    bool Function(T)? success,
  }) async {
    final start = _now();
    _spans[operation] = start;
    await event('span.start', operation: operation, duration: 0);
    var ok = false;
    try {
      final result = await action();
      ok = success?.call(result) ?? true;
      return result;
    } finally {
      _spans.remove(operation);
      await event(
        'span.end',
        operation: operation,
        status: ok ? 'success' : 'failed',
        duration: _ms(start),
      );
    }
  }

  Future<void> finish({
    required bool success,
    required String? primary,
    required bool cleanup,
    int? remaining,
  }) async {
    for (final stage in _stages.keys.toList()) {
      await endStage(stage, false, error: primary);
    }
    final duration = _ms(_started);
    await event('span.start', operation: 'engine', duration: 0);
    await event(
      'span.end',
      operation: 'engine',
      status: success ? 'success' : 'failed',
      duration: duration,
    );
    final failed =
        failedStage ??
        (primary != null && RegExp(r'^STAGE_[1-9]_FAILED$').hasMatch(primary)
            ? int.parse(primary.split('_')[1])
            : null);
    final outcome = <String, dynamic>{
      'terminalStatus': success ? 'success' : 'failed',
      'failedStage': failed,
      'lastSuccessfulStage': lastSuccessfulStage,
      'primaryError': primary,
      'cleanupStatus': cleanup ? 'success' : 'failed',
      'remainingResources': remaining,
      'engineDurationMs': duration,
    };
    if (validSchema(outcome, ['object', 'outcome'])) {
      await _send({'op': 'outcome', 'outcome': outcome});
    }
  }
}
