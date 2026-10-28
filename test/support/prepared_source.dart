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
void configurePreparedSource(
  FakeCommandRunner f, {
  String disk = "/dev/fixture",
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
  f.addResponse('blockdev', ['--getsize64', disk], stdout: '85899345920');
  f.addResponse(
    'sh',
    kernelQuery,
    stdout: '6.1-fixture\t/boot/vmlinuz-6.1-fixture\n',
  );
}

FakeCommandRunner healthy() {
  final f = FakeCommandRunner();
  configurePreparedSource(f);
  return f;
}
