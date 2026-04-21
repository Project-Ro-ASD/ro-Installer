import 'command_runner.dart';

/// Test ortamında kullanılmak üzere sahte komut çalıştırıcı.
///
/// Gerçek sistem komutları çalıştırmak yerine, önceden tanımlanmış
/// çıktıları döndürür. Bu sayede:
///   - Testler donanım gerektirmez
///   - Hata senaryoları simüle edilebilir
///   - Hangi komutların çağrıldığı doğrulanabilir
///
/// Kullanım:
/// ```dart
/// final fake = FakeCommandRunner();
/// fake.addResponse('lsblk', ['-J', '-b'], stdout: '{"blockdevices":[]}');
/// fake.addResponse('sgdisk', ['-Z', '/dev/sda'], exitCode: 1, stderr: 'Hata');
///
/// CommandRunner.setInstance(fake);
/// // ... testleri çalıştır ...
/// expect(fake.commandLog.length, 2);
/// ```
class FakeCommandRunner extends CommandRunner {
  /// Komut eşleşmesi için önceden tanımlanmış yanıtlar.
  /// Anahtar: "komut arg1 arg2 ..." şeklinde birleştirilmiş komut satırı
  final Map<String, List<_FakeResponse>> _responses = {};

  /// Çağrılan tüm komutların sıralı kaydı.
  /// Test sonunda doğrulama için kullanılır.
  final List<RecordedCommand> commandLog = [];

  /// Yanıt bulunamadığında döndürülecek varsayılan davranış.
  /// `true` ise başarılı (exitCode: 0) döner, `false` ise hata fırlatır.
  final bool defaultSuccess;

  FakeCommandRunner({this.defaultSuccess = true});

  /// Belirli bir komut + argüman kombinasyonu için yanıt tanımlar.
  ///
  /// [command]: Çalıştırılacak komut adı (ör: 'lsblk')
  /// [args]: Beklenen argümanlar (boş bırakılırsa sadece komut adı eşleşir)
  /// [stdout]: Döndürülecek standart çıktı
  /// [stderr]: Döndürülecek hata çıktısı
  /// [exitCode]: Döndürülecek çıkış kodu (0 = başarılı)
  /// [started]: Komutun başlatılıp başlatılamadığı (false = komut bulunamadı)
  void addResponse(
    String command,
    List<String> args, {
    String stdout = '',
    String stderr = '',
    int exitCode = 0,
    bool started = true,
  }) {
    final key = _makeKey(command, args);
    _responses.putIfAbsent(key, () => []);
    _responses[key]!.add(_FakeResponse(
      stdout: stdout,
      stderr: stderr,
      exitCode: exitCode,
      started: started,
    ));
  }

  /// Sadece komut adına göre yanıt tanımlar (argümanlara bakılmaz).
  /// Daha genel eşleşme için kullanılır.
  void addResponseForCommand(
    String command, {
    String stdout = '',
    String stderr = '',
    int exitCode = 0,
    bool started = true,
  }) {
    final key = 'CMD:$command';
    _responses.putIfAbsent(key, () => []);
    _responses[key]!.add(_FakeResponse(
      stdout: stdout,
      stderr: stderr,
      exitCode: exitCode,
      started: started,
    ));
  }

  /// Dosyadan fixture yükleyerek yanıt tanımlar.
  void addResponseFromFixture(
    String command,
    List<String> args, {
    required String fixtureContent,
    int exitCode = 0,
  }) {
    addResponse(command, args, stdout: fixtureContent, exitCode: exitCode);
  }

  /// Tüm kayıtlı yanıtları ve komut günlüğünü temizler.
  void reset() {
    _responses.clear();
    commandLog.clear();
  }

  /// Belirli bir komutun çağrılıp çağrılmadığını kontrol eder.
  bool wasCommandCalled(String command) {
    return commandLog.any((c) => c.command == command);
  }

  /// Belirli bir komut + argüman kombinasyonunun çağrılıp çağrılmadığını kontrol eder.
  bool wasCalledWith(String command, List<String> args) {
    final key = _makeKey(command, args);
    return commandLog.any((c) => _makeKey(c.command, c.args) == key);
  }

  /// Komutların çağrılma sırasını döndürür (sadece komut adları).
  List<String> get commandNames => commandLog.map((c) => c.command).toList();

  @override
  Future<CommandResult> run(
    String command,
    List<String> args, {
    bool isMock = false,
    CommandLogCallback? onLog,
  }) async {
    // Komutu kaydet
    commandLog.add(RecordedCommand(command: command, args: List.unmodifiable(args)));

    // Log callback'i tetikle
    onLog?.call(
      CommandLogEvent(
        type: CommandLogType.command,
        command: command,
        args: List.unmodifiable(args),
        message: [command, ...args].join(' ').trim(),
      ),
    );

    // Yanıt ara: önce tam eşleşme, sonra sadece komut adı
    final exactKey = _makeKey(command, args);
    final cmdKey = 'CMD:$command';
    final response = _takeResponse(exactKey) ?? _takeResponse(cmdKey);

    if (response != null) {
      // Stdout log callback
      if (response.stdout.isNotEmpty) {
        for (final line in response.stdout.split('\n')) {
          if (line.trim().isEmpty) continue;
          onLog?.call(
            CommandLogEvent(
              type: CommandLogType.stdout,
              command: command,
              args: List.unmodifiable(args),
              message: line.trim(),
            ),
          );
        }
      }

      // Stderr log callback
      if (response.stderr.isNotEmpty) {
        for (final line in response.stderr.split('\n')) {
          if (line.trim().isEmpty) continue;
          onLog?.call(
            CommandLogEvent(
              type: CommandLogType.stderr,
              command: command,
              args: List.unmodifiable(args),
              message: line.trim(),
            ),
          );
        }
      }

      return CommandResult(
        command: command,
        args: List.unmodifiable(args),
        exitCode: response.exitCode,
        stdout: response.stdout,
        stderr: response.stderr,
        started: response.started,
      );
    }

    // Tanımlanmamış komut — varsayılan davranış
    if (defaultSuccess) {
      return CommandResult(
        command: command,
        args: List.unmodifiable(args),
        exitCode: 0,
        stdout: '',
        stderr: '',
        started: true,
      );
    } else {
      throw StateError(
        'FakeCommandRunner: Tanımlanmamış komut çağrıldı: '
        '$command ${args.join(" ")}\n'
        'Tanımlı yanıtlar: ${_responses.keys.join(", ")}',
      );
    }
  }

  /// Komut + argümanları tekil bir anahtar stringine çevirir.
  String _makeKey(String command, List<String> args) {
    return [command, ...args].join(' ').trim();
  }

  _FakeResponse? _takeResponse(String key) {
    final queue = _responses[key];
    if (queue == null || queue.isEmpty) {
      return null;
    }
    final response = queue.removeAt(0);
    if (queue.isEmpty) {
      _responses.remove(key);
    }
    return response;
  }
}

/// Önceden tanımlanmış sahte komut yanıtı.
class _FakeResponse {
  final String stdout;
  final String stderr;
  final int exitCode;
  final bool started;

  const _FakeResponse({
    required this.stdout,
    required this.stderr,
    required this.exitCode,
    required this.started,
  });
}

/// Çağrılan bir komutun kaydı.
class RecordedCommand {
  final String command;
  final List<String> args;

  const RecordedCommand({required this.command, required this.args});

  String get commandLine => [command, ...args].join(' ').trim();

  @override
  String toString() => commandLine;
}
