import 'dart:io';
import 'package:test/test.dart';
import 'package:ro_installer/services/network_service.dart';
import 'package:ro_installer/services/fake_command_runner.dart';

/// Fixture dosyasını okur
String fixture(String name) {
  return File('test/fixtures/$name').readAsStringSync();
}

void main() {
  group('NetworkService.checkEthernet()', () {
    test('ethernet bağlıysa true döner', () async {
      final fake = FakeCommandRunner();
      fake.addResponse('nmcli', [
        '-w',
        '2',
        '-t',
        '-f',
        'TYPE,STATE',
        'dev',
        'status',
      ], stdout: fixture('nmcli_ethernet_connected.txt').trim());

      final service = NetworkService(commandRunner: fake);
      final result = await service.checkEthernet();

      expect(result, true);
    });

    test('ethernet bağlı değilse false döner', () async {
      final fake = FakeCommandRunner();
      fake.addResponse('nmcli', [
        '-w',
        '2',
        '-t',
        '-f',
        'TYPE,STATE',
        'dev',
        'status',
      ], stdout: 'ethernet:disconnected\nwifi:connected');

      final service = NetworkService(commandRunner: fake);
      final result = await service.checkEthernet();

      expect(result, false);
    });

    test('nmcli başarısız olursa false döner', () async {
      final fake = FakeCommandRunner();
      fake.addResponse(
        'nmcli',
        ['-w', '2', '-t', '-f', 'TYPE,STATE', 'dev', 'status'],
        exitCode: 1,
        stderr: 'nmcli: command not found',
      );

      final service = NetworkService(commandRunner: fake);
      final result = await service.checkEthernet();

      expect(result, false);
    });
  });

  group('NetworkService.scanWifi()', () {
    test('Wi-Fi ağları doğru parse edilir', () async {
      final fake = FakeCommandRunner();
      fake.addResponse('nmcli', [
        '-w',
        '4',
        '-t',
        '-e',
        'no',
        '-f',
        'IN-USE,SIGNAL,SECURITY,SSID',
        'dev',
        'wifi',
        'list',
      ], stdout: fixture('nmcli_wifi_list.txt').trim());

      final service = NetworkService(commandRunner: fake);
      final networks = await service.scanWifi();

      expect(networks.isNotEmpty, true);

      // Bağlı ağlar önce gelmeli
      final connected = networks.where((n) => n['inUse'] == true).toList();
      expect(connected.length, greaterThanOrEqualTo(1));
      if (connected.isNotEmpty) {
        expect(
          networks.indexOf(connected.first),
          lessThan(networks.length ~/ 2),
        );
      }
    });

    test('SSID içinde : olan ağlar doğru parse edilir', () async {
      final fake = FakeCommandRunner();
      fake.addResponse('nmcli', [
        '-w',
        '4',
        '-t',
        '-e',
        'no',
        '-f',
        'IN-USE,SIGNAL,SECURITY,SSID',
        'dev',
        'wifi',
        'list',
      ], stdout: ':30:WPA2:Guest:Network');

      final service = NetworkService(commandRunner: fake);
      final networks = await service.scanWifi();

      expect(networks.length, 1);
      expect(networks[0]['ssid'], 'Guest:Network');
      expect(networks[0]['signal'], 30);
      expect(networks[0]['security'], 'WPA2');
    });

    test('aynı SSID tekrarlandığında en güçlü sinyal alınır', () async {
      final fake = FakeCommandRunner();
      fake.addResponse('nmcli', [
        '-w',
        '4',
        '-t',
        '-e',
        'no',
        '-f',
        'IN-USE,SIGNAL,SECURITY,SSID',
        'dev',
        'wifi',
        'list',
      ], stdout: ':30:WPA2:TestNet\n:80:WPA2:TestNet\n:50:WPA2:TestNet');

      final service = NetworkService(commandRunner: fake);
      final networks = await service.scanWifi();

      expect(networks.length, 1);
      expect(networks[0]['ssid'], 'TestNet');
      expect(networks[0]['signal'], 80);
    });

    test('boş Wi-Fi listesi boş döner', () async {
      final fake = FakeCommandRunner();
      fake.addResponse('nmcli', [
        '-w',
        '4',
        '-t',
        '-e',
        'no',
        '-f',
        'IN-USE,SIGNAL,SECURITY,SSID',
        'dev',
        'wifi',
        'list',
      ], stdout: '');

      final service = NetworkService(commandRunner: fake);
      final networks = await service.scanWifi();

      expect(networks, isEmpty);
    });

    test('802.1X ağları kurumsal olarak işaretlenir', () async {
      final fake = FakeCommandRunner();
      fake.addResponse('nmcli', [
        '-w',
        '4',
        '-t',
        '-e',
        'no',
        '-f',
        'IN-USE,SIGNAL,SECURITY,SSID',
        'dev',
        'wifi',
        'list',
      ], stdout: ':70:WPA2 802.1X:eduroam');

      final service = NetworkService(commandRunner: fake);
      final networks = await service.scanWifi();

      expect(networks.length, 1);
      expect(networks[0]['ssid'], 'eduroam');
      expect(networks[0]['enterprise'], true);
    });
  });

  group('NetworkService.connectWifi()', () {
    test(
      'WPA personal bağlantısından önce Wi-Fi radyosunu açar ve rescan yapar',
      () async {
        final fake = FakeCommandRunner(defaultSuccess: false);
        fake.addResponse('nmcli', ['-w', '5', 'radio', 'wifi', 'on']);
        fake.addResponse('nmcli', [
          '-w',
          '10',
          'dev',
          'wifi',
          'rescan',
          'ssid',
          'TestNet',
        ]);
        fake.addResponse('nmcli', [
          '-w',
          '35',
          'dev',
          'wifi',
          'connect',
          'TestNet',
          'password',
          'secret',
        ]);

        final service = NetworkService(commandRunner: fake);
        final result = await service.connectWifi('TestNet', 'secret');

        expect(result, true);
        expect(fake.commandNames.take(3), ['nmcli', 'nmcli', 'nmcli']);
      },
    );

    test('ilk WPA denemesi düşerse eski profili silip tekrar dener', () async {
      final fake = FakeCommandRunner(defaultSuccess: false);
      fake.addResponse('nmcli', ['-w', '5', 'radio', 'wifi', 'on']);
      fake.addResponse('nmcli', [
        '-w',
        '10',
        'dev',
        'wifi',
        'rescan',
        'ssid',
        'TestNet',
      ]);
      fake.addResponse(
        'nmcli',
        ['-w', '35', 'dev', 'wifi', 'connect', 'TestNet', 'password', 'secret'],
        exitCode: 10,
        stderr: 'Activation failed',
      );
      fake.addResponse('nmcli', ['connection', 'delete', 'id', 'TestNet']);
      fake.addResponse('nmcli', [
        '-w',
        '35',
        'dev',
        'wifi',
        'connect',
        'TestNet',
        'password',
        'secret',
      ]);

      final service = NetworkService(commandRunner: fake);
      final result = await service.connectWifi('TestNet', 'secret');

      expect(result, true);
      expect(
        fake.wasCalledWith('nmcli', ['connection', 'delete', 'id', 'TestNet']),
        true,
      );
    });

    test('kurumsal ağ için PEAP/MSCHAPv2 profil oluşturur', () async {
      final fake = FakeCommandRunner(defaultSuccess: false);
      fake.addResponse('nmcli', ['-w', '5', 'radio', 'wifi', 'on']);
      fake.addResponse('nmcli', [
        '-w',
        '10',
        'dev',
        'wifi',
        'rescan',
        'ssid',
        'eduroam',
      ]);
      fake.addResponse('nmcli', [
        'connection',
        'delete',
        'id',
        'Ro Wi-Fi eduroam',
      ]);
      fake.addResponse('nmcli', [
        'connection',
        'add',
        'type',
        'wifi',
        'ifname',
        '*',
        'con-name',
        'Ro Wi-Fi eduroam',
        'ssid',
        'eduroam',
      ]);
      fake.addResponse('nmcli', [
        'connection',
        'modify',
        'Ro Wi-Fi eduroam',
        'wifi-sec.key-mgmt',
        'wpa-eap',
        '802-1x.eap',
        'peap',
        '802-1x.phase2-auth',
        'mschapv2',
        '802-1x.identity',
        'user@example.edu',
        '802-1x.password',
        'secret',
        '802-1x.system-ca-certs',
        'no',
      ]);
      fake.addResponse('nmcli', [
        '-w',
        '45',
        'connection',
        'up',
        'Ro Wi-Fi eduroam',
      ]);

      final service = NetworkService(commandRunner: fake);
      final result = await service.connectWifi(
        'eduroam',
        'secret',
        security: 'WPA2 802.1X',
        identity: 'user@example.edu',
      );

      expect(result, true);
    });
  });
}
