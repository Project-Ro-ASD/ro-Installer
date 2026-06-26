import 'dart:io';

import 'package:test/test.dart';

void main() {
  group('real system log audit', () {
    const logDir = 'gerçeksistemdenloglar';
    const analysisPath =
        'docs/old/gerçeksistemdenloglar/kernel-black-screen-analysis-20260505.md';
    const customNomodesetPath = '$logDir/ro-kernel-debug-custom-nomodeset.txt';
    const stockFedoraPath = '$logDir/ro-kernel-debug-stock-fedora-kernel.txt';

    test(
      'kernel black screen corpus contains expected regression signals',
      () {
        final dir = Directory(logDir);
        expect(dir.existsSync(), true);
        expect(
          dir.listSync().whereType<File>().length,
          greaterThanOrEqualTo(4),
        );

        final analysis = File(analysisPath).readAsStringSync();
        expect(analysis, contains('NVIDIA GA102'));
        expect(analysis, contains('nomodeset'));
        expect(analysis, contains('nouveau.config=NvGspRm=1'));
        expect(analysis, contains('nouveau.config=NvGspRm=0'));
        expect(analysis, contains('rd.driver.blacklist=nouveau'));
      },
      skip: _hasCorpusIndex(logDir, analysisPath) ? false : _skipReason,
    );

    test(
      'custom nomodeset and stock Fedora logs preserve comparison points',
      () {
        final customNomodeset = File(customNomodesetPath).readAsStringSync();
        final stockFedora = File(stockFedoraPath).readAsStringSync();

        expect(customNomodeset, contains('nomodeset'));
        expect(customNomodeset, contains('rootflags=subvol=@'));
        expect(customNomodeset, contains('nouveau.config=NvGspRm=1'));
        expect(customNomodeset, contains('nouveau.noaccel=1'));

        expect(stockFedora, contains('Kernel driver in use: nouveau'));
        expect(stockFedora, contains('NVIDIA GA102'));
        expect(stockFedora, contains('[drm] Initialized nouveau'));
      },
      skip: _hasComparisonLogs(customNomodesetPath, stockFedoraPath)
          ? false
          : _skipReason,
    );
  });
}

const _skipReason =
    'Local real hardware log corpus is intentionally not committed.';

bool _hasCorpusIndex(String logDir, String analysisPath) {
  final dir = Directory(logDir);
  return dir.existsSync() &&
      File(analysisPath).existsSync() &&
      dir.listSync().whereType<File>().length >= 4;
}

bool _hasComparisonLogs(String customNomodesetPath, String stockFedoraPath) {
  return File(customNomodesetPath).existsSync() &&
      File(stockFedoraPath).existsSync();
}
