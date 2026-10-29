import 'package:test/test.dart';
import 'package:ro_installer/services/mount_session.dart';

import '../support/mount_graph.dart';

Future<VerifiedMountSession> ready(MountGraph graph) async {
  final session = graph.session();
  await session.initialize();
  await session.validateTarget('/dev/fixture');
  return session;
}

Future<bool> root(VerifiedMountSession s) =>
    s.mount(['-o', 'compress=zstd:1,subvol=root', '/dev/fixture2', '/mnt']);
void main() {
  test(
    'inherited foreign target mount is preserved before any command',
    () async {
      final graph = MountGraph()..add('/mnt', device: '8:99');
      final s = graph.session();
      await expectLater(s.initialize(), throwsStateError);
      expect(graph.commandLog, isEmpty);
      expect((await s.cleanup()).success, isFalse);
      expect(graph.unmounts, 0);
    },
  );
  for (final field in ['lease', 'target', 'namespace']) {
    test('unverified session $field cannot start', () async {
      final g = MountGraph();
      if (field == 'lease') g.lease = false;
      if (field == 'target') g.targetSafe = false;
      if (field == 'namespace') g.ns = 'mnt:[1]';
      await expectLater(g.session().initialize(), throwsStateError);
      expect(g.commandLog, isEmpty);
    });
  }
  test('root/EFI are tracked and removed deepest first', () async {
    final g = MountGraph();
    final s = await ready(g);
    expect(await root(s), isTrue);
    expect(await s.mount(['/dev/fixture1', '/mnt/boot/efi']), isTrue);
    expect((await s.cleanup()).success, isTrue);
    expect(
      g.commandLog
          .where((c) => c.command == 'umount')
          .map((c) => c.args.single),
      ['/mnt/boot/efi', '/mnt'],
    );
    expect(g.rows.where((r) => r.target.startsWith('/mnt')), isEmpty);
  });
  test(
    'temporary top-level mount can be retired before standard root mount',
    () async {
      final g = MountGraph();
      final s = await ready(g);
      expect(
        await s.mount(['-o', 'subvolid=5', '/dev/fixture2', '/mnt']),
        isTrue,
      );
      expect(await s.unmount('/mnt'), isTrue);
      expect(await root(s), isTrue);
      expect((await s.cleanup()).success, isTrue);
    },
  );
  test(
    'partial rbind failure records every created child for cleanup',
    () async {
      final g = MountGraph()..partialBind = true;
      final s = await ready(g);
      await root(s);
      expect(await s.mount(['--rbind', '/dev', '/mnt/dev']), isFalse);
      expect((await s.cleanup()).success, isTrue);
      expect(
        g.commandLog
            .where((c) => c.command == 'umount')
            .map((c) => c.args.single),
        ['/mnt/dev/pts', '/mnt/dev', '/mnt'],
      );
    },
  );
  test(
    'mount throws after creating resource: snapshot still permits safe cleanup',
    () async {
      final g = MountGraph();
      final s = await ready(g);
      g.throwAfterMount = true;
      expect(await root(s), isFalse);
      expect((await s.cleanup()).success, isTrue);
      expect(g.unmounts, 1);
    },
  );
  test(
    'busy unmount fails, keeps original failure and is not retried into success',
    () async {
      final g = MountGraph()..busy.add('/mnt');
      final s = await ready(g);
      await root(s);
      final first = await s.cleanup();
      expect(first.success, isFalse);
      expect(first.remaining, ['/mnt']);
      g.busy.clear();
      expect((await s.cleanup()).success, isFalse);
      expect(g.unmounts, 1);
    },
  );
  test(
    'cleanup repeated after success never removes a new foreign mount',
    () async {
      final g = MountGraph();
      final s = await ready(g);
      await root(s);
      expect((await s.cleanup()).success, isTrue);
      g.add('/mnt', device: '8:99');
      expect((await s.cleanup()).success, isFalse);
      expect(g.unmounts, 1);
    },
  );
  for (final reuse in [false, true]) {
    test(
      'overmount or changed/reused ID never authorizes path unmount: reuse=$reuse',
      () async {
        final g = MountGraph();
        final s = await ready(g);
        await root(s);
        if (reuse) {
          final old = g.rows.removeLast();
          g.rows.add(
            MountRecord(
              old.id,
              old.parent,
              '8:99',
              '/',
              old.target,
              'ext4',
              '/dev/foreign',
            ),
          );
        } else {
          g.add('/mnt', device: '8:99');
        }
        expect((await s.cleanup()).success, isFalse);
        expect(g.unmounts, 0);
      },
    );
  }
  test('inventory or namespace failure refuses unsafe cleanup', () async {
    final g = MountGraph();
    final s = await ready(g);
    await root(s);
    g.failInventory = true;
    expect((await s.cleanup()).success, isFalse);
    expect(g.unmounts, 0);
    g.failInventory = false;
    g.ns = 'mnt:[3]';
    expect((await s.cleanup()).success, isFalse);
    expect(g.unmounts, 0);
  });
  test(
    'live children block cleanup before an unmount check/call race',
    () async {
      final g = MountGraph();
      final s = await ready(g);
      await root(s);
      g.idle = false;
      expect((await s.cleanup()).success, isFalse);
      expect(g.unmounts, 0);
    },
  );
  test('invalid or stacked inventory cannot create an ownership baseline', () {
    expect(() => MountRecord.parse('garbage'), throwsA(isA<Exception>()));
    expect(
      () => MountRecord.parse('1 0 0:1 / / rw shared:1 - overlay live rw'),
      throwsFormatException,
    );
    expect(
      () => MountRecord.parse(
        '1 0 0:1 / / rw - overlay live rw\n1 0 0:1 / /mnt rw - ext4 d rw',
      ),
      throwsFormatException,
    );
  });
  test(
    'mount path/source options outside the fixed layout are refused',
    () async {
      final g = MountGraph();
      final s = await ready(g);
      for (final args in [
        ['/dev/foreign', '/mnt'],
        ['--rbind', '/home', '/mnt/home'],
        ['-t', 'tmpfs', 'tmpfs', '/tmp/foreign'],
      ]) {
        expect(await s.mount(args), isFalse);
      }
      expect(g.commandLog, isEmpty);
    },
  );
}
