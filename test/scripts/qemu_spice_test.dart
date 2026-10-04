import 'dart:io';
import 'package:test/test.dart';

void main() {
  test('QEMU SPICE harness contracts without booting a VM', () async {
    final result = await Process.run('python3', [
      'test/scripts/qemu_spice_test.py',
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  });
}
