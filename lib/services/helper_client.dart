import '../models/ntfs_shrink_assessment.dart';
import '../models/ntfs_shrink_installation_plan.dart';
import '../models/manual_installation_plan.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'helper_protocol.dart';
import 'copy_progress.dart';
import '../models/approved_full_disk_plan.dart';
import '../models/gpt_disk_snapshot.dart';
import '../models/free_space_installation_plan.dart';
import 'session_report.dart';

abstract class HelperProcess {
  Stream<List<int>> get output;
  Stream<List<int>> get diagnostics;
  Future<int> get exitCode;
  void send(String value);
  Future<void> closeInput();
  void terminate();
}

typedef HelperProcessStarter =
    Future<HelperProcess> Function(String executable, List<String> args);

class _NativeHelperProcess implements HelperProcess {
  _NativeHelperProcess(this.process);
  final Process process;
  @override
  Stream<List<int>> get output => process.stdout;
  @override
  Stream<List<int>> get diagnostics => process.stderr;
  @override
  Future<int> get exitCode => process.exitCode;
  @override
  void send(String value) => process.stdin.write(value);
  @override
  Future<void> closeInput() => process.stdin.close();
  @override
  void terminate() {
    process.kill();
  }
}

class HelperException implements Exception {
  const HelperException(this.code);
  final String code;
  @override
  String toString() => 'Installer helper: $code';
}

class HelperClient {
  HelperClient({
    HelperProcessStarter? start,
    this.readTimeout = const Duration(minutes: 2),
    this.protocolVersion = 1,
  }) : _start = start ?? _startNative;
  static final instance = HelperClient();
  final HelperProcessStarter _start;
  final int protocolVersion;
  final Duration readTimeout;
  static const executable = '/usr/bin/pkexec';
  static const arguments = [
    '--disable-internal-agent',
    '/usr/libexec/ro-installer-helper',
    '--protocol=1',
  ];
  static Future<HelperProcess> _startNative(
    String executable,
    List<String> args,
  ) async => _NativeHelperProcess(
    await Process.start(executable, args, runInShell: false),
  );

  Future<DeviceIdentity> probe(String disk) async {
    if (!DeviceIdentity.pathPattern.hasMatch(disk)) {
      throw const HelperException('INVALID_REQUEST');
    }
    final result = await _call({
      'protocolVersion': protocolVersion,
      'operation': 'probe-disk',
      'disk': disk,
    });
    try {
      if (!exactFields(result, {
            'protocolVersion',
            'type',
            'operation',
            'ok',
            'device',
          }) ||
          result['device'] is! Map<String, dynamic>) {
        throw const FormatException();
      }
      final identity = DeviceIdentity.fromJson(result['device']);
      if (identity.path != disk) throw const FormatException();
      return identity;
    } on FormatException {
      throw const HelperException('PROTOCOL_ERROR');
    }
  }

  Future<void> install(
    DeviceIdentity identity,
    void Function(double, String) onProgress,
  ) => installWithReport(identity, onProgress);

  Future<GptDiskSnapshot> probeFreeSpace(String disk) async {
    if (protocolVersion != 2 || !DeviceIdentity.pathPattern.hasMatch(disk)) {
      throw const HelperException('INVALID_REQUEST');
    }
    final result = await _call({
      'protocolVersion': 2,
      'operation': 'probe-free-space',
      'disk': disk,
    });
    try {
      if (!exactFields(result, {
        'protocolVersion',
        'type',
        'operation',
        'ok',
        'snapshot',
      })) {
        throw const FormatException();
      }
      final snapshot = GptDiskSnapshot.fromJson(result['snapshot']);
      if (snapshot.device.path != disk || snapshot.partitions.length > 32) {
        throw const FormatException();
      }
      return snapshot;
    } on FormatException {
      throw const HelperException('PROTOCOL_ERROR');
    }
  }

  Future<FreeSpaceInstallationPlan> validateFreeSpacePlan(
    FreeSpaceInstallationPlan proposed,
  ) async {
    if (protocolVersion != 2) throw const HelperException('INVALID_REQUEST');
    final result = await _call({
      'protocolVersion': 2,
      'operation': 'validate-free-space-plan',
      'disk': proposed.snapshot.device.path,
      'expectedDevice': proposed.snapshot.device.expected,
      'tableFingerprint': proposed.snapshot.tableFingerprint,
      'selectedExtent': proposed.selectedExtent.json,
    });
    if (!exactFields(result, {
          'protocolVersion',
          'type',
          'operation',
          'ok',
          'plan',
        }) ||
        !samePlanValue(result['plan'], proposed.intentJson)) {
      throw const HelperException('PROTOCOL_ERROR');
    }
    return proposed;
  }

  Future<ManualInstallationPlan> validateManualPlan(
    ManualInstallationPlan proposed,
  ) async {
    if (protocolVersion != 2) throw const HelperException('INVALID_REQUEST');
    final result = await _call({
      'protocolVersion': 2,
      'operation': 'validate-manual-plan',
      'disk': proposed.snapshot.device.path,
      'expectedDevice': proposed.snapshot.device.expected,
      'tableFingerprint': proposed.snapshot.tableFingerprint,
      'esp': proposed.esp.choice.json,
      'root': proposed.root.choice.json,
    });
    if (!exactFields(result, {
          'protocolVersion',
          'type',
          'operation',
          'ok',
          'plan',
        }) ||
        !samePlanValue(result['plan'], proposed.intentJson)) {
      throw const HelperException('PROTOCOL_ERROR');
    }
    return proposed;
  }

  Future<NtfsShrinkAssessment> assessNtfsShrink({
    required GptDiskSnapshot snapshot,
    required int sourceNumber,
    required int espNumber,
    required int rootBytes,
  }) async {
    if (protocolVersion != 2) throw const HelperException('INVALID_REQUEST');
    try {
      // A structural check only; the helper must independently inspect NTFS.
      NtfsShrinkInstallationPlan.build(
        snapshot: snapshot,
        sourceNumber: sourceNumber,
        espNumber: espNumber,
        rootBytes: rootBytes,
        minimumFilesystemBytes: 1,
      );
    } on FormatException {
      throw const HelperException('INVALID_REQUEST');
    }
    final result = await _call({
      'protocolVersion': 2,
      'operation': 'assess-ntfs-shrink',
      'disk': snapshot.device.path,
      'expectedDevice': snapshot.device.expected,
      'tableFingerprint': snapshot.tableFingerprint,
      'sourceNumber': sourceNumber,
      'espNumber': espNumber,
      'rootBytes': rootBytes,
    });
    try {
      if (!exactFields(result, {
        'protocolVersion',
        'type',
        'operation',
        'ok',
        'plan',
        'inspection',
      })) {
        throw const FormatException('Invalid assessment result');
      }
      return NtfsShrinkAssessment.fromJson(
        {'plan': result['plan'], 'inspection': result['inspection']},
        snapshot: snapshot,
        sourceNumber: sourceNumber,
        espNumber: espNumber,
        rootBytes: rootBytes,
      );
    } on FormatException {
      throw const HelperException('PROTOCOL_ERROR');
    }
  }

  Future<void> installManualPlan(
    ManualInstallationPlan plan,
    void Function(double, String) onProgress, {
    String? uiLanguage,
    void Function(CopyProgress)? onCopyProgress,
    void Function(SessionReport?, String)? onReport,
  }) async {
    if (protocolVersion != 2 ||
        uiLanguage != null && !installerUiLanguages.contains(uiLanguage)) {
      throw const HelperException('INVALID_REQUEST');
    }
    final result = await _call(
      {
        'protocolVersion': 2,
        'operation': 'install-manual',
        'disk': plan.snapshot.device.path,
        'expectedDevice': plan.snapshot.device.expected,
        'confirmDestructive': true,
        'confirmedPlan': plan.intentJson,
        'uiLanguage': ?uiLanguage,
        if (onCopyProgress != null) 'includeCopyProgress': true,
      },
      onProgress: onProgress,
      onCopyProgress: onCopyProgress,
      onReport: onReport,
    );
    if (!exactFields(result, {
          'protocolVersion',
          'type',
          'operation',
          'ok',
          'installed',
        }) ||
        result['installed'] != true) {
      throw const HelperException('PROTOCOL_ERROR');
    }
  }

  Future<void> installWithReport(
    DeviceIdentity identity,
    void Function(double, String) onProgress, {
    void Function(SessionReport? report, String status)? onReport,
    String? uiLanguage,
    void Function(CopyProgress)? onCopyProgress,
    ApprovedFullDiskPlan? confirmedPlan,
  }) async {
    if ((confirmedPlan != null &&
            (protocolVersion != 2 ||
                !samePlanValue(confirmedPlan.device.json, identity.json))) ||
        (onCopyProgress != null && protocolVersion != 2) ||
        uiLanguage != null &&
            (protocolVersion != 2 ||
                !installerUiLanguages.contains(uiLanguage))) {
      throw const HelperException('INVALID_REQUEST');
    }
    final result = await _call(
      {
        ...identity.installRequest,
        'protocolVersion': protocolVersion,
        'uiLanguage': ?uiLanguage,
        if (onCopyProgress != null) 'includeCopyProgress': true,
        if (confirmedPlan != null) 'confirmedPlan': confirmedPlan.json,
      },
      onProgress: onProgress,
      onReport: onReport,
      onCopyProgress: onCopyProgress,
    );
    if (!exactFields(result, {
          'protocolVersion',
          'type',
          'operation',
          'ok',
          'installed',
        }) ||
        result['installed'] != true) {
      throw const HelperException('PROTOCOL_ERROR');
    }
  }

  Future<void> installFreeSpace(
    FreeSpaceInstallationPlan plan,
    void Function(double, String) onProgress, {
    String? uiLanguage,
    void Function(CopyProgress)? onCopyProgress,
    void Function(SessionReport?, String)? onReport,
  }) async {
    if (protocolVersion != 2 ||
        plan.snapshot.partitions.length > 30 ||
        (uiLanguage != null && !installerUiLanguages.contains(uiLanguage))) {
      throw const HelperException('INVALID_REQUEST');
    }
    final result = await _call(
      {
        'protocolVersion': 2,
        'operation': 'install-free-space',
        'disk': plan.snapshot.device.path,
        'expectedDevice': plan.snapshot.device.expected,
        'confirmDestructive': true,
        'confirmedPlan': plan.intentJson,
        'uiLanguage': ?uiLanguage,
        if (onCopyProgress != null) 'includeCopyProgress': true,
      },
      onProgress: onProgress,
      onCopyProgress: onCopyProgress,
      onReport: onReport,
    );
    if (!exactFields(result, {
          'protocolVersion',
          'type',
          'operation',
          'ok',
          'installed',
        }) ||
        result['installed'] != true) {
      throw const HelperException('PROTOCOL_ERROR');
    }
  }

  Future<Map<String, dynamic>> _call(
    Map<String, dynamic> request, {
    void Function(double, String)? onProgress,
    void Function(SessionReport? report, String status)? onReport,
    void Function(CopyProgress)? onCopyProgress,
  }) async {
    if (protocolVersion != 1 && protocolVersion != 2) {
      throw const HelperException('INVALID_REQUEST');
    }
    final installing = const [
      'install-full-disk',
      'install-free-space',
      'install-manual',
    ].contains(request['operation']);
    var reportSeen = false;
    var currentStage = 0;
    CopyProgress? lastCopy;
    SessionReport? report;
    var reportStatus = 'unavailable';
    var reportNotified = false;
    void notifyReport(SessionReport? value, String status) {
      if (reportNotified || protocolVersion != 2 || !installing) return;
      reportNotified = true;
      try {
        onReport?.call(value, status);
      } catch (_) {}
    }

    HelperProcess process;
    try {
      process = await _start(
        executable,
        List.unmodifiable(
          protocolVersion == 1
              ? arguments
              : [...arguments.take(2), '--protocol=2'],
        ),
      );
    } catch (_) {
      throw const HelperException('PKEXEC_UNAVAILABLE');
    }
    Map<String, dynamic>? result;
    String? failure;
    var outputBytes = 0;
    var stderrBytes = 0;
    var messages = 0;
    final pending = <int>[];
    final output = StreamIterator(process.output);
    var outputEnded = false;
    var diagnosticsEnded = false;
    final elapsed = Stopwatch()..start();
    final diagnostics = process.diagnostics.listen(
      (chunk) {
        stderrBytes += chunk.length;
        if (stderrBytes > 65536) failure ??= 'OUTPUT_LIMIT';
        // Never retain or forward pkexec/backend stderr, including secrets.
      },
      onError: (_) {
        failure ??= 'TRANSPORT_ERROR';
      },
      onDone: () => diagnosticsEnded = true,
    );
    try {
      process.send('${jsonEncode(request)}\n');
      await process.closeInput();
      while (await (installing
          ? output.moveNext()
          : output.moveNext().timeout(readTimeout - elapsed.elapsed))) {
        final chunk = output.current;
        outputBytes += chunk.length;
        if (outputBytes > helperOutputLimit) failure ??= 'OUTPUT_LIMIT';
        if (failure != null) continue;
        for (final byte in chunk) {
          if (byte != 10) {
            if (pending.length >= helperLineLimit) {
              failure = 'OUTPUT_LIMIT';
              break;
            }
            pending.add(byte);
            continue;
          }
          try {
            final message = decodeProtocolObject(utf8.decode(pending));
            pending.clear();
            messages++;
            if (messages > 16384 ||
                result != null ||
                message['protocolVersion'] is! int ||
                message['protocolVersion'] != protocolVersion) {
              throw const FormatException();
            }
            if (message['type'] == 'session-report' &&
                installing &&
                protocolVersion == 2) {
              if (reportSeen ||
                  !exactFields(message, {
                    'protocolVersion',
                    'type',
                    'status',
                    'report',
                  }) ||
                  !const [
                    'available',
                    'invalid',
                    'unavailable',
                  ].contains(message['status'])) {
                throw const FormatException();
              }
              reportSeen = true;
              report = SessionReport.parse(message['report']);
              reportStatus = message['status'] == 'available' && report != null
                  ? 'available'
                  : message['status'] == 'unavailable'
                  ? 'unavailable'
                  : 'invalid';
            } else if (message['type'] == 'copy-progress' && installing) {
              if (reportSeen ||
                  protocolVersion != 2 ||
                  onCopyProgress == null) {
                throw const FormatException('Unexpected copy progress');
              }
              final copy = CopyProgress.fromJson(message);
              if (currentStage != 5 ||
                  (lastCopy?.phase == 'efi' && copy.phase == 'main') ||
                  (lastCopy?.phase == copy.phase &&
                      copy.bytesProcessed < lastCopy!.bytesProcessed)) {
                throw const FormatException('Out-of-order copy progress');
              }
              lastCopy = copy;
              try {
                onCopyProgress(copy);
              } catch (_) {}
            } else if (message['type'] == 'progress' && installing) {
              if (reportSeen) throw const FormatException();
              validateProgress(message, expectedVersion: protocolVersion);
              currentStage = message['stage'];
              onProgress?.call(
                (message['progress'] as num).toDouble(),
                message['messageKey'] as String,
              );
            } else if (message['type'] == 'result' &&
                message['operation'] == request['operation'] &&
                message['ok'] is bool) {
              if (message['ok'] == false) {
                final error = message['error'];
                if (!exactFields(message, {
                      'protocolVersion',
                      'type',
                      'operation',
                      'ok',
                      'error',
                    }) ||
                    error is! Map<String, dynamic> ||
                    !exactFields(error, {'code', 'message'}) ||
                    error['code'] is! String ||
                    !helperErrorCodes.contains(error['code']) ||
                    error['message'] is! String ||
                    error['message'].length > 512) {
                  throw const FormatException();
                }
              }
              result = message;
            } else {
              throw const FormatException();
            }
          } catch (_) {
            failure = 'PROTOCOL_ERROR';
            break;
          }
        }
      }
      outputEnded = true;
      final status = await process.exitCode.timeout(const Duration(seconds: 5));
      if (failure != null) throw HelperException(failure!);
      if (pending.isNotEmpty) throw const HelperException('PROTOCOL_ERROR');
      if (result == null) {
        if (status == 126) throw const HelperException('AUTH_CANCELLED');
        if (status == 127) throw const HelperException('AUTH_DENIED');
        throw HelperException(status == 0 ? 'PROTOCOL_ERROR' : 'HELPER_FAILED');
      }
      notifyReport(
        result['ok'] == false || status == 0 ? report : null,
        result['ok'] == false || status == 0 ? reportStatus : 'unavailable',
      );
      if (result['ok'] == false) {
        throw HelperException(result['error']['code']);
      }
      if (status != 0) throw const HelperException('HELPER_FAILED');
      return result;
    } on TimeoutException {
      if (!installing) process.terminate();
      throw const HelperException('TIMEOUT');
    } on HelperException {
      rethrow;
    } catch (_) {
      throw const HelperException('TRANSPORT_ERROR');
    } finally {
      notifyReport(null, 'unavailable');
      // EOF already releases the stream subscription. Only cancel streams
      // that are still live (including timeout/error exits).
      if (!outputEnded) await output.cancel();
      if (!diagnosticsEnded) await diagnostics.cancel();
    }
    // Install streams have no GUI-driven termination/cancellation: the helper
    // owns the two-hour backend watchdog and retains the lock through exit.
  }
}
