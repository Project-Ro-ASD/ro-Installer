import '../command_runner.dart';
import '../install_localizer.dart';

/// Tüm kurulum aşamalarının eriştiği ortak bağlam (context) nesnesi.
///
/// Her aşama bu nesne üzerinden:
/// - [state] ile kurulum yapılandırmasına erişir
/// - [runCmd] ile komut çalıştırır
/// - [log] ile teknik log yazar
/// - [onProgress] ile arayüze ilerleme bildirimi gönderir
/// - [isMock] ile simülasyon modunu kontrol eder
class StageContext {
  StageContext({
    required this.state,
    required this.log,
    required this.onProgress,
    required this.commandRunner,
    required this.runCmd,
    this.localizer = const InstallLocalizer(),
    this.isMock = false,
  });

  /// Kurulum yapılandırma verisi (disk, kullanıcı, timezone vb.)
  final Map<String, dynamic> state;

  /// Teknik log yazma fonksiyonu
  final void Function(String message) log;

  /// Arayüze ilerleme bildirimi gönderme fonksiyonu
  final void Function(double progress, String status) onProgress;

  /// Merkezi komut çalıştırıcı
  final CommandRunner commandRunner;

  /// InstallService'deki runCmd metodu — komut çalıştırır ve sonuca göre bool döndürür
  final Future<bool> Function(
    String cmd,
    List<String> args,
    void Function(String) onLog, {
    bool isMock,
    List<int> allowedExitCodes,
  })
  runCmd;

  /// Kurulum motoru metinlerini seçilen dile çevirir.
  final InstallLocalizer localizer;

  /// Simülasyon modu aktif mi
  final bool isMock;

  String t(
    String key,
    String fallback, [
    Map<String, String> placeholders = const {},
  ]) {
    return localizer.t(key, fallback, placeholders);
  }

  void progress(
    double progress,
    String key,
    String fallback, [
    Map<String, String> placeholders = const {},
  ]) {
    onProgress(progress, t(key, fallback, placeholders));
  }
}
