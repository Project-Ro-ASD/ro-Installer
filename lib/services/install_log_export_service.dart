import 'dart:convert';
import 'dart:io';

class InstallLogExportResult {
  const InstallLogExportResult({
    required this.success,
    this.logPath,
    this.summaryPath,
    this.error,
  });

  final bool success;
  final String? logPath;
  final String? summaryPath;
  final String? error;
}

class InstallLogExportService {
  InstallLogExportService._();

  static final InstallLogExportService instance = InstallLogExportService._();

  Future<InstallLogExportResult> exportSession({
    required DateTime startedAt,
    required DateTime finishedAt,
    required bool success,
    required String finalStatus,
    required List<String> statusHistory,
    required List<String> technicalLogs,
    required Map<String, dynamic> installContext,
  }) async {
    try {
      final targetDir = await _resolveTargetDir();
      final stamp = _timestampForName(startedAt);
      final logFile = File('${targetDir.path}/install-$stamp.log');
      final summaryFile = File('${targetDir.path}/install-$stamp.summary.json');

      final sanitizedStatus = statusHistory.map(_sanitizeLine).toList(growable: false);
      final sanitizedTechnical = technicalLogs.map(_sanitizeLine).toList(growable: false);
      final sanitizedContext = _sanitizeContext(installContext);

      final buffer = StringBuffer()
        ..writeln('Ro-Installer Installation Session Log')
        ..writeln('====================================')
        ..writeln('Started: ${startedAt.toIso8601String()}')
        ..writeln('Finished: ${finishedAt.toIso8601String()}')
        ..writeln('DurationSec: ${finishedAt.difference(startedAt).inSeconds}')
        ..writeln('Result: ${success ? 'SUCCESS' : 'FAILED'}')
        ..writeln('FinalStatus: $finalStatus')
        ..writeln('')
        ..writeln('[STATUS HISTORY]');

      for (final line in sanitizedStatus) {
        buffer.writeln(line);
      }

      buffer
        ..writeln('')
        ..writeln('[TECHNICAL LOGS]');

      for (final line in sanitizedTechnical) {
        buffer.writeln(line);
      }

      await logFile.writeAsString(buffer.toString(), flush: true);

      final summary = {
        'startedAt': startedAt.toIso8601String(),
        'finishedAt': finishedAt.toIso8601String(),
        'durationSeconds': finishedAt.difference(startedAt).inSeconds,
        'success': success,
        'finalStatus': _sanitizeLine(finalStatus),
        'statusHistory': sanitizedStatus,
        'context': sanitizedContext,
        'technicalLogLineCount': sanitizedTechnical.length,
        'logFile': logFile.path,
      };

      await summaryFile.writeAsString(
        const JsonEncoder.withIndent('  ').convert(summary),
        flush: true,
      );

      return InstallLogExportResult(
        success: true,
        logPath: logFile.path,
        summaryPath: summaryFile.path,
      );
    } catch (e) {
      return InstallLogExportResult(success: false, error: e.toString());
    }
  }

  Future<Directory> _resolveTargetDir() async {
    final candidates = <String>[];
    final fromEnv = Platform.environment['RO_INSTALLER_LOG_DIR'];
    if (fromEnv != null && fromEnv.trim().isNotEmpty) {
      candidates.add(fromEnv.trim());
    }

    candidates.add('${Directory.current.path}/outputs/logs');
    candidates.add('/tmp/ro-installer/logs');

    for (final path in candidates) {
      final dir = Directory(path);
      try {
        if (!await dir.exists()) {
          await dir.create(recursive: true);
        }
        return dir;
      } catch (_) {
        continue;
      }
    }

    throw Exception('No writable log directory found');
  }

  String _timestampForName(DateTime value) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${value.year}${two(value.month)}${two(value.day)}-${two(value.hour)}${two(value.minute)}${two(value.second)}';
  }

  String _sanitizeLine(String raw) {
    var line = raw;

    line = line.replaceAllMapped(
      RegExp(r'(password\s+)(\S+)', caseSensitive: false),
      (m) => '${m.group(1)}***',
    );

    line = line.replaceAllMapped(
      RegExp("(echo\\s+['\"])([^'\":\\s]+):([^'\"\\s]+)(['\"]\\s*\\|\\s*chpasswd)", caseSensitive: false),
      (m) => '${m.group(1)}***:***${m.group(4)}',
    );

    line = line.replaceAllMapped(
      RegExp("(root:)([^\\s'\"]+)", caseSensitive: false),
      (m) => '${m.group(1)}***',
    );

    return line;
  }

  Map<String, dynamic> _sanitizeContext(Map<String, dynamic> raw) {
    final context = Map<String, dynamic>.from(raw);
    context.remove('password');
    context.remove('username');
    return context;
  }
}
