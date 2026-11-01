import '../install_observation.dart';
import '../copy_progress.dart';
import '../helper_protocol.dart';
import '../../models/approved_full_disk_plan.dart';
import '../../models/approved_free_space_plan.dart';
import 'dart:convert';
import '../command_runner.dart';
import '../mount_session.dart';
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
    this.beforeFirstMutation,
    this.mountSession,
    this.observation,
    this.onCopyProgress,
    this.approvedPlan,
    this.approvedFreeSpacePlan,
  });

  /// Kurulum yapılandırma verisi (disk, storage layout, Installer UI language hint)
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
  final Future<void> Function()? beforeFirstMutation;
  final MountSession? mountSession;
  final InstallObservation? observation;
  final void Function(CopyProgress)? onCopyProgress;
  final ApprovedFullDiskPlan? approvedPlan;
  final ApprovedFreeSpacePlan? approvedFreeSpacePlan;
  CreatedFreeSpaceLayout? _createdFreeSpaceLayout;
  CreatedFreeSpaceLayout? get createdFreeSpaceLayout => _createdFreeSpaceLayout;
  void bindCreatedFreeSpaceLayout(CreatedFreeSpaceLayout layout) {
    if (approvedFreeSpacePlan == null ||
        !samePlanValue(approvedFreeSpacePlan!.json, layout.approved.json)) {
      throw const FormatException('Unowned storage layout');
    }
    mountSession?.bindCreatedFreeSpaceLayout(layout);
    _createdFreeSpaceLayout = layout;
  }

  bool get approvedStateMatches =>
      matchesApprovedPlan(state, expected: approvedPlan) &&
      (approvedFreeSpacePlan == null ||
          approvedFreeSpacePlan!.matchesState(state));
  bool get usesStandardStorage =>
      approvedStateMatches &&
      (state['fileSystem'] ?? 'btrfs') == 'btrfs' &&
      ((state['partitionMethod'] ?? 'full') == 'full' ||
          (state['partitionMethod'] == 'free_space' &&
              approvedFreeSpacePlan != null &&
              _createdFreeSpaceLayout != null &&
              approvedStateMatches));
  String _fullPartition(int number) {
    final disk = state['selectedDisk'] as String;
    return '$disk${disk.contains('nvme') || disk.contains('mmcblk') || disk.contains('loop') ? 'p' : ''}$number';
  }

  String get rootPartition => state['partitionMethod'] == 'free_space'
      ? _createdFreeSpaceLayout!.rootPath
      : _fullPartition(2);
  String get espPartition => state['partitionMethod'] == 'free_space'
      ? _createdFreeSpaceLayout!.espPath
      : _fullPartition(1);
  Future<Map<String, dynamic>> probeFreeSpaceMetadata() async {
    final approved = approvedFreeSpacePlan!;
    final result = await commandRunner.run('/usr/bin/python3', [
      '-I',
      '/usr/libexec/ro_installer_gpt.py',
      '--probe',
      approved.plan.snapshot.device.path,
      jsonEncode(approved.plan.snapshot.device.json),
      '--preserve-slots',
      jsonEncode([approved.plan.espNumber, approved.plan.rootNumber]),
    ], timeout: const Duration(seconds: 12));
    if (!result.started ||
        result.exitCode != 0 ||
        utf8.encode(result.stdout).length > 8192) {
      throw const FormatException('GPT verification failed');
    }
    final value = decodeProtocolObject(result.stdout);
    if (!exactFields(value, {'snapshot', 'preservationFingerprint'}) ||
        value['preservationFingerprint'] is! String) {
      throw const FormatException('Invalid GPT proof');
    }
    return value;
  }

  Future<bool> verifyFreeSpaceLayoutNow() async {
    if (approvedFreeSpacePlan == null ||
        _createdFreeSpaceLayout == null ||
        !approvedStateMatches) {
      return false;
    }
    try {
      final value = await probeFreeSpaceMetadata();
      return samePlanValue(
            value['snapshot'],
            _createdFreeSpaceLayout!.snapshot.json,
          ) &&
          value['preservationFingerprint'] ==
              approvedFreeSpacePlan!.preservationFingerprint;
    } catch (_) {
      return false;
    }
  }

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
