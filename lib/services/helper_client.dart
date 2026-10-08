import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'helper_protocol.dart';

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
  }) : _start = start ?? _startNative;
  static final instance = HelperClient();
  final HelperProcessStarter _start;
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
      'protocolVersion': 1,
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
  ) async {
    final result = await _call(identity.installRequest, onProgress: onProgress);
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
  }) async {
    final installing = request['operation'] == 'install-full-disk';
    HelperProcess process;
    try {
      process = await _start(executable, List.unmodifiable(arguments));
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
                message['protocolVersion'] != 1) {
              throw const FormatException();
            }
            if (message['type'] == 'progress' && installing) {
              validateProgress(message);
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
      final status = await process.exitCode.timeout(const Duration(seconds: 5));
      if (failure != null) throw HelperException(failure!);
      if (pending.isNotEmpty) throw const HelperException('PROTOCOL_ERROR');
      if (result == null) {
        if (status == 126) throw const HelperException('AUTH_CANCELLED');
        if (status == 127) throw const HelperException('AUTH_DENIED');
        throw HelperException(status == 0 ? 'PROTOCOL_ERROR' : 'HELPER_FAILED');
      }
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
      await output.cancel();
      await diagnostics.cancel();
    }
    // Install streams have no GUI-driven termination/cancellation: the helper
    // owns the two-hour backend watchdog and retains the lock through exit.
  }
}
