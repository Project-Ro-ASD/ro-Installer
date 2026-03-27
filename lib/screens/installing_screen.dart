import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state/installer_state.dart';
import '../services/install_service.dart';

class InstallingScreen extends StatefulWidget {
  const InstallingScreen({super.key});

  @override
  State<InstallingScreen> createState() => _InstallingScreenState();
}

class _InstallingScreenState extends State<InstallingScreen> with SingleTickerProviderStateMixin {
  double _progress = 0.0;
  String _statusText = "Sistem yapılandırması başlatılıyor...";
  bool _isFinished = false;
  
  // Custom Log list for Terminal overlay
  final List<String> _logs = [];
  final ScrollController _scrollController = ScrollController();
  
  // Animation state
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
    Future.delayed(const Duration(seconds: 1), () {
      if (mounted) setState(() => _startExpansion = true);
    });

    _slideTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      if (mounted && !_isFinished) {
        setState(() {
          _currentSlide = (_currentSlide + 1) % _slideImages.length;
        });
      }
    });

    _startRealInstallation();
  }

  @override
  void dispose() {
    _slideTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  void _pushLog(String logMsg) {
     if (!mounted) return;
     setState(() {
        _logs.add(logMsg);
     });
     // Auto scroll
     WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
           _scrollController.animateTo(
             _scrollController.position.maxScrollExtent, 
             duration: const Duration(milliseconds: 300), 
             curve: Curves.easeOut
           );
        }
     });
  }

  Future<void> _startRealInstallation() async {
    final state = Provider.of<InstallerState>(context, listen: false);

    await Future.delayed(const Duration(seconds: 1)); 

    final Map<String, dynamic> stateMap = {
      'selectedDisk': state.selectedDisk,
      'partitionMethod': state.partitionMethod,
      'fileSystem': state.fileSystem,
      'manualPartitions': state.manualPartitions,
      'username': state.username,
      'password': state.password,
      'selectedRegion': state.selectedRegion,
      'isAdministrator': state.isAdministrator,
      // Alongside (Yanına Kur) motoru için
      'linuxDiskSizeGB': state.linuxDiskSizeGB,
      'hasExistingEfi': state.hasExistingEfi,
      'existingEfiPartition': state.existingEfiPartition,
    };

    bool success = await InstallService.instance.runInstall(stateMap, (progress, status) {
       if (!mounted) return;
       // -1 signifies just a log entry
       if (progress < 0) {
          _pushLog(status);
       } else {
          setState(() {
             _progress = progress;
             _statusText = status;
          });
          _pushLog("[SİSTEM DURUMU] $status");
       }
    }, isMock: state.isMockEnabled);

    if (!mounted) return;
    
    if (success) {
      setState(() {
        _progress = 1.0;
        _isFinished = true;
        _statusText = "Sistem başarıyla kuruldu!";
        _slideTimer?.cancel();
      });
    } else {
      setState(() {
        _statusText = "KURULUM HATASI (Detaylar için loglara göz atın).";
        _isFinished = true;
        _slideTimer?.cancel();
      });
    }
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
      height: _startExpansion ? MediaQuery.of(context).size.height * 0.8 : 100,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            _isFinished ? (_progress >= 1.0 ? "Kurulum Tamamlandı" : "Hata Oluştu") : state.t('installing'),
            style: theme.textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.bold,
              color: textColor,
            ),
          ),
          const SizedBox(height: 20),

          Text(_statusText, style: TextStyle(color: _statusText.contains('HATA') ? Colors.redAccent : textColor.withOpacity(0.6), fontWeight: FontWeight.bold)),
          const SizedBox(height: 20),
          
          // Yüzde Barı
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
                    color: _statusText.contains('HATA') ? Colors.redAccent : theme.colorScheme.primary,
                    borderRadius: BorderRadius.circular(6),
                    boxShadow: [
                      BoxShadow(
                        color: _statusText.contains('HATA') ? Colors.redAccent.withOpacity(0.6) : theme.colorScheme.primary.withOpacity(0.6),
                        blurRadius: 10,
                        spreadRadius: 1,
                      )
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          // Log Penceresi (Gerçek zamanlı Terminal çıktısı)
          if (_startExpansion)
             Container(
                width: 600,
                height: 150,
                margin: const EdgeInsets.symmetric(vertical: 10),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                   color: Colors.black.withOpacity(0.8),
                   borderRadius: BorderRadius.circular(12),
                   border: Border.all(color: Colors.white24)
                ),
                child: ListView.builder(
                   controller: _scrollController,
                   itemCount: _logs.length,
                   itemBuilder: (context, index) {
                      return Text(
                         _logs[index],
                         style: const TextStyle(color: Colors.greenAccent, fontFamily: 'monospace', fontSize: 11),
                      );
                   },
                ),
             ),

          // Slayt Gösterisi
          if (_startExpansion && !_statusText.contains('HATA'))
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 800),
                transitionBuilder: (child, animation) => FadeTransition(opacity: animation, child: child),
                child: Container(
                  key: ValueKey(_currentSlide),
                  width: 600,
                  margin: const EdgeInsets.symmetric(vertical: 10),
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

          if (_isFinished) ...[
            const SizedBox(height: 20),
            Icon(_progress >= 1.0 ? Icons.task_alt : Icons.error_outline, size: 80, color: _progress >= 1.0 ? theme.colorScheme.primary : Colors.red),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: () {
                // TODO: Gercek reboot at (Process.run('reboot', []))
              },
              icon: const Icon(Icons.restart_alt),
              label: Text(state.t('restart')),
              style: theme.elevatedButtonTheme.style?.copyWith(
                padding: const WidgetStatePropertyAll(
                  EdgeInsets.symmetric(horizontal: 48, vertical: 24),
                ),
                backgroundColor: WidgetStatePropertyAll(_progress >= 1.0 ? theme.colorScheme.primary : Colors.grey),
                foregroundColor: const WidgetStatePropertyAll(Colors.white),
              ),
            ),
          ]
        ],
      ),
    );
  }
}
