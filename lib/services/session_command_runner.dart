import 'dart:convert';
import 'dart:io';
import 'command_runner.dart';

/// Internal root-to-root transport, never part of the GUI/helper protocol.
/// The root supervisor verifies SO_PEERCRED against its exact engine child.
class SessionCommandRunner extends CommandRunner {
  SessionCommandRunner(this.socketPath);
  final String socketPath;
  static SessionCommandRunner? fromEnvironment() {
    final path = Platform.environment['RO_INSTALLER_SESSION_SOCKET'];
    if (path == null ||
        !RegExp(
          r'^/run/ro-installer/session-[a-zA-Z0-9_-]+/commands\.sock$',
        ).hasMatch(path)) {
      return null;
    }
    return SessionCommandRunner(path);
  }

  Stream<Map<String, dynamic>> _exchange(Map<String, dynamic> request) async* {
    final socket = await Socket.connect(
      InternetAddress(socketPath, type: InternetAddressType.unix),
      0,
    );
    try {
      socket.write('${jsonEncode(request)}\n');
      await socket.flush();
      await for (final line
          in socket
              .cast<List<int>>()
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
        final value = jsonDecode(line);
        if (value is! Map<String, dynamic> || value.containsKey('error')) {
          throw const FormatException('Session rejected request');
        }
        yield value;
      }
    } finally {
      socket.destroy();
    }
  }

  Future<Map<String, dynamic>> control(Map<String, dynamic> request) async {
    final rows = await _exchange(request).toList();
    if (rows.length != 1) {
      throw const FormatException('Invalid session response');
    }
    return rows.single;
  }

  @override
  Future<CommandResult> run(
    String command,
    List<String> args, {
    bool isMock = false,
    CommandLogCallback? onLog,
    Duration? timeout,
    String? stdinText,
  }) async {
    if (isMock) {
      throw StateError('Production session cannot execute mock requests');
    }
    final captured = BoundedCommandOutput(
      rsync: command.split('/').last == 'rsync',
    );
    void log(String stream, String text) {
      final value = text.trim();
      if (value.isEmpty) return;
      onLog?.call(
        CommandLogEvent(
          type: stream == 'stdout'
              ? CommandLogType.stdout
              : CommandLogType.stderr,
          command: command,
          args: List.unmodifiable(args),
          message: SecretRedactor.redactText(value),
        ),
      );
    }

    onLog?.call(
      CommandLogEvent(
        type: CommandLogType.command,
        command: command,
        args: List.unmodifiable(args),
        message: SecretRedactor.redactCommandLine(command, args),
      ),
    );
    Map<String, dynamic>? result;
    try {
      await for (final event in _exchange({
        'op': 'command',
        'command': command,
        'args': args,
        'stdin': stdinText,
        'timeoutMs': timeout?.inMilliseconds,
      })) {
        if (result != null) {
          throw const FormatException('Events after completion');
        }
        if (event['stream'] is String &&
            const ['stdout', 'stderr'].contains(event['stream']) &&
            event['data'] is String) {
          final name = event['stream'] as String;
          final data = event['data'] as String;
          captured.add(name, data, log);
        } else if (event['started'] is bool && event['exitCode'] is int) {
          result = event;
        } else {
          throw const FormatException('Invalid command event');
        }
      }
      if (result == null) throw const FormatException('Missing command result');
      captured.finish(log);
      if (captured.overflow) {
        // Functional transport overflow is a fail-closed input error, not a
        // telemetry failure. Actual subprocess exit stays in supervisor events.
        try {
          await control({
            'op': 'observe',
            'event': {
              'eventType': 'capture.failed',
              'stageId': null,
              'operationId': 'unclassified',
              'status': 'failed',
              'durationMs': 0,
              'exitCode': null,
              'errorCode': 'COMMAND_OUTPUT_LIMIT',
            },
          }).timeout(const Duration(milliseconds: 500));
        } catch (_) {}
      }
      return CommandResult(
        command: command,
        args: List.unmodifiable(args),
        started: result['started'],
        exitCode: captured.overflow ? -126 : result['exitCode'],
        stdout: captured.overflow ? '' : captured.value('stdout'),
        stderr: captured.overflow
            ? 'COMMAND_OUTPUT_LIMIT'
            : captured.value('stderr'),
      );
    } catch (_) {
      return CommandResult(
        command: command,
        args: List.unmodifiable(args),
        started: false,
        exitCode: -1,
        stdout: '',
        stderr: 'Isolated installer session transport failed.',
      );
    }
  }
}
