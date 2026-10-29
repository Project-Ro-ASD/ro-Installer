import 'dart:convert';
import 'dart:io';

import 'command_runner.dart';
import 'install_artifact_collector.dart';
import 'session_report.dart';

class InstallLogExportResult {
  const InstallLogExportResult({
    required this.success,
    this.logPath,
    this.summaryPath,
    this.manifestPath,
    this.error,
  });

  final bool success;
  final String? logPath;
  final String? summaryPath;
  final String? manifestPath;
  final String? error;
}

typedef SessionExporter =
    Future<InstallLogExportResult> Function({
      required DateTime startedAt,
      required DateTime finishedAt,
      required bool success,
      required String finalStatus,
      required List<String> statusHistory,
      required List<String> technicalLogs,
      required Map<String, dynamic> installContext,
    });

class _ExportBudget {
  int nodes = 512;
  int chars = 65536;
}

class InstallLogExportService {
  InstallLogExportService({
    this.exportExecutable = '/usr/libexec/ro-installer-export',
    this.targetDirectory,
  });
  final String? targetDirectory;
  final String exportExecutable;

  static final InstallLogExportService instance = InstallLogExportService();

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

      final sanitizedStatus = _boundedLines(statusHistory);
      final sanitizedTechnical = _boundedLines(technicalLogs);
      final sanitizedContext = _sanitizeContext(installContext);

      final buffer = StringBuffer()
        ..writeln('Ro-Installer Installation Session Log')
        ..writeln('====================================')
        ..writeln('Started: ${startedAt.toIso8601String()}')
        ..writeln('Finished: ${finishedAt.toIso8601String()}')
        ..writeln('DurationSec: ${finishedAt.difference(startedAt).inSeconds}')
        ..writeln('Result: ${success ? 'SUCCESS' : 'FAILED'}')
        ..writeln('FinalStatus: ${_sanitizeLine(finalStatus)}')
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

      final summary = {
        'startedAt': startedAt.toIso8601String(),
        'finishedAt': finishedAt.toIso8601String(),
        'durationSeconds': finishedAt.difference(startedAt).inSeconds,
        'success': success,
        'finalStatus': _sanitizeLine(finalStatus),
        'statusHistory': sanitizedStatus,
        'context': sanitizedContext,
        'textTruncated':
            sanitizedStatus.length < statusHistory.length ||
            sanitizedTechnical.length < technicalLogs.length,
        'technicalLogLineCount': sanitizedTechnical.length,
        'logFile': 'install.log',
      };

      final manifest = {
        'schemaVersion': 1,
        'artifactKind': 'ro-installer-install-session',
        'sessionStamp': stamp,
        'createdAt': DateTime.now().toUtc().toIso8601String(),
        'result': success ? 'success' : 'failed',
        'files': {
          'technicalLog': 'install.log',
          'summary': 'summary.json',
          'manifest': 'manifest.json',
        },
        'collectionContract': {
          'version': InstallArtifactCollector.structuredContractVersion,
          'redaction': 'SecretRedactor.redactText',
          'technicalLogSections': const ['structured-outcome'],
        },
        'context': sanitizedContext,
        'statusHistoryLineCount': sanitizedStatus.length,
        'technicalLogLineCount': sanitizedTechnical.length,
      };

      // The isolated user-side writer refuses root and publishes one complete
      // directory with a hash manifest. No pre-existing file is overwritten.
      final payload = jsonEncode({
        'target': targetDir.path,
        'files': {
          'install.log': buffer.toString(),
          'summary.json': jsonEncode({...summary, 'manifest': manifest}),
        },
      });
      if (utf8.encode(payload).length > 512 * 1024) {
        return const InstallLogExportResult(
          success: false,
          error: 'EXPORT_LIMIT',
        );
      }
      final process = await Process.start(
        exportExecutable,
        [],
        includeParentEnvironment: false,
        environment: const {'PATH': '/usr/bin:/usr/sbin', 'LC_ALL': 'C'},
      );
      final output = <int>[];
      final response = process.stdout.listen((chunk) {
        if (output.length + chunk.length > 16384) {
          process.kill();
        } else {
          output.addAll(chunk);
        }
      });
      final responseDone = response.asFuture<void>();
      final errors = process.stderr.drain<void>();
      process.stdin.write(payload);
      await process.stdin.close().timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          process.kill();
          throw const FormatException("EXPORT_TIMEOUT");
        },
      );
      final status = await process.exitCode.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          process.kill();
          return -1;
        },
      );
      await responseDone.timeout(const Duration(seconds: 2));
      final raw = utf8.decode(output);
      await errors.timeout(const Duration(seconds: 2));
      if (raw.length > 16384) {
        return const InstallLogExportResult(
          success: false,
          error: 'EXPORT_FAILED',
        );
      }
      final result = jsonDecode(raw) as Map<String, dynamic>;
      if (status != 0 || result['success'] != true) {
        final code = result['error'];
        return InstallLogExportResult(
          success: false,
          error:
              const [
                'EXPORT_ROOT_DENIED',
                'EXPORT_INPUT_INVALID',
                'EXPORT_PUBLISH_UNCONFIRMED',
              ].contains(code)
              ? code
              : 'EXPORT_FAILED',
        );
      }
      return InstallLogExportResult(
        success: true,
        logPath: SecretRedactor.redactText(result['logPath'] as String),
        summaryPath: SecretRedactor.redactText(result['summaryPath'] as String),
        manifestPath: SecretRedactor.redactText(
          result['manifestPath'] as String,
        ),
      );
    } catch (_) {
      return const InstallLogExportResult(
        success: false,
        error: "EXPORT_FAILED",
      );
    }
  }

  Future<Directory> _resolveTargetDir() async {
    final explicit =
        targetDirectory ?? Platform.environment['RO_INSTALLER_LOG_DIR'];
    if (explicit != null && explicit.trim().isNotEmpty) {
      return Directory(explicit.trim());
    }
    final state = Platform.environment['XDG_STATE_HOME'];
    final home = Platform.environment['HOME'];
    if (state != null && state.startsWith('/')) {
      return Directory('$state/ro-installer/exports');
    }
    if (home != null && home.startsWith('/')) {
      return Directory('$home/.local/state/ro-installer/exports');
    }
    throw StateError('EXPORT_TARGET_UNAVAILABLE');
  }

  String _timestampForName(DateTime value) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${value.year}${two(value.month)}${two(value.day)}-${two(value.hour)}${two(value.minute)}${two(value.second)}';
  }

  String _sanitizeLine(String raw) {
    final value = SecretRedactor.redactText(raw);
    return value.length > 4096 ? value.substring(0, 4096) : value;
  }

  List<String> _boundedLines(List<String> lines) {
    final result = <String>[];
    var bytes = 0;
    for (final line in lines.take(3000)) {
      final safe = _sanitizeLine(line);
      bytes += utf8.encode(safe).length;
      if (bytes > 65536) break;
      result.add(safe);
    }
    return result;
  }

  Map<String, dynamic> _sanitizeContext(Map<String, dynamic> raw) {
    return _sanitizeContextMap(raw, 0, _ExportBudget());
  }

  Map<String, dynamic> _sanitizeContextMap(
    Map<dynamic, dynamic> raw, [
    int depth = 0,
    _ExportBudget? budget,
  ]) {
    budget ??= _ExportBudget();
    if (depth > 8 || --budget.nodes < 0 || budget.chars <= 0) {
      return {"truncated": true};
    }
    final sanitized = <String, dynamic>{};
    for (final entry in raw.entries.take(64)) {
      if (budget.nodes <= 0 || budget.chars <= 0) break;
      if (entry.key is! String) continue;
      final key = entry.key as String;
      final keyLower = key.toLowerCase();
      if (SecretRedactor.isSecretKey(key) ||
          keyLower == 'username' ||
          keyLower.contains('password') ||
          keyLower.contains('passphrase') ||
          keyLower.contains('secret') ||
          keyLower.contains('token')) {
        continue;
      }
      if (key == 'sessionReport') {
        final report = SessionReport.parse(entry.value);
        if (report != null) sanitized[key] = report.json;
      } else {
        sanitized[_sanitizeLine(key)] = _sanitizeContextValue(
          entry.value,
          depth + 1,
          budget,
        );
      }
    }
    return sanitized;
  }

  dynamic _sanitizeContextValue(
    dynamic value, [
    int depth = 0,
    _ExportBudget? budget,
  ]) {
    budget ??= _ExportBudget();
    if (depth > 8 || --budget.nodes < 0 || budget.chars <= 0) {
      return "[TRUNCATED]";
    }
    if (value is Map) {
      return _sanitizeContextMap(value, depth + 1, budget);
    }
    if (value is List) {
      return value
          .take(64)
          .map((v) => _sanitizeContextValue(v, depth + 1, budget))
          .toList(growable: false);
    }
    if (value is String) {
      final safe = _sanitizeLine(value);
      final cut = safe.length > budget.chars
          ? safe.substring(0, budget.chars)
          : safe;
      budget.chars -= cut.length;
      return cut;
    }
    return value == null || value is bool || value is num && value.isFinite
        ? value
        : "[UNSUPPORTED]";
  }
}
