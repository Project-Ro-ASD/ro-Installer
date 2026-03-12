import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state/installer_state.dart';
import '../ffi/backend_bindings.dart';

class InstallingScreen extends StatefulWidget {
  const InstallingScreen({super.key});

  @override
  State<InstallingScreen> createState() => _InstallingScreenState();
}

class _InstallingScreenState extends State<InstallingScreen> with SingleTickerProviderStateMixin {
  double _progress = 0.0;
  String _statusText = "Initializing partitions...";
  bool _isFinished = false;
  
  // Animasyon state değişkenleri
  bool _startExpansion = false;
  int _currentSlide = 0;
  Timer? _slideTimer;

  final List<String> _slideImages = [
    "assets/images/slide1.png",
    "assets/images/slide2.png",
    "assets/images/slide3.png",
  ];

  final List<String> _slideKeys = [
    "slide_1",
    "slide_2",
    "slide_3",
  ];

  @override
  void initState() {
    super.initState();
    // Animasyonu 1 sn sonra başlat
    Future.delayed(const Duration(seconds: 1), () {
      if (mounted) setState(() => _startExpansion = true);
    });

    // 5 saniyede bir slaytı değiştir
    _slideTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      if (mounted && !_isFinished) {
        setState(() {
          _currentSlide = (_currentSlide + 1) % _slideImages.length;
        });
      }
    });

    _startSetupProcess();
  }

  @override
  void dispose() {
    _slideTimer?.cancel();
    super.dispose();
  }

  void _showError(String message) {
    if (!mounted) return;
    setState(() {
      _statusText = "HATA: $message";
      _isFinished = true;
      _slideTimer?.cancel();
    });
  }

  Future<void> _startSetupProcess() async {
    final state = Provider.of<InstallerState>(context, listen: false);

    setState(() {
      _statusText = "Sistem ve disk ayarları alınıyor...";
      _progress = 0.1;
    });

    await Future.delayed(const Duration(seconds: 1)); // Animasyon icin 1 saniye mola

    bool success = true;

    // 1. DISK FORMAT VEYA SHRINK ISLEMLERI
    if (state.partitionMethod == 'alongside') {
      setState(() => _statusText = "Seçilen diskin eski işlemleri korunarak küçültülüyor (Shrink)...");
      success = await BackendBindings().shrinkPartition(state.selectedDisk, "${state.linuxDiskSizeGB.toInt()}GB");
      setState(() => _progress = 0.3);
    } else {
      setState(() => _statusText = "${state.selectedDisk} diskine ${state.fileSystem} formatı atılıyor...");
      success = await BackendBindings().formatPartition(state.selectedDisk, state.fileSystem);
      setState(() => _progress = 0.3);
    }

    if (!success) { _showError("Disk işlemleri sırasında kritik bir hata oluştu."); return; }

    // 2. DOSYA KOPYALAMA
    await Future.delayed(const Duration(seconds: 1)); // Gorsel
    setState(() {
      _statusText = "Kök dosya sistemi (${state.fileSystem}) hedefe aktarılıyor (Unsquashfs)...";
      _progress = 0.5;
    });
    
    // Live OS ortamina gore dinamik squashfs tespiti
    final potentialPaths = [
      "/run/initramfs/live/LiveOS/squashfs.img", // Fedora/Ro-ASD
      "/run/archiso/bootmnt/arch/x86_64/airootfs.sfs", // Arch
      "/run/miso/bootmnt/miso/x86_64/rootfs.sfs", // Manjaro
      "/cdrom/casper/filesystem.squashfs" // Ubuntu
    ];
    String squashfsPath = "/tmp/dummy.sfs"; // Fallback Test 
    for (var p in potentialPaths) {
      if (File(p).existsSync()) {
        squashfsPath = p;
        break;
      }
    }

    success = await BackendBindings().extractSystem(state.selectedDisk, squashfsPath);
    if (!success) { _showError("Sistem dosyaları hedefe çıkarılırken bir hata oluştu."); return; }

    // 3. CHROOT ISLEMLERI (Dil, Klavye, Kullanici)
    setState(() {
      _statusText = "Bölgesel ayarlar ve kullanıcınız (${state.username}) oluşturuluyor...";
      _progress = 0.7;
    });
    
    success = await BackendBindings().runInChroot(state.selectedDisk, "ln -sf /usr/share/zoneinfo/${state.selectedRegion} /etc/localtime");
    if (!success) { _showError("Zaman dilimi (/etc/localtime) hedefe ayarlanamadı."); return; }

    success = await BackendBindings().runInChroot(state.selectedDisk, "useradd -m -g users -G wheel,storage,power,network -s /bin/bash ${state.username}");
    if (!success) { _showError("Yeni kullanıcı oluşturulamadı."); return; }

    success = await BackendBindings().runInChroot(state.selectedDisk, "echo '${state.username}:${state.password}' | chpasswd");
    if (!success) { _showError("Kullanıcı parolası atanamadı."); return; }

    if (state.isAdministrator) {
         await BackendBindings().runInChroot(state.selectedDisk, "echo '${state.username} ALL=(ALL:ALL) ALL' > /etc/sudoers.d/${state.username}");
    }

    // 4. OZEL REPOLAR VE TEMALAR (Ro-ASD)
    setState(() {
      _statusText = "Ro-ASD özel depoları ve sistem temaları yükleniyor...";
      _progress = 0.85;
    });

    await BackendBindings().runInChroot(state.selectedDisk, "git clone https://github.com/Project-Ro-ASD/Ro-Repo.git /opt/Ro-Repo");
    await BackendBindings().runInChroot(state.selectedDisk, "cp /opt/Ro-Repo/*.repo /etc/yum.repos.d/ 2>/dev/null || true");

    await BackendBindings().runInChroot(state.selectedDisk, "git clone https://github.com/Project-Ro-ASD/ro-theme.git /tmp/ro-theme");
    await BackendBindings().runInChroot(state.selectedDisk, "cd /tmp/ro-theme && (chmod +x install.sh && ./install.sh || cp -r . /usr/share/themes/Ro-Theme)");

    // 5. BOOTLOADER ISLEMLERI (rEFInd)
    setState(() {
      _statusText = "Sistem bootloader yapılandırması (rEFInd) EFI bölümüne gömülüyor...";
      _progress = 0.95;
    });
    
    success = await BackendBindings().runInChroot(state.selectedDisk, "refind-install");
    if (!success) { _showError("Bootloader (rEFInd) diske yüklenemedi. Kernel boot edemez."); return; }
    
    // Kurulum bittikten sonra un-mount islemleri temizlik. (Suanlik chroot'u C++ disindan sarmalayip umount atmamiz gerekir)
    // Bunun icin C++ a umount eklemek yerine terminalden gecici olarak SystemCommand unwrap sekilde halledilebilir (ileriki c++ FFI eklentisinde halledecegiz).
    
    // BITIS
    setState(() {
      _progress = 1.0;
      _isFinished = true;
      _statusText = state.t('install_done');
      _slideTimer?.cancel();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = Provider.of<InstallerState>(context);
    final isDark = theme.brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black87;

    return AnimatedContainer(
      duration: const Duration(seconds: 1),
      curve: Curves.easeInOutBack,
      width: double.infinity,
      // Animasyon: Başta kısa olup, sonra ekranı dikeyde uzatan bar etkisi
      height: _startExpansion ? MediaQuery.of(context).size.height * 0.8 : 100,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            _isFinished ? state.t('install_done') : state.t('installing'),
            style: theme.textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.bold,
              color: textColor,
            ),
          ),
          const SizedBox(height: 20),

          if (!_isFinished) ...[
            Text(_statusText, style: TextStyle(color: textColor.withOpacity(0.6))),
            const SizedBox(height: 20),
            
            // Yüzde Barı: Geniş
            Container(
              width: 500,
              height: 12,
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1E1E2E) : Colors.grey.withOpacity(0.2),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Stack(
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    width: 500 * _progress,
                    height: 12,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary,
                      borderRadius: BorderRadius.circular(6),
                      boxShadow: [
                        BoxShadow(
                          color: theme.colorScheme.primary.withOpacity(0.6),
                          blurRadius: 10,
                          spreadRadius: 1,
                        )
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 40),

            // Slayt Gösterisi
            if (_startExpansion)
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 800),
                  transitionBuilder: (child, animation) => FadeTransition(opacity: animation, child: child),
                  child: Container(
                    key: ValueKey(_currentSlide),
                    width: 600,
                    margin: const EdgeInsets.symmetric(vertical: 20),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(24),
                      image: DecorationImage(
                        image: AssetImage(_slideImages[_currentSlide]),
                        fit: BoxFit.cover,
                        colorFilter: ColorFilter.mode(Colors.black.withOpacity(0.3), BlendMode.darken),
                      ),
                      border: Border.all(color: theme.colorScheme.primary.withOpacity(0.5), width: 2),
                    ),
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: Padding(
                        padding: const EdgeInsets.all(32.0),
                        child: Text(
                          state.t(_slideKeys[_currentSlide]),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                            shadows: [Shadow(color: Colors.black.withOpacity(0.8), blurRadius: 10)],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],

          if (_isFinished) ...[
            const SizedBox(height: 40),
            Icon(Icons.task_alt, size: 100, color: theme.colorScheme.primary),
            const SizedBox(height: 40),
            ElevatedButton.icon(
              onPressed: () {
                debugPrint("Sistem yeniden başlatılıyor (Reboot FFI Call)...");
              },
              icon: const Icon(Icons.restart_alt),
              label: Text(state.t('restart')),
              style: theme.elevatedButtonTheme.style?.copyWith(
                padding: const WidgetStatePropertyAll(
                  EdgeInsets.symmetric(horizontal: 48, vertical: 24),
                ),
                backgroundColor: WidgetStatePropertyAll(theme.colorScheme.primary),
                foregroundColor: const WidgetStatePropertyAll(Colors.white),
              ),
            ),
          ]
        ],
      ),
    );
  }
}
