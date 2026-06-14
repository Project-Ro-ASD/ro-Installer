import 'command_runner.dart';

class WifiConnectionResult {
  const WifiConnectionResult({required this.success, this.message = ''});

  final bool success;
  final String message;
}

class NetworkService {
  NetworkService({CommandRunner? commandRunner})
    : _commandRunner = commandRunner ?? CommandRunner.instance;

  /// Varsayılan singleton erişimi (geriye uyumluluk için)
  static final NetworkService instance = NetworkService();

  final CommandRunner _commandRunner;

  Future<bool> checkEthernet() async {
    try {
      final result = await _commandRunner.run('nmcli', [
        '-w',
        '2',
        '-t',
        '-f',
        'TYPE,STATE',
        'dev',
        'status',
      ], timeout: const Duration(seconds: 5));
      if (result.exitCode == 0) {
        final lines = result.stdout.split('\n');
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
      final result = await _commandRunner.run('nmcli', [
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
      ], timeout: const Duration(seconds: 8));

      if (result.exitCode == 0) {
        final lines = result.stdout.trim().split('\n');
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
              final existingIndex = networks.indexWhere(
                (n) => n['ssid'] == ssid,
              );
              if (existingIndex >= 0) {
                if (signal > networks[existingIndex]['signal']) {
                  networks[existingIndex] = {
                    'inUse': inUse || networks[existingIndex]['inUse'],
                    'signal': signal,
                    'security': security,
                    'enterprise': _isEnterpriseSecurity(security),
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
                  'enterprise': _isEnterpriseSecurity(security),
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

  Future<bool> connectWifi(
    String ssid,
    String password, {
    bool isMock = false,
    String security = '',
    String identity = '',
    String anonymousIdentity = '',
    bool enterprise = false,
    String eapMethod = 'peap',
    String phase2Auth = 'mschapv2',
  }) async {
    final result = await connectWifiDetailed(
      ssid,
      password,
      isMock: isMock,
      security: security,
      identity: identity,
      anonymousIdentity: anonymousIdentity,
      enterprise: enterprise,
      eapMethod: eapMethod,
      phase2Auth: phase2Auth,
    );
    return result.success;
  }

  Future<WifiConnectionResult> connectWifiDetailed(
    String ssid,
    String password, {
    bool isMock = false,
    String security = '',
    String identity = '',
    String anonymousIdentity = '',
    bool enterprise = false,
    String eapMethod = 'peap',
    String phase2Auth = 'mschapv2',
  }) async {
    if (isMock) {
      // Simülasyon modunda ağ ayarlarını değiştirmiyoruz.
      await Future.delayed(const Duration(seconds: 1));
      return const WifiConnectionResult(success: true);
    }

    try {
      await _runNmcliQuiet(['-w', '5', 'radio', 'wifi', 'on']);
      await _runNmcliQuiet(['-w', '10', 'dev', 'wifi', 'rescan', 'ssid', ssid]);

      final shouldUseEnterprise = enterprise || _isEnterpriseSecurity(security);
      if (shouldUseEnterprise) {
        return _connectEnterpriseWifi(
          ssid: ssid,
          password: password,
          identity: identity,
          anonymousIdentity: anonymousIdentity,
          eapMethod: eapMethod,
          phase2Auth: phase2Auth,
        );
      }

      return _connectPersonalWifi(ssid: ssid, password: password);
    } catch (e) {
      return WifiConnectionResult(success: false, message: e.toString());
    }
  }

  Future<WifiConnectionResult> _connectPersonalWifi({
    required String ssid,
    required String password,
  }) async {
    final args = ['-w', '35', 'dev', 'wifi', 'connect', ssid];
    if (password.isNotEmpty) {
      args.addAll(['password', password]);
    }

    var result = await _commandRunner.run(
      'nmcli',
      args,
      timeout: const Duration(seconds: 40),
    );
    if (result.exitCode == 0) {
      return const WifiConnectionResult(success: true);
    }

    final firstError = _nmcliError(result);
    if (_looksEnterpriseRequired(firstError)) {
      return WifiConnectionResult(
        success: false,
        message: 'Bu ağ kurumsal/eduroam ayarları gerektiriyor olabilir.',
      );
    }

    // NetworkManager bazen aynı SSID için eski/bozuk bir bağlantı profilini
    // tekrar kullanır. Live ortamda ikinci denemeden önce profili temizlemek
    // doğru parolanın gereksiz yere reddedilmesini azaltır.
    await _runNmcliQuiet(['connection', 'delete', 'id', ssid]);

    result = await _commandRunner.run(
      'nmcli',
      args,
      timeout: const Duration(seconds: 40),
    );
    if (result.exitCode == 0) {
      return const WifiConnectionResult(success: true);
    }

    return WifiConnectionResult(success: false, message: _nmcliError(result));
  }

  Future<WifiConnectionResult> _connectEnterpriseWifi({
    required String ssid,
    required String password,
    required String identity,
    required String anonymousIdentity,
    required String eapMethod,
    required String phase2Auth,
  }) async {
    if (identity.trim().isEmpty) {
      return const WifiConnectionResult(
        success: false,
        message: 'Kurumsal ağ için kullanıcı adı/kimlik gerekli.',
      );
    }

    final connectionName = 'Ro Wi-Fi $ssid';
    await _runNmcliQuiet(['connection', 'delete', 'id', connectionName]);

    var result = await _commandRunner.run('nmcli', [
      'connection',
      'add',
      'type',
      'wifi',
      'ifname',
      '*',
      'con-name',
      connectionName,
      'ssid',
      ssid,
    ], timeout: const Duration(seconds: 15));
    if (result.exitCode != 0) {
      return WifiConnectionResult(success: false, message: _nmcliError(result));
    }

    final modifyArgs = [
      'connection',
      'modify',
      connectionName,
      'wifi-sec.key-mgmt',
      'wpa-eap',
      '802-1x.eap',
      _normalizeEapMethod(eapMethod),
      '802-1x.phase2-auth',
      _normalizePhase2Auth(phase2Auth),
      '802-1x.identity',
      identity.trim(),
      '802-1x.password',
      password,
      '802-1x.system-ca-certs',
      'no',
    ];
    if (anonymousIdentity.trim().isNotEmpty) {
      modifyArgs.addAll([
        '802-1x.anonymous-identity',
        anonymousIdentity.trim(),
      ]);
    }

    result = await _commandRunner.run(
      'nmcli',
      modifyArgs,
      timeout: const Duration(seconds: 15),
    );
    if (result.exitCode != 0) {
      return WifiConnectionResult(success: false, message: _nmcliError(result));
    }

    result = await _commandRunner.run('nmcli', [
      '-w',
      '45',
      'connection',
      'up',
      connectionName,
    ], timeout: const Duration(seconds: 50));
    if (result.exitCode == 0) {
      return const WifiConnectionResult(success: true);
    }

    return WifiConnectionResult(success: false, message: _nmcliError(result));
  }

  Future<void> _runNmcliQuiet(List<String> args) async {
    try {
      await _commandRunner.run(
        'nmcli',
        args,
        timeout: const Duration(seconds: 15),
      );
    } catch (_) {
      // Hazırlık/temizlik komutları bağlantı denemesini tek başına düşürmez.
    }
  }

  String _nmcliError(CommandResult result) {
    final text = '${result.stderr}\n${result.stdout}'.trim();
    if (text.isEmpty) {
      return 'nmcli exit code ${result.exitCode}';
    }
    return text.split('\n').map((line) => line.trim()).join(' ').trim();
  }

  bool _looksEnterpriseRequired(String text) {
    final lower = text.toLowerCase();
    return lower.contains('802.1x') ||
        lower.contains('wpa-eap') ||
        lower.contains('enterprise') ||
        lower.contains('secrets were required but not provided');
  }

  static bool _isEnterpriseSecurity(String security) {
    final normalized = security.toLowerCase();
    return normalized.contains('802.1x') ||
        normalized.contains('wpa-eap') ||
        normalized.contains('enterprise');
  }

  String _normalizeEapMethod(String value) {
    final normalized = value.toLowerCase().trim();
    if (normalized == 'ttls') {
      return 'ttls';
    }
    return 'peap';
  }

  String _normalizePhase2Auth(String value) {
    final normalized = value.toLowerCase().trim();
    if (normalized == 'pap') {
      return 'pap';
    }
    return 'mschapv2';
  }
}
