import 'package:ro_installer/services/install_stages/file_copy_stage.dart';
import 'dart:convert';
import 'package:ro_installer/services/fake_command_runner.dart';
import 'package:ro_installer/services/install_stages/prepared_kernel_artifacts.dart';

const releaseMetadata = {
  'schema_version': 'ro-asd-release-metadata-v1',
  'product': {'name': 'Ro-ASD', 'release': 44},
  'base': {'distribution': 'Fedora Linux', 'release': 44},
  'primary_architecture': 'x86_64',
};
const kernelQuery = [
  '-c',
  '$preparedKernelDiscoveryScript\ndiscover_prepared_kernels',
];
const sourceBudgetStats =
    'Number of files: 30000 (reg: 29990, dir: 10)\n'
    'Total file size: 2147483648 bytes\nTotal transferred file size: 0 bytes\n';
List<String> get sourceBudgetArguments => FileCopyStage.mainCopyArguments([
  '--exclude=/boot/efi/*',
  '--exclude=/boot/efi',
], dryRun: true);

void configurePreparedSource(
  FakeCommandRunner f, {
  String disk = "/dev/fixture",
  int diskBytes = 80 * 1024 * 1024 * 1024,
  String? budgetStats,
  int budgetExitCode = 0,
  bool budgetStarted = true,
}) {
  f.addResponse('findmnt', [
    '--json',
    '--list',
    '--output',
    'TARGET,FSTYPE',
  ], stdout: '{"filesystems":[{"target":"/","fstype":"overlay"}]}');
  f.addResponse('cat', [
    '/usr/lib/ro-asd/release.json',
  ], stdout: jsonEncode(releaseMetadata));
  f.addResponse('blockdev', ['--getsize64', disk], stdout: '$diskBytes');
  f.addResponse(
    'sh',
    kernelQuery,
    stdout: '6.1-fixture\t/boot/vmlinuz-6.1-fixture\n',
  );
  f.addResponse(
    'rsync',
    sourceBudgetArguments,
    stdout: budgetStats ?? sourceBudgetStats,
    exitCode: budgetExitCode,
    started: budgetStarted,
  );
}

FakeCommandRunner healthy() {
  final f = FakeCommandRunner();
  configurePreparedSource(f);
  return f;
}
