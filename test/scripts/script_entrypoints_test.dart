import 'dart:io';
import 'package:test/test.dart';

const removedFiles = [
  'scripts/build-iso.sh',
  'scripts/02-build-iso.sh',
  'scripts/03-audit-iso.sh',
  'scripts/04-benchmark-copy-paths.sh',
  'kernel.txt',
];
const isoConsumers = [
  'scripts/qemu-boot-iso.sh',
  'scripts/test-qemu.sh',
  'test_qemu_vm.sh',
];

void main() {
  group('script entrypoints', () {
    test('every remaining tracked shell script has valid syntax', () async {
      final listed = await Process.run('git', ['ls-files', '*.sh']);
      expect(listed.exitCode, 0);
      for (final script in listed.stdout.toString().trim().split('\n')) {
        if (!File(script).existsSync()) continue;
        final result = await Process.run('bash', ['-n', script]);
        expect(result.exitCode, 0, reason: '$script: ${result.stderr}');
      }
    });
    test('active main entrypoints expose help without heavy work', () async {
      for (final script in [
        'scripts/test-qemu.sh',
        'scripts/01-build-rpm.sh',
        'scripts/qemu-boot-iso.sh',
      ]) {
        final result = await Process.run('bash', [script, '--help']);
        expect(result.exitCode, 0, reason: result.stderr.toString());
        final output = '${result.stdout}\n${result.stderr}';
        expect(output.contains('Usage:') || output.contains('Kullanim:'), true);
      }
    });
    test(
      'producer, static audit, extraction benchmark and historical report are deleted',
      () {
        for (final path in removedFiles) {
          expect(File(path).existsSync(), false, reason: path);
        }
      },
    );
    test('RPM build advertises only RPM work', () async {
      final result = await Process.run('bash', [
        'scripts/01-build-rpm.sh',
        '--help',
      ]);
      expect(result.exitCode, 0);
      final source = File('scripts/01-build-rpm.sh').readAsStringSync();
      for (final forbidden in [
        '--no-chain',
        '--source-iso',
        '--beta',
        '--no-host-auto-install',
        'CHAIN_ISO',
        '02-build-iso.sh',
      ]) {
        expect(result.stdout.toString(), isNot(contains(forbidden)));
        expect(source, isNot(contains(forbidden)));
      }
      for (final retained in [
        'archive --worktree-attributes',
        'audit_source_tarball',
        'source_tarball_sha256=',
        'latest-rpm-path.txt',
        'latest-rpm-manifest.txt',
        '*.iso',
        '*.qcow2',
        '*.fd',
      ]) {
        expect(source, contains(retained));
      }
    });
    test('wrapper suites consume ISO without composition policy', () async {
      final result = await Process.run('bash', [
        'scripts/test-qemu.sh',
        '--help',
      ]);
      expect(result.exitCode, 0);
      for (final suite in ['check', 'boot', 'smoke', 'install', 'all']) {
        expect(result.stdout.toString(), contains('--suite $suite'));
      }
      final source = File('scripts/test-qemu.sh').readAsStringSync();
      for (final forbidden in [
        '--suite audit',
        '--skip-audit',
        '--allow-unsigned-ro-repo',
        '03-audit-iso.sh',
        'xorriso',
        'build-manifest',
        'iso-release',
        'iso-realese',
      ]) {
        expect(source, isNot(contains(forbidden)));
      }
    });
    test('consumers contain no local ISO discovery', () {
      for (final script in isoConsumers) {
        final source = File(script).readAsStringSync();
        for (final forbidden in [
          'iso-release',
          'iso-realese',
          'latest-iso',
          'Ro-ASD-beta',
          "-name '*.iso'",
        ]) {
          expect(source, isNot(contains(forbidden)), reason: script);
        }
      }
      final vm = File('test_qemu_vm.sh').readAsStringSync();
      for (final retained in [
        'RO_INSTALLER_TEST_ISO',
        '--enforce-lockfile',
        'pubspec.lock dosyasini degistirdi',
        'build linux --release --no-pub',
        '.dart_tool/flutter_build',
        'hostshare',
        'guest-logs',
        'runner-state.txt',
        'RO_INSTALLER_VM_BOOT_OK',
      ]) {
        expect(vm, contains(retained));
      }
      expect(
        vm.indexOf(r'ISO_FILE="$(resolve_iso)"'),
        lessThan(vm.indexOf('require_host_cmd qemu-system-x86_64')),
      );
      expect(
        File('test_qemu_guest_runner.sh').readAsStringSync(),
        contains('build/linux/x64/release/bundle/ro_installer'),
      );
    });
  });

  group('external ISO fail-fast behavior', () {
    late Directory repo;
    late Directory tools;
    late File marker;
    setUp(() {
      repo = Directory.systemTemp.createTempSync('pr08-entrypoints-');
      tools = Directory('${repo.path}/fake-tools')..createSync();
      marker = File('${repo.path}/heavy-work');
      Directory('${repo.path}/scripts').createSync();
      for (final script in isoConsumers) {
        File(script).copySync('${repo.path}/$script');
      }
      // Stale local artifacts must never satisfy the external-input contract.
      for (final directory in ['iso-release', 'iso-realese']) {
        Directory('${repo.path}/$directory').createSync();
        final stale = File('${repo.path}/$directory/Ro-ASD-beta999.iso')
          ..writeAsStringSync('stale');
        File(
          '${repo.path}/$directory/latest-iso-path.txt',
        ).writeAsStringSync(stale.path);
      }
      File('${repo.path}/unrelated.iso').writeAsStringSync('stale');
      for (final command in ['qemu-system-x86_64', 'qemu-img', 'flutter']) {
        final tool = File('${tools.path}/$command');
        tool.writeAsStringSync(
          '#!/bin/sh\nprintf called >> "\$HEAVY_MARKER"\nexit 88\n',
        );
        expect(Process.runSync('chmod', ['+x', tool.path]).exitCode, 0);
      }
    });
    tearDown(() => repo.deleteSync(recursive: true));
    Map<String, String> environment() => {
      'RO_ASD_TEST_ISO': '',
      'RO_INSTALLER_TEST_ISO': '',
      'PATH': '${tools.path}:${Platform.environment['PATH']}',
      'HEAVY_MARKER': marker.path,
    };
    for (final script in isoConsumers) {
      test('$script rejects missing ISO despite stale local files', () async {
        final result = await Process.run(
          'bash',
          ['${repo.path}/$script'],
          workingDirectory: repo.path,
          environment: environment(),
        );
        expect(result.exitCode, isNot(0));
        final output = '${result.stdout}\n${result.stderr}';
        expect(
          output,
          contains('external Compose-produced test ISO is required'),
        );
        expect(
          output,
          contains(
            script == 'test_qemu_vm.sh'
                ? 'RO_INSTALLER_TEST_ISO'
                : 'RO_ASD_TEST_ISO',
          ),
        );
        if (script != 'test_qemu_vm.sh') expect(output, contains('--iso PATH'));
        expect(marker.existsSync(), false);
      });
      test(
        '$script rejects explicit nonexistent ISO before tools/build',
        () async {
          final env = environment();
          env[script == 'test_qemu_vm.sh'
                  ? 'RO_INSTALLER_TEST_ISO'
                  : 'RO_ASD_TEST_ISO'] =
              '${repo.path}/missing-external.iso';
          final result = await Process.run(
            'bash',
            ['${repo.path}/$script'],
            workingDirectory: repo.path,
            environment: env,
          );
          expect(result.exitCode, isNot(0));
          expect(
            '${result.stdout}\n${result.stderr}',
            contains('ISO not found'),
          );
          expect(marker.existsSync(), false);
        },
      );
    }
    for (final script in isoConsumers.take(2)) {
      test('$script CLI overrides environment ISO', () async {
        final env = environment()
          ..['RO_ASD_TEST_ISO'] = '/missing/env-input.iso';
        final result = await Process.run(
          'bash',
          ['${repo.path}/$script', '--iso', '/missing/cli-input.iso'],
          workingDirectory: repo.path,
          environment: env,
        );
        expect(result.exitCode, isNot(0));
        expect(
          '${result.stdout}\n${result.stderr}',
          contains('ISO not found or unreadable: /missing/cli-input.iso'),
        );
        expect(marker.existsSync(), false);
      });
    }
    test('removed audit suite and flags are rejected', () async {
      for (final args in [
        ['--suite', 'audit'],
        ['--skip-audit'],
        ['--allow-unsigned-ro-repo'],
      ]) {
        final result = await Process.run(
          'bash',
          ['${repo.path}/scripts/test-qemu.sh', ...args],
          workingDirectory: repo.path,
          environment: environment(),
        );
        expect(result.exitCode, isNot(0));
        expect(marker.existsSync(), false);
      }
    });
  });
}
