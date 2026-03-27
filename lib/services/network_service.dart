import 'dart:io';

class NetworkService {
  NetworkService._();
  static final NetworkService instance = NetworkService._();

  Future<bool> checkEthernet() async {
    try {
      final result = await Process.run('nmcli', ['-t', '-f', 'TYPE,STATE', 'dev', 'status']);
      if (result.exitCode == 0) {
        final lines = result.stdout.toString().split('\n');
        for (var line in lines) {
          if (line.startsWith('ethernet:connected')) {
            return true;
          }
        }
      }
    } catch (e) {
      // nmcli bulunamazsa false döner
    }
    return false;
  }

  Future<List<Map<String, dynamic>>> scanWifi() async {
    final List<Map<String, dynamic>> networks = [];
    try {
      // SSID sonunda yer alıyor, bu nedenle split ederken SSID stringi bozulmaz
      final result = await Process.run('nmcli', ['-t', '-e', 'no', '-f', 'IN-USE,SIGNAL,SECURITY,SSID', 'dev', 'wifi', 'list']);
      
      if (result.exitCode == 0) {
        final lines = result.stdout.toString().trim().split('\n');
        for (var line in lines) {
          if (line.isEmpty) continue;
          final parts = line.split(':');
          
          if (parts.length >= 4) {
            final inUse = parts[0] == '*';
            final signal = int.tryParse(parts[1]) ?? 0;
            final security = parts[2];
            // SSID içerisinde `:` işareti varsa parçaları tekrardan birleştir
            final ssid = parts.sublist(3).join(':').trim();

            if (ssid.isNotEmpty) {
              // Aynı SSID'li ağlarda en güçlü sinyale sahip olanı (veya aktif olanı) tut
              final existingIndex = networks.indexWhere((n) => n['ssid'] == ssid);
              if (existingIndex >= 0) {
                 if (signal > networks[existingIndex]['signal']) {
                    networks[existingIndex] = {
                      'inUse': inUse || networks[existingIndex]['inUse'],
                      'signal': signal,
                      'security': security,
                      'ssid': ssid,
                    };
                 }
                 if (inUse) {
                    networks[existingIndex]['inUse'] = true;
                 }
              } else {
                 networks.add({
                  'inUse': inUse,
                  'signal': signal,
                  'security': security,
                  'ssid': ssid,
                });
              }
            }
          }
        }
      }
    } catch (e) {
      // Hata durumunda boş liste döner
    }
    
    // Sıralama (Önce aktif olan, ardından sinyal gücüne göre)
    networks.sort((a, b) {
      if (a['inUse'] && !b['inUse']) return -1;
      if (!a['inUse'] && b['inUse']) return 1;
      return (b['signal'] as int).compareTo(a['signal'] as int);
    });
    
    return networks;
  }

  Future<bool> connectWifi(String ssid, String password, {bool isMock = false}) async {
    if (isMock) {
      // Simülasyon modunda ağ ayarlarını değiştirmiyoruz.
      await Future.delayed(const Duration(seconds: 1));
      return true;
    }
    try {
      final List<String> args = ['dev', 'wifi', 'connect', ssid];
      if (password.isNotEmpty) {
        args.addAll(['password', password]);
      }
      final result = await Process.run('nmcli', args);
      // Exit code 0 başarlı demek.
      return result.exitCode == 0;
    } catch (e) {
      return false;
    }
  }
}
