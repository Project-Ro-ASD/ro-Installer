import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'session_command_runner.dart';

enum CommandLogType { command, stdout, stderr, mock }

class CommandLogEvent {
  const CommandLogEvent({
    required this.type,
    required this.command,
    required this.args,
    required this.message,
  });

  final CommandLogType type;
  final String command;
  final List<String> args;
  final String message;

  String get displayMessage {
    switch (type) {
      case CommandLogType.command:
        return '[KOMUT] $message';
      case CommandLogType.stdout:
        return message;
      case CommandLogType.stderr:
        return '[STDERR] $message';
      case CommandLogType.mock:
        return '[MOCK] $message';
    }
  }
}

class CommandResult {
  const CommandResult({
    required this.command,
    required this.args,
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    required this.started,
  });

  final String command;
  final List<String> args;
  final int exitCode;
  final String stdout;
  final String stderr;
  final bool started;

  String get commandLine => [command, ...args].join(' ').trim();

  String get displayCommandLine =>
      SecretRedactor.redactCommandLine(command, args);
}

typedef CommandLogCallback = void Function(CommandLogEvent event);

/// CommandRunner soyut sınıfı.
///
/// Tüm servisler bu arayüz üzerinden komut çalıştırır.
/// Üretimde [RealCommandRunner], testlerde [FakeCommandRunner] kullanılır.
///
/// Kullanım:
///   CommandRunner.instance         → mevcut aktif runner'a erişir
///   CommandRunner.setInstance(...)  → test ortamında runner değiştirir
abstract class CommandRunner {
  /// Mevcut aktif CommandRunner.
  /// Varsayılan olarak [RealCommandRunner] kullanılır.
  /// Test ortamında [setInstance] ile değiştirilebilir.
  static CommandRunner _instance = _defaultRunner();
  static CommandRunner _defaultRunner() =>
      SessionCommandRunner.fromEnvironment() ?? RealCommandRunner();
  static CommandRunner get instance => _instance;

  /// Test veya özel senaryolarda runner'ı değiştirmek için kullanılır.
  /// Üretim kodunda çağrılmamalıdır.
  static void setInstance(CommandRunner runner) {
    _instance = runner;
  }

  /// Runner'ı varsayılan [RealCommandRunner]'a geri döndürür.
  static void resetInstance() {
    _instance = _defaultRunner();
  }

  /// Verilen komutu çalıştırır ve sonucu döndürür.
  Future<CommandResult> run(
    String command,
    List<String> args, {
    bool isMock = false,
    CommandLogCallback? onLog,
    Duration? timeout,
    String? stdinText,
  });
}

class SecretRedactor {
  SecretRedactor._();
  static const _aliases = {
    'password',
    'passwd',
    'passphrase',
    'passwordhash',
    'token',
    'accesstoken',
    'refreshtoken',
    'idtoken',
    'apikey',
    'accesskey',
    'accesskeyid',
    'secretaccesskey',
    'secret',
    'clientsecret',
    'authorization',
    'credential',
    'credentials',
    'psk',
    'privatekey',
    'sessiontoken',
    'auth',
    'signature',
  };
  static bool isSecretKey(String key) {
    var normalized = key.toLowerCase();
    try {
      for (var i = 0; i < 2; i++) {
        normalized = Uri.decodeComponent(normalized);
      }
    } catch (_) {}
    normalized = normalized.replaceAll(RegExp(r'[^a-z0-9]'), '');
    return _aliases.contains(normalized) ||
        normalized.endsWith('password') ||
        normalized.endsWith('passphrase') ||
        normalized.endsWith('token') ||
        normalized.endsWith('secret') ||
        normalized.endsWith('apikey') ||
        normalized.endsWith('accesskey') ||
        normalized.endsWith('signature') ||
        normalized.endsWith('credential') ||
        normalized.endsWith('secretkey') ||
        normalized == 'pwd';
  }

  static dynamic _json(dynamic value) {
    if (value is Map) {
      return {
        for (final e in value.entries)
          e.key.toString(): isSecretKey(e.key.toString())
              ? '***'
              : _json(e.value),
      };
    }
    if (value is List) return value.map(_json).toList();
    if (value is String) return _text(value);
    return value;
  }

  static String redactCommandLine(String command, List<String> args) {
    final safe = <String>[];
    var hide = false;
    for (final arg in args) {
      if (hide) {
        safe.add('***');
        hide = false;
        continue;
      }
      final parts = arg.split('=');
      if (isSecretKey(parts.first)) {
        if (parts.length > 1) {
          safe.add('${parts.first}=***');
        } else {
          safe.add(arg);
          hide = true;
        }
      } else {
        safe.add(redactText(arg));
      }
    }
    return redactText([command, ...safe].join(' '));
  }

  static String redactText(String raw) {
    // Public free-text export is bounded. Structured telemetry never uses this
    // as its security boundary: it accepts only typed allowlisted fields.
    final bounded = raw.length > 65536 ? raw.substring(0, 65536) : raw;
    try {
      return jsonEncode(_json(jsonDecode(bounded)));
    } catch (_) {}
    return _text(bounded);
  }

  static String _text(String raw) {
    var line = raw
        .replaceAll(r'\"', '"')
        .replaceAllMapped(
          RegExp(r'\u([0-9a-fA-F]{4})'),
          (m) => String.fromCharCode(int.parse(m[1]!, radix: 16)),
        );
    line = line.replaceAllMapped(RegExp(r'''https?://[^\s<>"']+'''), (match) {
      try {
        final uri = Uri.parse(match[0]!);
        final query = <String, dynamic>{};
        for (final e in uri.queryParametersAll.entries) {
          query[e.key] =
              isSecretKey(e.key) ||
                  const ['code', 'key', 'sig'].contains(e.key.toLowerCase())
              ? '***'
              : e.value;
        }
        return uri
            .replace(
              userInfo: uri.userInfo.isEmpty ? '' : '***',
              queryParameters: uri.hasQuery ? query : null,
            )
            .toString();
      } catch (_) {
        return '[URL_REDACTED]';
      }
    });
    line = line.replaceAllMapped(
      RegExp(
        r'''(["'])([A-Za-z0-9_.-]+)\1\s*:\s*("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|[^,\s}\]]+)''',
      ),
      (m) => isSecretKey(m[2]!) ? '${m[1]}${m[2]}${m[1]}:"***"' : m[0]!,
    );
    line = line.replaceAllMapped(
      RegExp(
        r'''(?<![A-Za-z0-9_])((?:--)?(?:password|passwd|passphrase|passwordHash|api[_-]?key|access[_-]?key(?:[_-]?id)?|secret[_-]?access[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret|token|secret|authorization|credential|802-1x\.password|wifi-sec\.psk))\s*(?:=|:|\s)\s*(?:"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|[^\r\n]*)''',
        caseSensitive: false,
      ),
      (m) => '${m[1]} ***',
    );
    if (line.toLowerCase().contains('chpasswd')) {
      line = line.replaceAll(
        RegExp(r'''[a-z_][a-z0-9_-]*:[^\s'"|]+''', caseSensitive: false),
        '***:***',
      );
    }
    line = line.replaceAll(
      RegExp(r'''root:[^\s'"|]+''', caseSensitive: false),
      'root:***',
    );
    return line;
  }
}

/// Functional output retention, independent of the record-store quota. Parsed
/// output is never silently truncated: callers receive -126 on overflow. Rsync
/// output is not parsed by FileCopyStage; its actual exit code stays authoritative.
class BoundedCommandOutput {
  BoundedCommandOutput({this.rsync = false});
  final bool rsync;
  final _output = {'stdout': StringBuffer(), 'stderr': StringBuffer()};
  final _pending = {'stdout': '', 'stderr': ''};
  final _discardLine = {'stdout': false, 'stderr': false};
  bool overflow = false;
  String value(String name) => _output[name].toString().trim();
  void add(String name, String text, void Function(String, String) log) {
    final buffer = _output[name]!;
    final limit = name == 'stderr' || rsync ? 65536 : 1024 * 1024;
    final remaining = limit - buffer.length;
    if (remaining > 0) {
      buffer.write(
        text.length > remaining ? text.substring(0, remaining) : text,
      );
    }
    if (name == 'stdout' && !rsync && text.length > remaining) overflow = true;
    for (final line in text.split(RegExp(r'[\r\n]')).asMap().entries) {
      if (line.key > 0) {
        if (!_discardLine[name]! && _pending[name]!.isNotEmpty) {
          log(name, _pending[name]!);
        }
        _pending[name] = '';
        _discardLine[name] = false;
      }
      if (!_discardLine[name]!) {
        if (_pending[name]!.length + line.value.length > 8192) {
          _pending[name] = '';
          _discardLine[name] = true;
        } else {
          _pending[name] = '${_pending[name]}${line.value}';
        }
      }
    }
  }

  void finish(void Function(String, String) log) {
    for (final name in _pending.keys) {
      if (!_discardLine[name]! && _pending[name]!.isNotEmpty) {
        log(name, _pending[name]!);
      }
    }
  }
}

/// Gerçek sistem komutları çalıştıran CommandRunner uygulaması.
///
/// [Process.start] kullanarak komutları çalıştırır,
/// stdout/stderr akışlarını dinler ve sonucu döndürür.
class RealCommandRunner extends CommandRunner {
  @override
  Future<CommandResult> run(
    String command,
    List<String> args, {
    bool isMock = false,
    CommandLogCallback? onLog,
    Duration? timeout,
    String? stdinText,
  }) async {
    final runCommand = command;
    final runArgs = List<String>.unmodifiable(args);

    onLog?.call(
      CommandLogEvent(
        type: CommandLogType.command,
        command: runCommand,
        args: List.unmodifiable(runArgs),
        message: SecretRedactor.redactCommandLine(runCommand, runArgs),
      ),
    );

    if (isMock) {
      await Future.delayed(const Duration(milliseconds: 300));
      onLog?.call(
        CommandLogEvent(
          type: CommandLogType.mock,
          command: command,
          args: List.unmodifiable(args),
          message: 'Simülasyon başarılı: $command',
        ),
      );
      return CommandResult(
        command: runCommand,
        args: List.unmodifiable(runArgs),
        exitCode: 0,
        stdout: '',
        stderr: '',
        started: true,
      );
    }

    try {
      final process = await Process.start(runCommand, runArgs);
      if (stdinText != null) {
        process.stdin.write(stdinText);
        await process.stdin.close();
      }
      final captured = BoundedCommandOutput(
        rsync: runCommand.split('/').last == 'rsync',
      );
      final stdoutDone = Completer<void>();
      final stderrDone = Completer<void>();
      void log(String name, String line) {
        onLog?.call(
          CommandLogEvent(
            type: name == 'stdout'
                ? CommandLogType.stdout
                : CommandLogType.stderr,
            command: runCommand,
            args: runArgs,
            message: SecretRedactor.redactText(line),
          ),
        );
      }

      for (final name in ['stdout', 'stderr']) {
        final complete = name == 'stdout' ? stdoutDone : stderrDone;
        (name == 'stdout' ? process.stdout : process.stderr)
            .transform(utf8.decoder)
            .listen(
              (text) => captured.add(name, text, log),
              onDone: () => complete.complete(),
              onError: (_) => complete.complete(),
              cancelOnError: false,
            );
      }
      final timeoutDetail = StringBuffer();
      final exitCode = await _waitForExit(process, timeout, timeoutDetail);
      await _waitForStreams(stdoutDone, stderrDone);
      captured.finish(log);
      return CommandResult(
        command: runCommand,
        args: List.unmodifiable(runArgs),
        exitCode: captured.overflow ? -126 : exitCode,
        stdout: captured.overflow ? '' : captured.value('stdout'),
        stderr: captured.overflow
            ? 'COMMAND_OUTPUT_LIMIT'
            : timeoutDetail.isNotEmpty
            ? timeoutDetail.toString()
            : captured.value('stderr'),
        started: true,
      );
    } catch (e) {
      return CommandResult(
        command: runCommand,
        args: List.unmodifiable(runArgs),
        exitCode: -1,
        stdout: '',
        stderr: e.toString(),
        started: false,
      );
    }
  }

  Future<int> _waitForExit(
    Process process,
    Duration? timeout,
    StringBuffer stderrBuffer,
  ) async {
    if (timeout == null) {
      return process.exitCode;
    }

    try {
      return await process.exitCode.timeout(timeout);
    } on TimeoutException {
      stderrBuffer.writeln(
        'Command timed out after ${timeout.inSeconds}s; terminating process.',
      );
      process.kill(ProcessSignal.sigterm);
      try {
        await process.exitCode.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        process.kill(ProcessSignal.sigkill);
        try {
          await process.exitCode.timeout(const Duration(seconds: 2));
        } on TimeoutException {
          // The caller still receives a timeout result; stream draining below
          // is also bounded so the UI cannot remain blocked here.
        }
      }
      return -124;
    }
  }

  Future<void> _waitForStreams(
    Completer<void> stdoutDone,
    Completer<void> stderrDone,
  ) async {
    await Future.wait([
      stdoutDone.future,
      stderrDone.future,
    ]).timeout(const Duration(seconds: 2), onTimeout: () => <void>[]);
  }
}
