import 'dart:io';

import 'package:test/test.dart';

void main() {
  group('real system log audit', () {
    const logDir = 'gerçeksistemdenloglar';

    test('kernel black screen corpus contains expected regression signals', () {
      final dir = Directory(logDir);
      expect(dir.existsSync(), true);
      expect(dir.listSync().whereType<File>().length, greaterThanOrEqualTo(4));

      final analysis = File(
        '$logDir/kernel-black-screen-analysis-20260505.md',
      ).readAsStringSync();
      expect(analysis, contains('NVIDIA GA102'));
      expect(analysis, contains('nomodeset'));
      expect(analysis, contains('nouveau.config=NvGspRm=1'));
      expect(analysis, contains('nouveau.config=NvGspRm=0'));
      expect(analysis, contains('rd.driver.blacklist=nouveau'));
    });

    test(
      'custom nomodeset and stock Fedora logs preserve comparison points',
      () {
        final customNomodeset = File(
          '$logDir/ro-kernel-debug-custom-nomodeset.txt',
        ).readAsStringSync();
        final stockFedora = File(
          '$logDir/ro-kernel-debug-stock-fedora-kernel.txt',
        ).readAsStringSync();

        expect(customNomodeset, contains('nomodeset'));
        expect(customNomodeset, contains('rootflags=subvol=@'));
        expect(customNomodeset, contains('nouveau.config=NvGspRm=1'));
        expect(customNomodeset, contains('nouveau.noaccel=1'));

        expect(stockFedora, contains('Kernel driver in use: nouveau'));
        expect(stockFedora, contains('NVIDIA GA102'));
        expect(stockFedora, contains('[drm] Initialized nouveau'));
      },
    );
  });
}
