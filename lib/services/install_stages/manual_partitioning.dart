import '../../models/approved_full_disk_plan.dart';
import '../../models/gpt_disk_snapshot.dart';
import 'stage_context.dart';
import 'stage_result.dart';

/// Only helper-owned slots can be appended. Existing GPT entries are immutable.
Future<StageResult> partitionApprovedManual(StageContext ctx) async {
  final approved = ctx.approvedManualPlan;
  if (approved == null || !ctx.approvedStateMatches) {
    return StageResult.fail('Doğrulanmış manuel plan gerekli.');
  }
  try {
    final before = await ctx.probeManualMetadata();
    if (!samePlanValue(before['snapshot'], approved.plan.snapshot.json) ||
        before['preservationFingerprint'] != approved.preservationFingerprint) {
      return StageResult.fail('Manuel planın kaynak diski değişti.');
    }
    if (approved.newSlots.isNotEmpty && !ctx.isMock) {
      final tool = await ctx.commandRunner.run('sh', [
        '-c',
        'command -v sfdisk >/dev/null 2>&1',
      ]);
      if (!tool.started || tool.exitCode != 0) {
        return StageResult.fail('sfdisk bulunamadı.');
      }
    }
    await ctx.beforeFirstMutation?.call();
    if (!ctx.approvedStateMatches) {
      return StageResult.fail('Manuel onay değişti.');
    }
    if (approved.newSlots.isNotEmpty) {
      final lines = <String>[];
      for (final part in [
        approved.plan.esp,
        approved.plan.root,
      ].where((p) => p.isNew)) {
        final name = part.role.name == 'esp' ? 'RoASD_EFI' : 'RoASD_Root';
        lines.add(
          '${part.number} : start=${part.startSector}, size=${part.endSector - part.startSector + 1}, type=${part.typeGuid}, uuid=${approved.allocationGuids[part.role.name]}, name="$name"',
        );
      }
      final result = await ctx.commandRunner.run(
        'sfdisk',
        [
          '--append',
          '--no-reread',
          '--no-tell-kernel',
          '--wipe',
          'never',
          '--wipe-partitions',
          'never',
          approved.plan.snapshot.device.path,
        ],
        stdinText: '${lines.join('\n')}\n',
        isMock: ctx.isMock,
        timeout: const Duration(seconds: 60),
      );
      if (!result.started || result.exitCode != 0) {
        return StageResult.fail('Manuel bölümler oluşturulamadı.');
      }
      for (final command in ['partprobe', 'udevadm']) {
        final scan = await ctx.commandRunner.run(
          command,
          command == 'partprobe'
              ? [approved.plan.snapshot.device.path]
              : ['settle'],
          isMock: ctx.isMock,
          timeout: const Duration(seconds: 30),
        );
        if (!scan.started || scan.exitCode != 0) {
          return StageResult.fail('Yeni bölüm aygıtları hazır değil.');
        }
      }
    }
    final after = await ctx.probeManualMetadata();
    final layout = approved.verifyCreated(
      GptDiskSnapshot.fromJson(after['snapshot']),
      after['preservationFingerprint'] as String,
    );
    ctx.bindCreatedManualLayout(layout);
    return StageResult.ok(
      'Manuel bölüm kimlikleri ve GPT koruması doğrulandı.',
    );
  } catch (_) {
    return StageResult.fail('Manuel bölüm sahipliği doğrulanamadı.');
  }
}
