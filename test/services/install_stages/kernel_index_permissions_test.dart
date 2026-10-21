import 'dart:io';

import 'package:test/test.dart';
import 'package:ro_installer/services/install_stages/bootloader_stage.dart';

/// Real depmod writes only beneath `-b <temporary root>`. No chroot, mount,
/// privilege escalation or host module-tree mutation is used.
class IndexFixture {
  final root = Directory.systemTemp.createTempSync('i01-indexes-');
  final String depmod;
  static const versions = ['6.1.0-i01', '6.2.0-i01'];
  static const indexes = [
    'modules.alias',
    'modules.alias.bin',
    'modules.dep',
    'modules.dep.bin',
    'modules.symbols',
    'modules.symbols.bin',
    'modules.softdep',
    'modules.devname',
    'modules.builtin.bin',
    'modules.builtin.alias.bin',
  ];

  IndexFixture(this.depmod) {
    Directory('${root.path}/usr/lib/modules').createSync(recursive: true);
    Link('${root.path}/lib').createSync('usr/lib');
    Directory('${root.path}/boot').createSync();
    Directory('${root.path}/bin').createSync();
    for (final version in versions) {
      Directory(
        '${root.path}/lib/modules/$version/kernel',
      ).createSync(recursive: true);
      for (final name in [
        'modules.order',
        'modules.builtin',
        'modules.builtin.modinfo',
      ]) {
        File('${root.path}/lib/modules/$version/$name').writeAsStringSync('');
      }
      File(
        '${root.path}/lib/modules/$version/modules.builtin',
      ).writeAsStringSync('kernel/i01.ko\n');
      File(
        '${root.path}/lib/modules/$version/modules.builtin.modinfo',
      ).writeAsBytesSync('i01.alias=i01:test\u0000'.codeUnits);
      File(
        '${root.path}/boot/vmlinuz-$version',
      ).writeAsStringSync('fixture kernel');
    }
    tool('depmod', r'''
[ "$FAIL_PHASE" != "$PHASE" ] || exit 23
printf '%s %s\n' "$PHASE" "$(umask)" >> "$FIXTURE/depmod-masks"
exec "$REAL_DEPMOD" -b "$FIXTURE" "$@"
''');
    tool('dracut', r'''
# Assert repaired indexes are visible before initramfs generation.
for name in modules.alias modules.alias.bin modules.dep modules.dep.bin; do
  [ "$(stat -c %a "$FIXTURE/lib/modules/$3/$name")" = 644 ] || exit 24
done
printf private > "$FIXTURE/dracut-secret-$3"
printf initramfs > "$2"
''');
    tool('kernel-install', r'''
printf private > "$FIXTURE/plugin-secret-$2"
mkdir "$FIXTURE/plugin-private-$2"
printf lock > "$FIXTURE/plugin-private-$2/lock"
# Model 50-depmod.install, including its inherited 0077 mask.
PHASE=plugin depmod -a "$2" || exit "$?"
[ "$(stat -c %a "$FIXTURE/lib/modules/$2/modules.dep")" = 600 ] || exit 25
''');
  }

  void tool(String name, String body) {
    final file = File('${root.path}/bin/$name');
    file.writeAsStringSync('#!/bin/sh\nset -e\n$body');
    if (Process.runSync('chmod', ['700', file.path]).exitCode != 0) {
      throw StateError('cannot make temporary fixture tool executable');
    }
  }

  Future<ProcessResult> run(String script, {String failPhase = ''}) {
    final redirected = script.replaceAllMapped(
      RegExp(r'/usr/lib/modules|/lib/modules|/boot'),
      (match) => '${root.path}${match[0]}',
    );
    return Process.run(
      'sh',
      [
        '-c',
        '''
umask 077
printf private > "\$FIXTURE/parent-secret"
(
$redirected
)
status=\$?
printf private > "\$FIXTURE/after-secret"
exit "\$status"
''',
      ],
      environment: {
        'PATH': '${root.path}/bin:${Platform.environment['PATH']}',
        'FIXTURE': root.path,
        'REAL_DEPMOD': depmod,
        'PHASE': 'prepare',
        'FAIL_PHASE': failPhase,
      },
    );
  }

  int mode(String path) => FileStat.statSync('${root.path}/$path').mode & 0x1ff;

  void expectReadable() {
    for (final version in versions) {
      final tree = 'lib/modules/$version';
      for (final name in indexes) {
        expect(
          mode('$tree/$name'),
          0x1a4,
          reason: '$version/$name must be 0644',
        );
      }
      // Also cover outputs added by newer kmod (e.g. modules.weakdep).
      for (final entry in Directory('${root.path}/$tree').listSync()) {
        final name = entry.path.split('/').last;
        if (indexes.contains(name) || name == 'modules.weakdep') {
          expect(
            FileStat.statSync(entry.path).mode & 4,
            4,
            reason: '$name must be readable by unrelated users',
          );
          File(entry.path).readAsBytesSync(); // actual unprivileged read
        }
      }
    }
  }

  void dispose() => root.deleteSync(recursive: true);
}

void main() {
  final probe = Process.runSync('sh', ['-c', 'command -v depmod']);
  final depmod = probe.stdout.toString().trim();
  final skip = depmod.isEmpty
      ? 'real depmod is required (no mocked fallback)'
      : false;

  test(
    '0077 parent: real depmod repairs Live indexes before dracut and after plugins',
    () async {
      final fixture = IndexFixture(depmod);
      addTearDown(fixture.dispose);
      // Reproduce the defect with real depmod, in an isolated module tree.
      for (final version in IndexFixture.versions) {
        final seed = await fixture.run(
          '"\$REAL_DEPMOD" -b "\$FIXTURE" -a "$version"',
        );
        expect(seed.exitCode, 0, reason: '${seed.stderr}');
        for (final name in IndexFixture.indexes) {
          expect(fixture.mode('lib/modules/$version/$name'), 0x180);
        }
      }
      final dracut = await fixture.run(bootloaderDracutScript);
      expect(dracut.exitCode, 0, reason: '${dracut.stderr}');
      fixture.expectReadable();
      final install = await fixture.run(bootloaderKernelInstallScript);
      expect(install.exitCode, 0, reason: '${install.stderr}');
      fixture.expectReadable();
      expect(File('${fixture.root.path}/depmod-masks').readAsLinesSync(), [
        'prepare 0022',
        'prepare 0022',
        'plugin 0077',
        'prepare 0022',
        'plugin 0077',
        'prepare 0022',
      ]);
      for (final name in ['parent-secret', 'after-secret']) {
        expect(fixture.mode(name), 0x180);
      }
      for (final version in IndexFixture.versions) {
        for (final name in [
          'dracut-secret-$version',
          'plugin-secret-$version',
          'plugin-private-$version/lock',
        ]) {
          expect(fixture.mode(name), 0x180, reason: '$name must remain 0600');
        }
        expect(fixture.mode('plugin-private-$version'), 0x1c0); // 0700
      }
    },
    skip: skip,
  );

  final modprobe = Process.runSync('sh', ['-c', 'command -v modprobe']);
  test(
    'unprivileged real modprobe resolves rebuilt builtin alias indexes',
    () async {
      final fixture = IndexFixture(depmod);
      addTearDown(fixture.dispose);
      expect((await fixture.run(bootloaderDracutScript)).exitCode, 0);
      expect((await fixture.run(bootloaderKernelInstallScript)).exitCode, 0);
      for (final version in IndexFixture.versions) {
        final query = await Process.run(modprobe.stdout.toString().trim(), [
          '-d',
          fixture.root.path,
          '-S',
          version,
          '-R',
          'i01:test',
        ]);
        expect(query.exitCode, 0, reason: '${query.stderr}');
        expect(query.stdout.toString().trim(), 'i01');
      }
    },
    skip: depmod.isEmpty || modprobe.exitCode != 0
        ? 'real depmod and modprobe are required'
        : false,
  );

  for (final entry in {
    'before dracut': bootloaderDracutScript,
    'after kernel-install': bootloaderKernelInstallScript,
  }.entries) {
    test('depmod failure ${entry.key} aborts preparation', () async {
      final fixture = IndexFixture(depmod);
      addTearDown(fixture.dispose);
      final result = await fixture.run(entry.value, failPhase: 'prepare');
      expect(result.exitCode, 23, reason: '${result.stderr}');
      expect(
        File(
          '${fixture.root.path}/dracut-secret-${IndexFixture.versions.last}',
        ).existsSync(),
        false,
      );
      expect(
        File(
          '${fixture.root.path}/plugin-secret-${IndexFixture.versions.last}',
        ).existsSync(),
        false,
      );
      expect(fixture.mode('after-secret'), 0x180);
    }, skip: skip);
  }
}
