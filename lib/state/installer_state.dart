import 'dart:async';
import 'package:flutter/material.dart';
import '../services/network_service.dart';
import '../services/disk_service.dart';

class InstallerState extends ChangeNotifier {
  int _currentStep = 0;
  int get currentStep => _currentStep;

  InstallerState() {
    _initNetworkChecker();
  }

  Timer? _networkTimer;

  void _initNetworkChecker() {
    // İlk çalıştırma
    _checkNetworkPeriodically();
    // Ardından her 5 saniyede bir kontrol et
    _networkTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
       _checkNetworkPeriodically();
    });
  }

  @override
  void dispose() {
    _networkTimer?.cancel();
    super.dispose();
  }

  Future<void> _checkNetworkPeriodically() async {
     final wasEthernetConnected = isEthernetConnected;
     isEthernetConnected = await NetworkService.instance.checkEthernet();
     
     if (wasEthernetConnected != isEthernetConnected) {
        // Otomatik bağlantı ayarı
        if (isEthernetConnected) networkStatus = 'connected';
        notifyListeners();
     }
  }

  Future<void> scanWifiNetworks() async {
     isScanningWifi = true;
     notifyListeners();
     
     wifiNetworks = await NetworkService.instance.scanWifi();
     
     // Halihazırda bağlı Wi-Fi varsa statüyü connected yap
     final isWifiConnected = wifiNetworks.any((net) => net['inUse'] == true);
     if (isWifiConnected && networkStatus == 'offline') {
         networkStatus = 'connected';
     }
     
     isScanningWifi = false;
     notifyListeners();
  }

  Future<bool> connectToWifi(String ssid, String password) async {
     final success = await NetworkService.instance.connectWifi(ssid, password, isMock: isMockEnabled);
     if (success) {
       await scanWifiNetworks(); // Listeyi yenile
       networkStatus = 'connected';
       notifyListeners();
     }
     return success;
  }

  // Adımlar listesi (Dinamik - partitionMethod ve installType'a göre şekillenir)
  List<String> get steps {
    List<String> baseSteps = ["Welcome", "Theme", "Location", "Network", "Account", "Type", "Disk"];
    
    if (partitionMethod == 'manual') {
      baseSteps.add("Partitions");
    }
    
    // Standart kurulumda Kernel adımı kullanıcıya gösterilmez (Atlanır)
    if (installType == 'advanced') {
      baseSteps.add("Kernel");
    }
    
    baseSteps.add("Install");
    return baseSteps;
  }

  // ---- Geliştirici & Test Modu ----
  bool isDeveloperMode = false; // Geliştirici arayüz elemanlarını (varsa) gizler
  bool isMockEnabled = false;   // GERÇEK KURULUM MODU: FFI/Sistem komutları DİREKT olarak çalıştırılır!

  // ---- 1. Welcome ----
  String selectedLanguage = 'tr'; // Varsayılan Türkçe

  // ---- 2. Theme ----
  String themeMode = 'dark'; // 'light' veya 'dark'

  // ---- 3. Location ----
  String selectedRegion = 'Türkiye';
  String selectedTimezone = 'Europe/Istanbul';
  String selectedKeyboard = 'trq';

  // ---- 4. Network ----
  String networkStatus = 'offline'; // 'offline' or 'connected'
  bool isEthernetConnected = false;
  List<Map<String, dynamic>> wifiNetworks = [];
  bool isScanningWifi = false;
  
  // ---- 5. Account ----
  String fullName = 'Geliştirici Test';
  String username = '1234';
  String password = '1234';
  bool isAdministrator = true;
  
  // ---- 6. Type ----
  String installType = 'standard'; // Deneysel varsayılan
  
  // ---- 7. Disk ----
  String selectedDisk = '';
  Map<String, dynamic>? selectedDiskDetails;
  double totalDiskSizeGB = 120.0; 
  String fileSystem = 'btrfs'; // Deneysel için btrfs
  String partitionMethod = 'full'; 
  double linuxDiskSizeGB = 60.0; 

  // Manuel Bölümlendirme Planı / Haritası
  List<Map<String, dynamic>> manualPartitions = [];

  // ---- Alongside (Yanına Kur) Algılama ----
  bool hasExistingOS = false;
  String detectedOS = '';
  bool hasExistingEfi = false;
  String existingEfiPartition = '';
  int diskFreeSpaceBytes = 0;
  bool isDetectingOS = false; // UI'da loading göstermek için
  
  // ---- 8. Kernel ----
  String kernelType = 'stable'; // Deneysel varsayılan

  // Navigasyon metodları
  void nextStep() {
    if (_currentStep < steps.length - 1) {
      _currentStep++;
      notifyListeners();
    }
  }

  void previousStep() {
    if (_currentStep > 0) {
      _currentStep--;
      notifyListeners();
    }
  }

  void goToStep(int stepIndex) {
    if (stepIndex >= 0 && stepIndex < steps.length && stepIndex <= _currentStep) {
      // Sadece ilerlediği adımlara veya geriye dönebilir
      _currentStep = stepIndex;
      notifyListeners();
    }
  }

  // State Güncelleme metodları
  void updateTheme(String mode) {
    themeMode = mode;
    notifyListeners();
  }

  void updateLanguage(String languageCode) {
    selectedLanguage = languageCode;
    notifyListeners();
  }

  void updateLocation({
    String? region,
    String? timezone,
    String? keyboard,
  }) {
    if (region != null) selectedRegion = region;
    if (timezone != null) selectedTimezone = timezone;
    if (keyboard != null) selectedKeyboard = keyboard;
    notifyListeners();
  }

  void updateInstallType(String type) {
    installType = type;
    // Eğer standart kurulum seçilirse, deneysel kernel kapatılıp otomatik stable yapılır
    if (type == 'standard') {
       kernelType = 'stable';
    }
    notifyListeners();
  }

  void updateKernel(String type) {
    kernelType = type;
    notifyListeners();
  }

  void updateAccount(String fName, String uName, String pass, bool isAdmin) {
    fullName = fName;
    username = uName;
    password = pass;
    isAdministrator = isAdmin;
    notifyListeners();
  }

  void updateDiskParams(String disk, String fs, String partition) {
    selectedDisk = disk;
    fileSystem = fs;
    partitionMethod = partition;
    notifyListeners();
  }

  void updateFileSystem(String fs) {
    fileSystem = fs;
    notifyListeners();
  }

  void updatePartitionMethod(String method) {
    partitionMethod = method;
    notifyListeners();
  }

  void updateLinuxDiskSize(double sizeGb) {
    linuxDiskSizeGB = sizeGb;
    notifyListeners();
  }

  void selectDisk(Map<String, dynamic> diskObj) {
    final newDisk = diskObj['name'] as String;
    // Eğer önceden seçilen disk ile yenisi farklıysa eski disk bölümlerini iptal et (Sıfırla)
    if (selectedDisk != newDisk) {
       manualPartitions.clear();
    }
    selectedDiskDetails = diskObj;
    selectedDisk = newDisk;
    
    // Boyutu Byte'dan GB'a çeviriyoruz
    final sizeBytes = diskObj['size'];
    if (sizeBytes != null && sizeBytes is int) {
       totalDiskSizeGB = sizeBytes / (1024 * 1024 * 1024);
       if (totalDiskSizeGB < 40) {
          totalDiskSizeGB = 40.0; // Slider patlamaması için min değer
       }
       linuxDiskSizeGB = totalDiskSizeGB - 20; // Varsayılan slider pozisyonu
    }
    notifyListeners();

    // Alongside için arka planda disk detaylarını çek
    _detectDiskOS(newDisk);
  }

  Future<void> _detectDiskOS(String diskName) async {
    isDetectingOS = true;
    notifyListeners();

    try {
      final details = await DiskService.instance.detectDiskDetails(diskName);
      hasExistingOS = details['hasExistingOS'] as bool;
      detectedOS = details['detectedOS'] as String;
      hasExistingEfi = details['hasEfiPartition'] as bool;
      existingEfiPartition = details['efiPartitionName'] as String;
      diskFreeSpaceBytes = details['freeSpaceBytes'] as int;
    } catch (e) {
      hasExistingOS = false;
      detectedOS = '';
      hasExistingEfi = false;
      existingEfiPartition = '';
      diskFreeSpaceBytes = 0;
    }

    isDetectingOS = false;
    notifyListeners();
  }
}

extension LocalizationExtension on InstallerState {
  static const Map<String, Map<String, String>> _translations = {
    'en': {
      'step_welcome': "Welcome",
      'step_theme': "Theme",
      'step_location': "Location",
      'step_network': "Network",
      'step_account': "Account",
      'step_type': "Type",
      'step_disk': "Disk",
      'step_partitions': "Partitions",
      'step_kernel': "Kernel",
      'step_install': "Install",
      'welcome_title': "Welcome to Ro-ASD",
      'welcome_desc': "Please select your system language to start a flawless, fast, and secure Linux experience.",
      'next': "Next",
      'prev': "Previous Step",
      'theme_title': "Personalize your space",
      'theme_desc': "Select a visual style for your installation and dashboard experience.",
      'light_theme': "Light Theme",
      'light_desc': "Vibrant, colorful and professional look for well-lit environments.",
      'dark_theme': "Dark Theme",
      'dark_desc': "Deep purple & navy tones optimized for reduced eye strain and modern aesthetics.",
      'location_title': "System Location & Input",
      'location_desc': "Set your physical location, timezone and preferred keyboard layout.",
      'region': "Region",
      'timezone': "Timezone",
      'kbd': "Keyboard Layout",
      'net_title': "Connect to Network",
      'net_desc': "Choose how you'd like to connect to the internet. A connection is required for real-time updates.",
      'wired': "WIRED CONNECTION",
      'wifi': "AVAILABLE WI-FI",
      'offline': "Continue Offline",
      'connect': "Connect & Continue",
      'acc_title': "Create User Account",
      'acc_desc': "Set up the primary user account for this system.",
      'admin': "Make Administrator",
      'admin_sub': "Grants root (sudo) privileges. Essential for system management.",
      'type_title': "Select Installation Type",
      'type_desc': "Choose the configuration that best suits your performance\nneeds and technical expertise.",
      'type_std_title': "Standard Installation",
      'type_std_desc': "Recommended for most users. Provides a stable environment with standard optimizations and automated configuration. Ideal for reliable long-term usage.",
      'type_std_btn': "Select Standard",
      'type_adv_title': "Experimental/Advanced",
      'type_adv_desc': "For power users and developers. Includes the latest experimental features, manual kernel configuration, and custom dependency management.",
      'type_adv_btn': "Select Advanced",
      'disk_title': "Disk Selection & Formatting",
      'disk_desc': "Select a target disk and preferred partition method. All data on the selected disk may be erased.",
      'disk_fs': "FILE SYSTEM",
      'disk_method': "INSTALLATION METHOD",
      'disk_full': "Erase Disk & Install\n(Recommended)",
      'disk_alongside': "Install Alongside\n(Dual Boot)",
      'disk_manual': "Manual Partitioning\n(Advanced)",
      'linux_size': "Ro-ASD Size",
      'windows_size': "Current OS Size",
      'part_badge': "STORAGE CONTROL",
      'part_title': "Manual Partitioning",
      'part_desc': "Create, delete, or format partitions. Minimum requirements: Root (/) partition and EFI System Partition.",
      'part_add': "Add Partition",
      'part_delete': "Delete",
      'part_format': "Format",
      'kernel_badge': "SYSTEM CONFIGURATION",
      'kernel_title': "Kernel Selector",
      'kernel_desc': "Configure your Ro-ASD environment by selecting between our battle-tested\nstable kernel or the latest experimental features.",
      'system_ram': "SYSTEM RAM",
      'ram_avail': "16GB / 32GB Available",
      'network': "NETWORK",
      'net_ready': "Ready for Download",
      'offline_status': "Offline",
      'kernel_stable_title': "Stable Kernel",
      'kernel_stable_desc': "Recommended for production environments. Features long-term support, maximum security patches, and optimal reliability for daily operations.",
      'kernel_s_feat1': "99.9% Uptime Guaranteed",
      'kernel_s_feat2': "Certified Security Modules",
      'kernel_exp_title': "Experimental",
      'kernel_exp_desc': "For enthusiasts and developers. Includes early access to multi-threading optimizations, new UI frameworks, and upcoming Ro-ASD API hooks.",
      'kernel_e_feat1': "30% Faster I/O Operations",
      'kernel_e_feat2': "Beta Feature Preview",
      'install_init': "Initialize Installation",
      'install_est': "Estimated install time: 4-6 minutes",
      'installing': "Installing Ro-ASD...",
      'install_done': "Installation Complete",
      'restart': "Restart System",
      'slide_1': "Discover the new Vibrancy UI",
      'slide_2': "Lightning fast BTRFS integration",
      'slide_3': "Uncompromising Experimental Features",
    },
    'tr': {
      'step_welcome': "Karşılama",
      'step_theme': "Tema",
      'step_location': "Konum",
      'step_network': "Ağ",
      'step_account': "Hesap",
      'step_type': "Tür",
      'step_disk': "Disk",
      'step_partitions': "Bölümler",
      'step_kernel': "Kernel",
      'step_install': "Kurulum",
      'welcome_title': "Ro-ASD'ye Hoş Geldiniz",
      'welcome_desc': "Kusursuz, hızlı ve güvenli bir Linux deneyimine başlamak için lütfen sistem dilinizi seçin.",
      'next': "İleri",
      'prev': "Önceki Adım",
      'theme_title': "Alanınızı Kişiselleştirin",
      'theme_desc': "Kurulum ve kullanım deneyiminiz için görsel bir stil seçin.",
      'light_theme': "Açık Tema",
      'light_desc': "Aydınlık ortamlar için canlı, renkli ve profesyonel bir görünüm.",
      'dark_theme': "Koyu Tema",
      'dark_desc': "Göz yorgunluğunu azaltmak için optimize edilmiş derin mor ve lacivert tonlar.",
      'location_title': "Bölge ve Giriş Ayarları",
      'location_desc': "Fiziksel konumunuzu, saat diliminizi ve klavye düzeninizi ayarlayın.",
      'region': "Bölge",
      'timezone': "Saat Dilimi",
      'kbd': "Klavye Düzeni",
      'net_title': "Ağa Bağlanın",
      'net_desc': "İnternete nasıl bağlanacağınızı seçin. Gerçek zamanlı güncellemeler için bağlantı gereklidir.",
      'wired': "KABLOLU BAĞLANTI",
      'wifi': "KULLANILABİLİR WI-FI",
      'offline': "Çevrimdışı Devam Et",
      'connect': "Bağlan ve İlerle",
      'acc_title': "Kullanıcı Hesabı Oluştur",
      'acc_desc': "Bu sistem için birincil kullanıcı hesabını ayarlayın.",
      'admin': "Yönetici Yap",
      'admin_sub': "Bu kullanıcıya tam yetki (root/sudo) verir. Sistem yönetimi için gereklidir.",
      'type_title': "Kurulum Tipini Seçin",
      'type_desc': "Performans ihtiyaçlarınıza ve teknik bilginize en uygun yapılandırmayı seçin.",
      'type_std_title': "Standart Kurulum",
      'type_std_desc': "Çoğu kullanıcı için önerilir. Standart optimizasyonlar ve yapılandırma ile kararlı bir ortam sunar.",
      'type_std_btn': "Standartı Seç",
      'type_adv_title': "Deneysel/Gelişmiş",
      'type_adv_desc': "Güçlü kullanıcılar ve geliştiriciler için. En son deneysel özellikleri ve manuel çekirdek ayarını içerir.",
      'type_adv_btn': "Gelişmişi Seç",
      'disk_title': "Disk Seçimi ve Biçimlendirme",
      'disk_desc': "Hedef diski ve bölümleme yöntemini seçin. Seçilen diskteki tüm veriler silinebilir.",
      'disk_fs': "DOSYA SİSTEMİ",
      'disk_method': "KURULUM YÖNTEMİ",
      'disk_full': "Tüm Diski Sil & Kur",
      'disk_alongside': "Yanına Kur\n(Windows/Linux ile)",
      'disk_manual': "Elle Bölümlendirme\n(Gelişmiş)",
      'linux_size': "Ro-ASD Alanı",
      'windows_size': "Mevcut OS Alanı",
      'part_badge': "DEPOLAMA KONTROLÜ",
      'part_title': "Elle Bölümlendirme",
      'part_desc': "Bölümler oluşturun, silin veya formatlayın. Minimum gereksinim: Kök (/) dizini ve EFI Sistem Bölümü.",
      'part_add': "Bölüm Ekle",
      'part_delete': "Sil",
      'part_format': "Format",
      'kernel_badge': "SİSTEM YAPILANDIRMASI",
      'kernel_title': "Kernel Seçici",
      'kernel_desc': "Kararlı çekirdek veya en yeni deneysel özellikler arasında seçim yapın.",
      'system_ram': "SİSTEM RAM",
      'ram_avail': "16GB / 32GB Kullanılabilir",
      'network': "AĞ BAĞLANTISI",
      'net_ready': "İndirmeye Hazır",
      'offline_status': "Çevrimdışı",
      'kernel_stable_title': "Kararlı Kernel",
      'kernel_stable_desc': "Üretim ortamları için önerilir. Uzun süreli destek ve onaylı güvenlik.",
      'kernel_s_feat1': "%99.9 Kesintisiz Çalışma Garantisi",
      'kernel_s_feat2': "Sertifikalı Güvenlik Modülleri",
      'kernel_exp_title': "Deneysel (Experimental)",
      'kernel_exp_desc': "Çoklu iş parçacığı optimizasyonlarına, yeni arayüzlere ve gelecek API hooklarına erken erişim.",
      'kernel_e_feat1': "%30 Daha Hızlı G/Ç İşlemleri",
      'kernel_e_feat2': "Beta Özellik Önizlemesi",
      'install_init': "Kurulumu Başlat",
      'install_est': "Tahmini kurulum süresi: 4-6 dakika",
      'installing': "Ro-ASD Kuruluyor...",
      'install_done': "Kurulum Tamamlandı",
      'restart': "Sistemi Yeniden Başlat",
      'slide_1': "Yeni Vibrancy Arayüzünü Keşfedin",
      'slide_2': "Yıldırım Hızında BTRFS Entegrasyonu",
      'slide_3': "Tavizsiz Deneysel Özellikler",
    },
    'es': {
      'step_welcome': "Inicio",
      'step_theme': "Tema",
      'step_location': "Ubicación",
      'step_network': "Red",
      'step_account': "Cuenta",
      'step_type': "Tipo",
      'step_disk': "Disco",
      'step_partitions': "Particiones",
      'step_kernel': "Kernel",
      'step_install': "Instalar",
      'welcome_title': "Bienvenido a Ro-ASD",
      'welcome_desc': "Seleccione el idioma de su sistema para comenzar una experiencia Linux impecable.",
      'next': "Siguiente",
      'prev': "Paso Anterior",
      'theme_title': "Personaliza tu espacio",
      'theme_desc': "Selecciona un estilo visual para tu experiencia de instalación.",
      'light_theme': "Tema Claro",
      'light_desc': "Aspecto vibrante, colorido y profesional.",
      'dark_theme': "Tema Oscuro",
      'dark_desc': "Tonos morados profundos optimizados.",
      'location_title': "Ubicación y Entrada",
      'location_desc': "Configura tu ubicación física, zona horaria y teclado preferido.",
      'region': "Región",
      'timezone': "Zona Horaria",
      'kbd': "Distribución del Teclado",
      'net_title': "Conectarse a la red",
      'net_desc': "Elige cómo te gustaría conectarte a internet.",
      'wired': "CONEXIÓN POR CABLE",
      'wifi': "WI-FI DISPONIBLE",
      'offline': "Continuar sin conexión",
      'connect': "Conectar y Continuar",
      'acc_title': "Crear Cuenta de Usuario",
      'acc_desc': "Configura la cuenta de usuario principal para este sistema.",
      'admin': "Hacer Administrador",
      'admin_sub': "Otorga privilegios de root (sudo). Esencial para administrar el sistema.",
      'type_title': "Seleccionar Tipo",
      'type_desc': "Elige la configuración que mejor se adapte a ti.",
      'type_std_title': "Instalación Estándar",
      'type_std_desc': "Recomendada para la mayoría. Proporciona un entorno estable y configuración automatizada.",
      'type_std_btn': "Seleccionar Estándar",
      'type_adv_title': "Avanzado/Experimental",
      'type_adv_desc': "Incluye las últimas características experimentales y configuración manual.",
      'type_adv_btn': "Seleccionar Avanzado",
      'disk_title': "Selección de Disco",
      'disk_desc': "Selecciona un disco de destino. Todos los datos podrían borrarse.",
      'disk_fs': "SISTEMA DE ARCHIVOS",
      'disk_method': "MÉTODO DE INSTALACIÓN",
      'disk_full': "Borrar Disco e Instalar",
      'disk_alongside': "Instalar Junto A\n(Dual Boot)",
      'disk_manual': "Particionamiento Manual",
      'linux_size': "Tamaño Ro-ASD",
      'windows_size': "Sistema Actual",
      'part_badge': "CONTROL DE ALMACENAMIENTO",
      'part_title': "Particionamiento Manual",
      'part_desc': "Crea, elimina o formatea particiones. Requisitos mínimos: / (Raíz) y UEFI.",
      'part_add': "Nueva Partición",
      'part_delete': "Eliminar",
      'part_format': "Formatear",
      'kernel_badge': "CONFIGURACIÓN",
      'kernel_title': "Selector de Kernel",
      'kernel_desc': "Configura tu entorno seleccionando el kernel adecuado.",
      'system_ram': "RAM DEL SISTEMA",
      'ram_avail': "16GB / 32GB Disponibles",
      'network': "RED",
      'net_ready': "Listo para Descargar",
      'offline_status': "Fuera de Línea",
      'kernel_stable_title': "Kernel Estable",
      'kernel_stable_desc': "Recomendado para entornos de producción con soporte a largo plazo.",
      'kernel_s_feat1': "99.9% Tiempo de Actividad",
      'kernel_s_feat2': "Módulos de Seguridad Certificados",
      'kernel_exp_title': "Experimental",
      'kernel_exp_desc': "Para entusiastas. Incluye acceso anticipado a optimizaciones y nuevas API.",
      'kernel_e_feat1': "I/O un 30% Más Rápido",
      'kernel_e_feat2': "Vista Previa Beta",
      'install_init': "Iniciar Instalación",
      'install_est': "Tiempo estimado: 4-6 minutos",
      'installing': "Instalando Ro-ASD...",
      'install_done': "Instalación Completada",
      'restart': "Reiniciar Sistema",
      'slide_1': "Descubre la nueva interfaz Vibrancy",
      'slide_2': "Integración BTRFS ultrarrápida",
      'slide_3': "Características Experimentales",
    }
  };

  String t(String key) {
    return _translations[selectedLanguage]?[key] ?? _translations['en']?[key] ?? key;
  }
}
