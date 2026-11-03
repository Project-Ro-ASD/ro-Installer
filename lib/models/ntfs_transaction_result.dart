import '../services/helper_protocol.dart';
import 'approved_ntfs_shrink_plan.dart';
import 'gpt_disk_snapshot.dart';

/// Private worker terminal state; an unknown transport never proves no mutation.
final class NtfsTransactionResult {
  const NtfsTransactionResult._(
    this.createdLayout,
    this.phase,
    this.progressKnown,
    this.sourceMayHaveChanged,
    this.gptWriteStarted,
    this.verifiedGptCopies,
    this.cleanupFailed,
  );
  static const phases = {
    'admission',
    'context',
    'power',
    'prepare',
    'native',
    'filesystem',
    'gpt',
    'gpt.prepare',
    'gpt.backup',
    'gpt.primary',
    'gpt.verify',
    'metadata-committed',
    'cleanup',
    'kernel.close',
    'kernel.identity',
    'kernel.reread',
    'kernel.ready',
    'kernel.source',
    'kernel.cleanup',
    'unknown',
  };
  final CreatedNtfsLayout? createdLayout;
  GptDiskSnapshot? get snapshot => createdLayout?.snapshot;
  final String phase;
  final bool progressKnown,
      sourceMayHaveChanged,
      gptWriteStarted,
      cleanupFailed;
  final int verifiedGptCopies;
  bool get succeeded => createdLayout != null;

  const NtfsTransactionResult.unknown()
    : this._(null, 'unknown', false, true, true, 0, false);
  const NtfsTransactionResult.notStarted()
    : this._(null, 'context', true, false, false, 0, false);

  factory NtfsTransactionResult.fromJson(
    Object? input, {
    required ApprovedNtfsShrinkPlan approved,
  }) {
    if (input is! Map<String, dynamic> ||
        input['schemaVersion'] is! int ||
        input['schemaVersion'] != 1) {
      throw const FormatException('Invalid NTFS terminal');
    }
    if (input['status'] == 'success') {
      if (!exactFields(input, {
            'schemaVersion',
            'status',
            'snapshot',
            'preservationFingerprint',
          }) ||
          input['preservationFingerprint'] is! String) {
        throw const FormatException('Invalid NTFS success terminal');
      }
      final snapshot = GptDiskSnapshot.fromJson(input['snapshot']);
      if (snapshot.tableFingerprint ==
          approved.plan.snapshot.tableFingerprint) {
        throw const FormatException('Stale NTFS table fingerprint');
      }
      final created = approved.verifyCreated(
        snapshot,
        input['preservationFingerprint'] as String,
      );
      return NtfsTransactionResult._(
        created,
        'complete',
        true,
        true,
        true,
        2,
        false,
      );
    }
    if (!exactFields(input, {
          'schemaVersion',
          'status',
          'phase',
          'progressKnown',
          'sourceMayHaveChanged',
          'gptWriteStarted',
          'verifiedGptCopies',
          'cleanupFailed',
        }) ||
        input['status'] != 'failed' ||
        input['phase'] is! String ||
        !phases.contains(input['phase']) ||
        [
          'progressKnown',
          'sourceMayHaveChanged',
          'gptWriteStarted',
          'cleanupFailed',
        ].any((name) => input[name] is! bool)) {
      throw const FormatException('Invalid NTFS failure terminal');
    }
    final known = input['progressKnown'] as bool,
        source = input['sourceMayHaveChanged'] as bool,
        table = input['gptWriteStarted'] as bool;
    final copies = snapshotInteger(input['verifiedGptCopies'], 0, 2);
    if ((!source && (table || copies != 0)) ||
        (copies != 0 && !table) ||
        (!known &&
            (input['phase'] != 'unknown' ||
                !source ||
                !table ||
                copies != 0))) {
      throw const FormatException('Contradictory NTFS failure progress');
    }
    return NtfsTransactionResult._(
      null,
      input['phase'] as String,
      known,
      source,
      table,
      copies,
      input['cleanupFailed'] as bool,
    );
  }
}
