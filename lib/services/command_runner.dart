import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
  static CommandRunner _instance = RealCommandRunner();
  static CommandRunner get instance => _instance;

  /// Test veya özel senaryolarda runner'ı değiştirmek için kullanılır.
  /// Üretim kodunda çağrılmamalıdır.
  static void setInstance(CommandRunner runner) {
    _instance = runner;
  }

  /// Runner'ı varsayılan [RealCommandRunner]'a geri döndürür.
  static void resetInstance() {
    _instance = RealCommandRunner();
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

  static String redactCommandLine(String command, List<String> args) {
    return redactText([command, ...args].join(' ').trim());
  }

  static String redactText(String raw) {
    var line = raw;

    line = line.replaceAllMapped(
      RegExp(
        r'((?:^|\s)(?:password|passwd|passphrase|802-1x\.password)\s+)([^\s]+)',
        caseSensitive: false,
      ),
      (m) => '${m.group(1)}***',
    );

    line = line.replaceAllMapped(
      RegExp(
        r'((?:--)?(?:password|passwd|passphrase)=)([^\s]+)',
        caseSensitive: false,
      ),
      (m) => '${m.group(1)}***',
    );

    if (line.toLowerCase().contains('chpasswd')) {
      line = line.replaceAllMapped(
        RegExp(r'''(['"])[^'":\s]+:[^'"\s]+\1'''),
        (m) => '${m.group(1)}***:***${m.group(1)}',
      );
      line = line.replaceAllMapped(
        RegExp(r'''([a-z_][a-z0-9_-]*):([^\s'"]+)''', caseSensitive: false),
        (m) => '***:***',
      );
    }

    line = line.replaceAllMapped(
      RegExp(r'''(root:)([^\s'"]+)''', caseSensitive: false),
      (m) => '${m.group(1)}***',
    );

    return line;
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
    final commandLine = _effectiveCommandLine(command, args);
    final runCommand = commandLine.command;
    final runArgs = commandLine.args;

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
      final stdoutBuffer = StringBuffer();
      final stderrBuffer = StringBuffer();
      final stdoutDone = Completer<void>();
      final stderrDone = Completer<void>();

      process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            (line) {
              final trimmed = line.trim();
              if (trimmed.isEmpty) return;
              stdoutBuffer.writeln(trimmed);
              onLog?.call(
                CommandLogEvent(
                  type: CommandLogType.stdout,
                  command: runCommand,
                  args: List.unmodifiable(runArgs),
                  message: SecretRedactor.redactText(trimmed),
                ),
              );
            },
            onDone: () => stdoutDone.complete(),
            onError: (_) => stdoutDone.complete(),
            cancelOnError: false,
          );

      process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            (line) {
              final trimmed = line.trim();
              if (trimmed.isEmpty) return;
              stderrBuffer.writeln(trimmed);
              onLog?.call(
                CommandLogEvent(
                  type: CommandLogType.stderr,
                  command: runCommand,
                  args: List.unmodifiable(runArgs),
                  message: SecretRedactor.redactText(trimmed),
                ),
              );
            },
            onDone: () => stderrDone.complete(),
            onError: (_) => stderrDone.complete(),
            cancelOnError: false,
          );

      final exitCode = await _waitForExit(process, timeout, stderrBuffer);
      await _waitForStreams(stdoutDone, stderrDone);

      return CommandResult(
        command: runCommand,
        args: List.unmodifiable(runArgs),
        exitCode: exitCode,
        stdout: stdoutBuffer.toString().trim(),
        stderr: stderrBuffer.toString().trim(),
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

  _EffectiveCommandLine _effectiveCommandLine(
    String command,
    List<String> args,
  ) {
    if (!_shouldUseSudo(command)) {
      return _EffectiveCommandLine(command, List.unmodifiable(args));
    }
    return _EffectiveCommandLine(
      'sudo',
      List.unmodifiable(['-n', command, ...args]),
    );
  }

  bool _shouldUseSudo(String command) {
    final sudoModeRaw = Platform.environment['RO_INSTALLER_COMMAND_SUDO']
        ?.toLowerCase()
        .trim();
    final sudoMode = sudoModeRaw == '1' || sudoModeRaw == 'true';
    if (!sudoMode || _effectiveUid == 0) {
      return false;
    }

    final basename = command.split('/').last;
    return basename != 'sudo' && basename != 'pkexec' && basename != 'id';
  }

  static final int _effectiveUid = _readEffectiveUid();

  static int _readEffectiveUid() {
    try {
      final result = Process.runSync('id', ['-u']);
      return int.tryParse(result.stdout.toString().trim()) ?? -1;
    } catch (_) {
      return -1;
    }
  }
}

class _EffectiveCommandLine {
  const _EffectiveCommandLine(this.command, this.args);

  final String command;
  final List<String> args;
}
