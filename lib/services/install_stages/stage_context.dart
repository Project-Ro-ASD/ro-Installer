import '../../models/approved_manual_plan.dart';
import '../install_observation.dart';
import '../copy_progress.dart';
import '../helper_protocol.dart';
import '../../models/approved_full_disk_plan.dart';
import '../../models/approved_free_space_plan.dart';
import 'dart:convert';
import '../command_runner.dart';
import '../mount_session.dart';
import '../install_localizer.dart';

/// A started GPT worker can fail transiently while kernel partition nodes settle.
final class FreeSpaceProbeNotReady implements Exception {
  const FreeSpaceProbeNotReady();
}

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
    this.approvedManualPlan,
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
  final ApprovedManualPlan? approvedManualPlan;
  CreatedManualLayout? _createdManualLayout;
  CreatedManualLayout? get createdManualLayout => _createdManualLayout;
  bool get reusesEsp => approvedManualPlan?.plan.esp.formatOnInstall == false;
  void bindCreatedManualLayout(CreatedManualLayout layout) {
    if (approvedManualPlan == null ||
        !samePlanValue(approvedManualPlan!.json, layout.approved.json)) {
      throw const FormatException('Unowned manual layout');
    }
    mountSession?.bindCreatedManualLayout(layout);
    _createdManualLayout = layout;
  }

  Future<bool> formattedManualEspFitsSource() async {
    final plan = approvedManualPlan!.plan;
    final bytes =
        (plan.esp.endSector - plan.esp.startSector + 1) *
        plan.snapshot.logicalSectorBytes;
    try {
      final result = await commandRunner.run('/usr/bin/python3', [
        '-I',
        '/usr/libexec/ro_installer_manual.py',
        '--new-efi-budget',
        '$bytes',
      ], timeout: const Duration(seconds: 10));
      if (!result.started ||
          result.exitCode != 0 ||
          utf8.encode(result.stdout).length > 4096) {
        return false;
      }
      final value = decodeProtocolObject(result.stdout);
      return exactFields(value, {
            'requiredBytes',
            'availableBytes',
            'sourceBytes',
            'fileCount',
            'clusterBytes',
            'sufficient',
          }) &&
          value['availableBytes'] is int &&
          value['availableBytes'] == bytes &&
          value['sufficient'] == true &&
          value['clusterBytes'] is int &&
          value['clusterBytes'] == 1048576 &&
          value['requiredBytes'] is int &&
          value['sourceBytes'] is int &&
          value['sourceBytes'] > 0 &&
          value['sourceBytes'] <= 1073741824 &&
          value['requiredBytes'] >= value['sourceBytes'] + 16777216 &&
          value['requiredBytes'] <= bytes &&
          value['fileCount'] is int &&
          value['fileCount'] >= 2 &&
          value['fileCount'] <= 4096;
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, dynamic>> probeManualMetadata() async {
    final approved = approvedManualPlan!;
    final result = await commandRunner.run('/usr/bin/python3', [
      '-I',
      '/usr/libexec/ro_installer_manual.py',
      '--layout',
      approved.plan.snapshot.device.path,
      jsonEncode(approved.plan.snapshot.device.json),
      jsonEncode(approved.newSlots),
    ], timeout: const Duration(seconds: 12));
    if (!result.started ||
        result.exitCode != 0 ||
        utf8.encode(result.stdout).length > 8192) {
      throw const FormatException('Manual metadata probe failed');
    }
    final value = decodeProtocolObject(result.stdout);
    if (!exactFields(value, {'snapshot', 'preservationFingerprint'}) ||
        value['preservationFingerprint'] is! String) {
      throw const FormatException('Invalid manual metadata proof');
    }
    return value;
  }

  Future<bool> verifyManualLayoutNow() async {
    if (_createdManualLayout == null || !approvedStateMatches) return false;
    try {
      final value = await probeManualMetadata();
      return samePlanValue(
            value['snapshot'],
            _createdManualLayout!.snapshot.json,
          ) &&
          value['preservationFingerprint'] ==
              approvedManualPlan!.preservationFingerprint;
    } catch (_) {
      return false;
    }
  }

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
          approvedFreeSpacePlan!.matchesState(state)) &&
      (approvedManualPlan == null || approvedManualPlan!.matchesState(state));
  bool get usesStandardStorage =>
      approvedStateMatches &&
      (state['fileSystem'] ?? 'btrfs') == 'btrfs' &&
      ((state['partitionMethod'] ?? 'full') == 'full' ||
          (state['partitionMethod'] == 'manual' &&
              approvedManualPlan != null &&
              _createdManualLayout != null) ||
          (state['partitionMethod'] == 'free_space' &&
              approvedFreeSpacePlan != null &&
              _createdFreeSpaceLayout != null &&
              approvedStateMatches));
  String _fullPartition(int number) {
    final disk = state['selectedDisk'] as String;
    return '$disk${disk.contains('nvme') || disk.contains('mmcblk') || disk.contains('loop') ? 'p' : ''}$number';
  }

  String get rootPartition => state['partitionMethod'] == 'manual'
      ? _createdManualLayout!.rootPath
      : state['partitionMethod'] == 'free_space'
      ? _createdFreeSpaceLayout!.rootPath
      : _fullPartition(2);
  String get espPartition => state['partitionMethod'] == 'manual'
      ? _createdManualLayout!.espPath
      : state['partitionMethod'] == 'free_space'
      ? _createdFreeSpaceLayout!.espPath
      : _fullPartition(1);
  Future<Map<String, dynamic>> probeFreeSpaceMetadata({
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final approved = approvedFreeSpacePlan!;
    final result = await commandRunner.run('/usr/bin/python3', [
      '-I',
      '/usr/libexec/ro_installer_gpt.py',
      '--probe',
      approved.plan.snapshot.device.path,
      jsonEncode(approved.plan.snapshot.device.json),
      '--preserve-slots',
      jsonEncode([approved.plan.espNumber, approved.plan.rootNumber]),
    ], timeout: timeout);
    if (!result.started || utf8.encode(result.stdout).length > 8192) {
      throw const FormatException('GPT verification failed');
    }
    if (result.exitCode != 0) throw const FreeSpaceProbeNotReady();
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
