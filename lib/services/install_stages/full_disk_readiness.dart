import 'dart:convert';
import '../../models/approved_full_disk_plan.dart';
import '../../models/gpt_disk_snapshot.dart';
import '../../models/manual_installation_plan.dart';
import '../../models/standard_storage_layout.dart';
import 'stage_context.dart';

enum FullDiskPartitionWriter { sgdisk, parted }

/// Accept only the fixed full-disk layout observed by the isolated GPT worker.
/// The worker also verifies both GPT copies and the kernel partition inventory.
bool matchesFullDiskLayout(
  ApprovedFullDiskPlan approved,
  GptDiskSnapshot value, {
  FullDiskPartitionWriter writer = FullDiskPartitionWriter.sgdisk,
}) {
  if (!samePlanValue(approved.device.json, value.device.json) ||
      value.partitions.length != 2) {
    return false;
  }
  final esp = value.partitions[0], root = value.partitions[1];
  final sector = value.logicalSectorBytes;
  final align = 1048576 ~/ sector;
  final expectedEnd = writer == FullDiskPartitionWriter.parted
      ? (value.lastUsableSector + 1) ~/ align * align - 1
      : value.lastUsableSector;
  return esp.number == 1 &&
      root.number == 2 &&
      esp.typeGuid == ManualInstallationPlan.espTypeGuid &&
      root.typeGuid == ManualInstallationPlan.rootTypeGuid &&
      esp.attributesHex == '0000000000000000' &&
      root.attributesHex == '0000000000000000' &&
      esp.startSector * sector == 1048576 &&
      (esp.endSector - esp.startSector + 1) * sector ==
          StandardStorageLayout.espBytes &&
      root.startSector == esp.endSector + 1 &&
      root.endSector == expectedEnd &&
      (root.endSector - root.startSector + 1) * sector >=
          StandardStorageLayout.temporaryMinimumRootBytes;
}

/// Retry transient probe failures; a successfully read wrong layout fails now.
/// No formatting, repair or fallback is authorized by an unsuccessful probe.
Future<bool> waitForFullDiskLayout(
  StageContext ctx, {
  FullDiskPartitionWriter writer = FullDiskPartitionWriter.sgdisk,
  Duration Function()? monotonicElapsed,
}) async {
  final approved = ctx.approvedPlan, session = ctx.mountSession;
  if (approved == null || session == null || !ctx.approvedStateMatches) {
    return false;
  }
  final clock = Stopwatch()..start();
  final elapsed = monotonicElapsed ?? (() => clock.elapsed);
  for (
    var attempt = 0;
    attempt < 20 && elapsed() < const Duration(seconds: 5);
    attempt++
  ) {
    if (!ctx.approvedStateMatches) return false;
    try {
      await session.validateTarget(approved.device.path, commit: true);
      if (elapsed() >= const Duration(seconds: 5)) return false;
      final result = await ctx.commandRunner.run('/usr/bin/python3', [
        '-I',
        '/usr/libexec/ro_installer_gpt.py',
        '--probe',
        approved.device.path,
        jsonEncode(approved.device.json),
      ], timeout: const Duration(seconds: 1));
      if (elapsed() >= const Duration(seconds: 5)) return false;
      if (result.started && result.exitCode == 0) {
        if (utf8.encode(result.stdout).length > 4096) return false;
        final snapshot = GptDiskSnapshot.fromJson(jsonDecode(result.stdout));
        if (!matchesFullDiskLayout(approved, snapshot, writer: writer) ||
            !ctx.approvedStateMatches) {
          return false;
        }
        await session.validateTarget(approved.device.path, commit: true);
        return elapsed() < const Duration(seconds: 5) &&
            ctx.approvedStateMatches;
      }
      if (!result.started) return false;
    } catch (_) {
      return false;
    }
    if (attempt < 19 && elapsed() < const Duration(milliseconds: 4900)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
  return false;
}
