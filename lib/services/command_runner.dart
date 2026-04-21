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
  });
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
  }) async {
    onLog?.call(
      CommandLogEvent(
        type: CommandLogType.command,
        command: command,
        args: List.unmodifiable(args),
        message: [command, ...args].join(' ').trim(),
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
        command: command,
        args: List.unmodifiable(args),
        exitCode: 0,
        stdout: '',
        stderr: '',
        started: true,
      );
    }

    try {
      final process = await Process.start(command, args);
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
              command: command,
              args: List.unmodifiable(args),
              message: trimmed,
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
              command: command,
              args: List.unmodifiable(args),
              message: trimmed,
            ),
          );
        },
        onDone: () => stderrDone.complete(),
        onError: (_) => stderrDone.complete(),
        cancelOnError: false,
      );

      final exitCode = await process.exitCode;
      await stdoutDone.future;
      await stderrDone.future;

      return CommandResult(
        command: command,
        args: List.unmodifiable(args),
        exitCode: exitCode,
        stdout: stdoutBuffer.toString().trim(),
        stderr: stderrBuffer.toString().trim(),
        started: true,
      );
    } catch (e) {
      return CommandResult(
        command: command,
        args: List.unmodifiable(args),
        exitCode: -1,
        stdout: '',
        stderr: e.toString(),
        started: false,
      );
    }
  }
}
