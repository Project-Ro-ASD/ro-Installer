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
      fake.addResponse(
        'nmcli',
        ['-t', '-f', 'TYPE,STATE', 'dev', 'status'],
        stdout: fixture('nmcli_ethernet_connected.txt').trim(),
      );

      final service = NetworkService(commandRunner: fake);
      final result = await service.checkEthernet();

      expect(result, true);
    });

    test('ethernet bağlı değilse false döner', () async {
      final fake = FakeCommandRunner();
      fake.addResponse(
        'nmcli',
        ['-t', '-f', 'TYPE,STATE', 'dev', 'status'],
        stdout: 'ethernet:disconnected\nwifi:connected',
      );

      final service = NetworkService(commandRunner: fake);
      final result = await service.checkEthernet();

      expect(result, false);
    });

    test('nmcli başarısız olursa false döner', () async {
      final fake = FakeCommandRunner();
      fake.addResponse(
        'nmcli',
        ['-t', '-f', 'TYPE,STATE', 'dev', 'status'],
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
      fake.addResponse(
        'nmcli',
        ['-t', '-e', 'no', '-f', 'IN-USE,SIGNAL,SECURITY,SSID', 'dev', 'wifi', 'list'],
        stdout: fixture('nmcli_wifi_list.txt').trim(),
      );

      final service = NetworkService(commandRunner: fake);
      final networks = await service.scanWifi();

      expect(networks.isNotEmpty, true);

      // Bağlı ağlar önce gelmeli
      final connected = networks.where((n) => n['inUse'] == true).toList();
      expect(connected.length, greaterThanOrEqualTo(1));
      if (connected.isNotEmpty) {
        expect(networks.indexOf(connected.first), lessThan(networks.length ~/ 2));
      }
    });

    test('SSID içinde : olan ağlar doğru parse edilir', () async {
      final fake = FakeCommandRunner();
      fake.addResponse(
        'nmcli',
        ['-t', '-e', 'no', '-f', 'IN-USE,SIGNAL,SECURITY,SSID', 'dev', 'wifi', 'list'],
        stdout: ':30:WPA2:Guest:Network',
      );

      final service = NetworkService(commandRunner: fake);
      final networks = await service.scanWifi();

      expect(networks.length, 1);
      expect(networks[0]['ssid'], 'Guest:Network');
      expect(networks[0]['signal'], 30);
      expect(networks[0]['security'], 'WPA2');
    });

    test('aynı SSID tekrarlandığında en güçlü sinyal alınır', () async {
      final fake = FakeCommandRunner();
      fake.addResponse(
        'nmcli',
        ['-t', '-e', 'no', '-f', 'IN-USE,SIGNAL,SECURITY,SSID', 'dev', 'wifi', 'list'],
        stdout: ':30:WPA2:TestNet\n:80:WPA2:TestNet\n:50:WPA2:TestNet',
      );

      final service = NetworkService(commandRunner: fake);
      final networks = await service.scanWifi();

      expect(networks.length, 1);
      expect(networks[0]['ssid'], 'TestNet');
      expect(networks[0]['signal'], 80);
    });

    test('boş Wi-Fi listesi boş döner', () async {
      final fake = FakeCommandRunner();
      fake.addResponse(
        'nmcli',
        ['-t', '-e', 'no', '-f', 'IN-USE,SIGNAL,SECURITY,SSID', 'dev', 'wifi', 'list'],
        stdout: '',
      );

      final service = NetworkService(commandRunner: fake);
      final networks = await service.scanWifi();

      expect(networks, isEmpty);
    });
  });
}
