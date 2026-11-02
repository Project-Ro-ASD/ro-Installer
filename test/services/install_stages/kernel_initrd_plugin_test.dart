import 'dart:io';
import 'package:test/test.dart';

void main() {
  test(
    'packaged Fedora dracut plugin reuses an explicitly supplied initrd',
    () async {
      const plugin = '/usr/lib/kernel/install.d/50-dracut.install';
      expect(
        File(plugin).existsSync(),
        true,
        reason:
            'The Fedora dracut package is required; this regression must not skip',
      );
      final directory = Directory.systemTemp.createTempSync(
        'ro-initrd-plugin-',
      );
      try {
        final bin = Directory('${directory.path}/bin')..createSync();
        final entry = Directory('${directory.path}/entry')..createSync();
        final config = Directory('${directory.path}/conf')..createSync();
        File(
          '${config.path}/cmdline',
        ).writeAsStringSync('root=UUID=fixture ro\n');
        final kernel = File('${directory.path}/vmlinuz-fixture')
          ..writeAsStringSync('kernel');
        final initrd = File('${directory.path}/generated.img')
          ..writeAsStringSync('generated initramfs');
        final marker = File('${directory.path}/dracut-called');
        final dracut = File('${bin.path}/dracut')
          ..writeAsStringSync(r'''#!/usr/bin/bash
printf 'called\n' >> "$DRACUT_MARKER"
exit 0
''');
        expect(
          (await Process.run('/usr/bin/chmod', ['700', dracut.path])).exitCode,
          0,
        );
        Future<ProcessResult> invoke({required bool supplied}) => Process.run(
          '/usr/bin/bash',
          [
            plugin,
            'add',
            '6.1.0-fixture',
            entry.path,
            kernel.path,
            if (supplied) initrd.path,
          ],
          environment: {
            'PATH': '${bin.path}:/usr/bin',
            'LC_ALL': 'C',
            'KERNEL_INSTALL_MACHINE_ID': 'fixture',
            'KERNEL_INSTALL_LAYOUT': 'other',
            'KERNEL_INSTALL_IMAGE_TYPE': 'kernel',
            'KERNEL_INSTALL_CONF_ROOT': config.path,
            'KERNEL_INSTALL_VERBOSE': '0',
            'DRACUT_MARKER': marker.path,
          },
          includeParentEnvironment: false,
          workingDirectory: directory.path,
        );
        final baseline = await invoke(supplied: false);
        expect(baseline.exitCode, 0, reason: '${baseline.stderr}');
        expect(marker.readAsLinesSync(), ['called']);
        marker.deleteSync();
        final reused = await invoke(supplied: true);
        expect(reused.exitCode, 0, reason: '${reused.stderr}');
        expect(marker.existsSync(), false);
        expect(initrd.readAsStringSync(), 'generated initramfs');
      } finally {
        directory.deleteSync(recursive: true);
      }
    },
  );
}
