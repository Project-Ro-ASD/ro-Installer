import 'helper_protocol.dart';

/// Rsync logical file-data bytes, not physical disk writes or whole-install ETA.
class CopyProgress {
  const CopyProgress({
    required this.phase,
    required this.bytesProcessed,
    this.bytesPerSecond,
    this.etaSeconds,
  });
  final String phase;
  final int bytesProcessed;
  final int? bytesPerSecond;
  final int? etaSeconds;
  static const maxBytes = 9007199254740991;
  Map<String, dynamic> toJson({int version = 1}) => {
    'protocolVersion': version,
    'type': 'copy-progress',
    'phase': phase,
    'bytesProcessed': bytesProcessed,
    'bytesPerSecond': bytesPerSecond,
    'etaSeconds': etaSeconds,
  };
  factory CopyProgress.fromJson(Map<String, dynamic> value, {int version = 2}) {
    bool bounded(dynamic n, int max) => n is int && n >= 0 && n <= max;
    if (!exactFields(value, {
          'protocolVersion',
          'type',
          'phase',
          'bytesProcessed',
          'bytesPerSecond',
          'etaSeconds',
        }) ||
        value['protocolVersion'] is! int ||
        value['protocolVersion'] != version ||
        value['type'] != 'copy-progress' ||
        !const ['main', 'efi'].contains(value['phase']) ||
        !bounded(value['bytesProcessed'], maxBytes) ||
        (value['bytesPerSecond'] != null &&
            !bounded(value['bytesPerSecond'], maxBytes)) ||
        (value['etaSeconds'] != null &&
            (!bounded(value['etaSeconds'], 86400) ||
                value['bytesPerSecond'] == null ||
                value['bytesPerSecond'] == 0))) {
      throw const FormatException('Invalid copy progress');
    }
    return CopyProgress(
      phase: value['phase'],
      bytesProcessed: value['bytesProcessed'],
      bytesPerSecond: value['bytesPerSecond'],
      etaSeconds: value['etaSeconds'],
    );
  }
}

/// Never parses filenames/stderr; unknown output contributes no measurement.
/// At most one sample/second/phase, using a monotonic clock and no extra scan.
class RsyncProgressParser {
  RsyncProgressParser(this.phase, {int Function()? milliseconds})
    : _now = milliseconds ?? _clock();
  final String phase;
  final int Function() _now;
  static int Function() _clock() {
    final watch = Stopwatch()..start();
    return () => watch.elapsedMilliseconds;
  }

  static final _line = RegExp(
    r'^\s*([0-9]+(?:,[0-9]{3})*)\s+([0-9]{1,3})%\s+[0-9]+(?:\.[0-9]+)?[kMGT]?B/s\s+([0-9]{1,3}):([0-5][0-9]):([0-5][0-9])\s+\(xfr#[0-9]+,\s+(to-chk|ir-chk)=[0-9]+/[0-9]+\)\s*$',
  );
  int? _lastTime, _lastBytes, _started;
  CopyProgress? add(String line) {
    if (line.length > 512) return null;
    final m = _line.firstMatch(line);
    if (m == null) return null;
    final bytes = int.tryParse(m[1]!.replaceAll(',', ''));
    final percent = int.tryParse(m[2]!);
    if (bytes == null ||
        bytes > CopyProgress.maxBytes ||
        percent == null ||
        percent > 100) {
      return null;
    }
    final time = _now();
    if (time < 0 ||
        (_lastTime != null &&
            (time - _lastTime! < 1000 || bytes < _lastBytes!))) {
      return null;
    }
    _started ??= time;
    final rate = _lastTime == null || time - _started! < 2000
        ? null
        : ((bytes - _lastBytes!) * 1000 ~/ (time - _lastTime!));
    final eta =
        int.parse(m[3]!) * 3600 + int.parse(m[4]!) * 60 + int.parse(m[5]!);
    final remaining =
        rate != null &&
            rate > 0 &&
            m[6] == 'to-chk' &&
            percent > 0 &&
            percent < 100 &&
            eta > 0 &&
            eta <= 86400
        ? eta
        : null;
    _lastTime = time;
    _lastBytes = bytes;
    return CopyProgress(
      phase: phase,
      bytesProcessed: bytes,
      bytesPerSecond: rate,
      etaSeconds: remaining,
    );
  }
}
