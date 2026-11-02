import '../../models/approved_free_space_plan.dart';
import '../../models/gpt_disk_snapshot.dart';
import 'stage_context.dart';

Future<CreatedFreeSpaceLayout?> readCreatedFreeSpaceLayout(
  StageContext ctx, {
  Duration timeout = const Duration(seconds: 12),
}) async {
  final approved = ctx.approvedFreeSpacePlan;
  if (approved == null || !ctx.approvedStateMatches) return null;
  final value = await ctx.probeFreeSpaceMetadata(timeout: timeout);
  final layout = approved.verifyCreated(
    GptDiskSnapshot.fromJson(value['snapshot']),
    value['preservationFingerprint'] as String,
  );
  return ctx.approvedStateMatches ? layout : null;
}

/// Retry only unsuccessful worker reads. A readable wrong layout fails at once.
/// No new slot can be formatted until its exact GUID/range and proof match.
Future<CreatedFreeSpaceLayout?> waitForFreeSpaceLayout(
  StageContext ctx, {
  Duration Function()? monotonicElapsed,
}) async {
  final approved = ctx.approvedFreeSpacePlan, session = ctx.mountSession;
  if (approved == null || session == null || !ctx.approvedStateMatches) {
    return null;
  }
  final clock = Stopwatch()..start();
  final elapsed = monotonicElapsed ?? (() => clock.elapsed);
  for (
    var attempt = 0;
    attempt < 20 && elapsed() < const Duration(seconds: 5);
    attempt++
  ) {
    if (!ctx.approvedStateMatches) return null;
    try {
      await session.validateTarget(
        approved.plan.snapshot.device.path,
        commit: true,
      );
      if (elapsed() >= const Duration(seconds: 5)) return null;
      final layout = await readCreatedFreeSpaceLayout(
        ctx,
        timeout: const Duration(seconds: 1),
      );
      if (layout == null || elapsed() >= const Duration(seconds: 5)) {
        return null;
      }
      await session.validateTarget(
        approved.plan.snapshot.device.path,
        commit: true,
      );
      return elapsed() < const Duration(seconds: 5) && ctx.approvedStateMatches
          ? layout
          : null;
    } on FreeSpaceProbeNotReady {
      // CRC/kernel inventory can be temporarily unavailable after partprobe.
    } catch (_) {
      return null;
    }
    if (attempt < 19 && elapsed() < const Duration(milliseconds: 4900)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
  return null;
}
