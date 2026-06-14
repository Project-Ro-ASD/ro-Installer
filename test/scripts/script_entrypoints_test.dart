import 'dart:io';

import 'package:test/test.dart';

void main() {
  group('script entrypoints', () {
    const scripts = [
      'scripts/01-build-rpm.sh',
      'scripts/02-build-iso.sh',
      'scripts/03-audit-iso.sh',
      'scripts/04-benchmark-copy-paths.sh',
      'scripts/qemu-boot-iso.sh',
    ];

    test('shell scripts are syntax-valid', () async {
      for (final script in scripts) {
        final result = await Process.run('bash', ['-n', script]);
        expect(
          result.exitCode,
          0,
          reason: '$script failed bash -n:\n${result.stderr}',
        );
      }
    });

    test('main scripts expose help without starting heavy work', () async {
      const helpScripts = [
        'scripts/01-build-rpm.sh',
        'scripts/02-build-iso.sh',
        'scripts/03-audit-iso.sh',
        'scripts/04-benchmark-copy-paths.sh',
      ];

      for (final script in helpScripts) {
        final result = await Process.run('bash', [script, '--help']);
        expect(
          result.exitCode,
          0,
          reason: '$script --help failed:\n${result.stdout}\n${result.stderr}',
        );
        final output = '${result.stdout}\n${result.stderr}';
        expect(
          output.contains('Usage:') || output.contains('Kullanim:'),
          true,
          reason: '$script should print usage text',
        );
      }
    });

    test('copy benchmark rejects missing source ISO before copying', () async {
      final result = await Process.run('bash', [
        'scripts/04-benchmark-copy-paths.sh',
      ]);

      expect(result.exitCode, isNot(0));
      expect('${result.stdout}\n${result.stderr}', contains('--source-iso'));
    });
  });
}
