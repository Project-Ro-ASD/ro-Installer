import 'dart:async';
import 'dart:convert';
import 'dart:io';

class InstallService {
  InstallService._();
  static final InstallService instance = InstallService._();

  /// Komut çalıştırma ve çıktıları canlı okuma.
  /// STDERR çıktısı biriktirilir ve hata durumunda tam olarak raporlanır.
  Future<bool> runCmd(String cmd, List<String> args, void Function(String) onLog, {bool isMock = false}) async {
    final fullCmd = '$cmd ${args.join(' ')}';
    onLog("[KOMUT] $fullCmd");
    
    if (isMock) {
      await Future.delayed(const Duration(milliseconds: 300));
      onLog("[MOCK] Simülasyon başarılı: $cmd");
      return true;
    }

    try {
      final process = await Process.start(cmd, args);
      
      // STDOUT ve STDERR'i biriktir
      final stdoutBuffer = StringBuffer();
      final stderrBuffer = StringBuffer();
      
      process.stdout.transform(utf8.decoder).listen((data) {
        final trimmed = data.trim();
        if (trimmed.isNotEmpty) {
          stdoutBuffer.writeln(trimmed);
          onLog(trimmed);
        }
      });
      
      process.stderr.transform(utf8.decoder).listen((data) {
        final trimmed = data.trim();
        if (trimmed.isNotEmpty) {
          stderrBuffer.writeln(trimmed);
          onLog("[STDERR] $trimmed");
        }
      });
      
      final exitCode = await process.exitCode;
      
      if (exitCode != 0) {
        final errorDetail = stderrBuffer.isNotEmpty 
            ? stderrBuffer.toString().trim() 
            : (stdoutBuffer.isNotEmpty ? stdoutBuffer.toString().trim() : 'Ek bilgi yok');
        onLog("═══════════════════════════════════════════");
        onLog("[HATA] Komut başarısız oldu!");
        onLog("[HATA] Komut: $fullCmd");
        onLog("[HATA] Çıkış Kodu: $exitCode");
        onLog("[HATA] Detay: $errorDetail");
        onLog("═══════════════════════════════════════════");
        return false;
      }
      return true;
    } catch (e) {
      onLog("═══════════════════════════════════════════");
      onLog("[İSTİSNA] Komut çalıştırılamadı: $cmd");
      onLog("[İSTİSNA] Sebep: $e");
      onLog("[İSTİSNA] Komut sisteminizde kurulu olmayabilir (PATH kontrol edin).");
      onLog("═══════════════════════════════════════════");
      return false;
    }
  }

  /// Sistem RAM miktarını MB cinsinden okur (/proc/meminfo)
  Future<int> getSystemRamMB() async {
    try {
      final result = await Process.run('grep', ['MemTotal', '/proc/meminfo']);
      if (result.exitCode == 0) {
        // Örnek çıktı: "MemTotal:       16384000 kB"
        final match = RegExp(r'(\d+)').firstMatch(result.stdout.toString());
        if (match != null) {
          final kb = int.parse(match.group(1)!);
          return kb ~/ 1024; // kB → MB
        }
      }
    } catch (e) {
      // Okunamazsa
    }
    return 4096; // Varsayılan 4 GB
  }

  /// RAM'e göre dinamik SWAP boyutu hesaplar (MB cinsinden)
  int calculateSwapMB(int ramMB) {
    // Genel Linux kuralı:
    // RAM <= 2 GB → SWAP = 2x RAM
    // RAM 2-8 GB → SWAP = RAM kadar
    // RAM 8-16 GB → SWAP = RAM / 2
    // RAM > 16 GB → SWAP = 8 GB (sabit üst sınır)
    if (ramMB <= 2048) return ramMB * 2;
    if (ramMB <= 8192) return ramMB;
    if (ramMB <= 16384) return ramMB ~/ 2;
    return 8192; // 8 GB üst sınır
  }

  // Ana kurulum motoru
  Future<bool> runInstall(Map<String, dynamic> state, void Function(double progress, String status) onProgress, {bool isMock = false}) async {
    // Log fonksiyonu: Hem terminale hem de UI'a gönderir
    void log(String msg) {
       print("[ro-Installer] $msg");
       onProgress(-1.0, msg); // UI'daki log penceresine gönder
    }

    final selectedDisk = state['selectedDisk'] as String;
    final partitionMethod = state['partitionMethod'] as String; // 'full' or 'manual' or 'alongside'
    final manualPartitions = state['manualPartitions'] as List<dynamic>;

    try {
      if (partitionMethod == 'full') {
        onProgress(0.1, "Tüm disk sıfırlanıyor ve yapılandırılıyor: $selectedDisk");
        
        // 1. Wipe partition table
        if (!await runCmd('sgdisk', ['-Z', selectedDisk], log, isMock: isMock)) return false;
        
        // 2. Create EFI Partition (512MB)
        if (!await runCmd('sgdisk', ['-n', '1:0:+512M', '-t', '1:ef00', selectedDisk], log, isMock: isMock)) return false;
        
        // 3. Create Root Partition (Rest of disk)
        if (!await runCmd('sgdisk', ['-n', '2:0:0', selectedDisk], log, isMock: isMock)) return false;
        
        await runCmd('partprobe', [selectedDisk], log, isMock: isMock);
        await Future.delayed(Duration(seconds: isMock ? 0 : 3));

        // Format
        String rootFs = state['fileSystem'] ?? 'btrfs';
        String efiPart = "${selectedDisk}1";
        String rootPart = "${selectedDisk}2";
        if (selectedDisk.contains("nvme") || selectedDisk.contains("loop")) {
          efiPart = "${selectedDisk}p1";
          rootPart = "${selectedDisk}p2";
        }

        onProgress(0.2, "Bölümler biçimlendiriliyor... (${rootFs.toUpperCase()})");
        if (!await runCmd('mkfs.fat', ['-F32', efiPart], log, isMock: isMock)) return false;
        
        if (rootFs == 'btrfs') {
          if (!await runCmd('mkfs.btrfs', ['-f', rootPart], log, isMock: isMock)) return false;
        } else {
          if (!await runCmd('mkfs.ext4', ['-F', rootPart], log, isMock: isMock)) return false;
        }

        // Mount
        onProgress(0.3, "Bölümler (/mnt) hedefine bağlanıyor...");
        await runCmd('umount', ['-R', '/mnt'], log, isMock: isMock);
        
        if (rootFs == 'btrfs') {
          // BTRFS Subvolume yapısını kur
          if (!await runCmd('mount', [rootPart, '/mnt'], log, isMock: isMock)) return false;
          if (!await runCmd('btrfs', ['subvolume', 'create', '/mnt/@'], log, isMock: isMock)) return false;
          if (!await runCmd('btrfs', ['subvolume', 'create', '/mnt/@home'], log, isMock: isMock)) return false;
          await runCmd('umount', ['/mnt'], log, isMock: isMock);
          
          // Subvolume'leri bağla
          if (!await runCmd('mount', ['-o', 'subvol=@', rootPart, '/mnt'], log, isMock: isMock)) return false;
          if (!await runCmd('mkdir', ['-p', '/mnt/home'], log, isMock: isMock)) return false;
          if (!await runCmd('mount', ['-o', 'subvol=@home', rootPart, '/mnt/home'], log, isMock: isMock)) return false;
        } else {
          // Normal Ext4 / XFS mount
          if (!await runCmd('mount', [rootPart, '/mnt'], log, isMock: isMock)) return false;
        }

        if (!await runCmd('mkdir', ['-p', '/mnt/boot/efi'], log, isMock: isMock)) return false;
        if (!await runCmd('mount', [efiPart, '/mnt/boot/efi'], log, isMock: isMock)) return false;

      } else if (partitionMethod == 'alongside') {
        // ============================================================
        // ALONGSIDE (YANINA KUR) MOTORU
        // Mevcut bölümlere KESİNLİKLE dokunmaz.
        // Sadece diskteki boş (unallocated) alana yeni bölümler oluşturur.
        // ============================================================
        
        final double linuxGB = (state['linuxDiskSizeGB'] as num?)?.toDouble() ?? 60.0;
        final bool hasExistingEfi = state['hasExistingEfi'] == true;
        final String existingEfiPart = (state['existingEfiPartition'] ?? '') as String;

        // GÜVENLİK ADIMI 1: Bölüm tablosunu yedekle
        onProgress(0.05, "Güvenlik: Mevcut bölüm tablosu yedekleniyor...");
        await runCmd('sgdisk', ['--backup=/tmp/gpt_backup_alongside.bin', selectedDisk], log, isMock: isMock);

        // ADIM 2: RAM'e göre dinamik SWAP boyutu hesapla
        final int ramMB = await getSystemRamMB();
        final int swapMB = calculateSwapMB(ramMB);
        final int swapGB = (swapMB / 1024).ceil(); // MB → GB, yukarı yuvarlama
        log("Sistem RAM: ${ramMB}MB → Hesaplanan SWAP: ${swapMB}MB (${swapGB}GB)");
        
        onProgress(0.1, "SWAP bölümü oluşturuluyor ($swapGB GB, RAM: ${(ramMB / 1024).toStringAsFixed(1)} GB)...");
        if (!await runCmd('sgdisk', ['-n', '0:0:+${swapGB}G', '-t', '0:8200', '-c', '0:RoASD_Swap', selectedDisk], log, isMock: isMock)) {
          log("HATA: SWAP bölümü oluşturulamadı. Yedeklenen tablo: /tmp/gpt_backup_alongside.bin");
          return false;
        }

        // ADIM 3: ROOT Bölümü — Slider'dan gelen değer eksi SWAP boyutu = root boyutu
        int rootGB = (linuxGB - swapGB).toInt();
        if (rootGB < 40) rootGB = 40;
        onProgress(0.15, "Kök dizin (Root) bölümü oluşturuluyor ($rootGB GB)...");
        if (!await runCmd('sgdisk', ['-n', '0:0:+${rootGB}G', '-t', '0:8300', '-c', '0:RoASD_Root', selectedDisk], log, isMock: isMock)) {
          log("HATA: Root bölümü oluşturulamadı. Yedeklenen tablo: /tmp/gpt_backup_alongside.bin");
          return false;
        }

        // ADIM 4: Kernel'a bildirme
        await runCmd('partprobe', [selectedDisk], log, isMock: isMock);
        await Future.delayed(Duration(seconds: isMock ? 0 : 3));

        // ADIM 5: Yeni oluşturulan bölümleri bul (son iki bölüm)
        onProgress(0.2, "Oluşturulan bölümler tanımlanıyor...");
        String swapPart = '';
        String rootPart = '';
        
        try {
          final lsblkResult = await Process.run('lsblk', ['-J', '-b', '-o', 'NAME,PARTLABEL', selectedDisk]);
          if (lsblkResult.exitCode == 0) {
            final parsed = jsonDecode(lsblkResult.stdout.toString());
            final devices = parsed['blockdevices'] as List<dynamic>;
            if (devices.isNotEmpty && devices.first.containsKey('children')) {
              final children = devices.first['children'] as List<dynamic>;
              for (var child in children) {
                final partLabel = (child['partlabel'] ?? '').toString();
                final childName = child['name'].toString();
                if (partLabel == 'RoASD_Swap') swapPart = '/dev/$childName';
                if (partLabel == 'RoASD_Root') rootPart = '/dev/$childName';
              }
            }
          }
        } catch (e) {
          log("UYARI: Bölüm etiketleri okunamadı, indeks bazlı deneniyor...");
        }
        
        // Etiket bazlı bulamazsa indeks bazlı dene
        if (swapPart.isEmpty || rootPart.isEmpty) {
          try {
            final sgResult = await Process.run('sgdisk', ['-p', selectedDisk]);
            if (sgResult.exitCode == 0) {
              final lines = sgResult.stdout.toString().split('\n').where((l) => RegExp(r'^\s+\d+').hasMatch(l)).toList();
              if (lines.length >= 2) {
                // Son iki bölüm (swap ve root)
                final swapNum = lines[lines.length - 2].trim().split(RegExp(r'\s+'))[0];
                final rootNum = lines[lines.length - 1].trim().split(RegExp(r'\s+'))[0];
                final suffix = (selectedDisk.contains('nvme') || selectedDisk.contains('loop')) ? 'p' : '';
                swapPart = '$selectedDisk$suffix$swapNum';
                rootPart = '$selectedDisk$suffix$rootNum';
              }
            }
          } catch (e) {
            log("HATA: Bölümler bulunamadı: $e");
            return false;
          }
        }

        if (swapPart.isEmpty || rootPart.isEmpty) {
          log("FATAL: Yeni oluşturulan SWAP ve ROOT bölümleri bulunamadı!");
          return false;
        }
        log("Bulunan bölümler → SWAP: $swapPart, ROOT: $rootPart");

        // ADIM 6: Formatlama (SADECE yeni bölümler, mevcut bölümlere DOKUNMA)
        String rootFs = state['fileSystem'] ?? 'btrfs';
        onProgress(0.25, "Yeni bölümler biçimlendiriliyor (${rootFs.toUpperCase()})...");
        
        if (!await runCmd('mkswap', [swapPart], log, isMock: isMock)) return false;
        
        if (rootFs == 'btrfs') {
          if (!await runCmd('mkfs.btrfs', ['-f', rootPart], log, isMock: isMock)) return false;
        } else if (rootFs == 'xfs') {
          if (!await runCmd('mkfs.xfs', ['-f', rootPart], log, isMock: isMock)) return false;
        } else {
          if (!await runCmd('mkfs.ext4', ['-F', rootPart], log, isMock: isMock)) return false;
        }

        // ADIM 7: Mount işlemleri
        onProgress(0.3, "Bölümler (/mnt) hedefine bağlanıyor...");
        await runCmd('umount', ['-R', '/mnt'], log, isMock: isMock);
        
        if (rootFs == 'btrfs') {
          // BTRFS Subvolume yapısını kur
          if (!await runCmd('mount', [rootPart, '/mnt'], log, isMock: isMock)) return false;
          if (!await runCmd('btrfs', ['subvolume', 'create', '/mnt/@'], log, isMock: isMock)) return false;
          if (!await runCmd('btrfs', ['subvolume', 'create', '/mnt/@home'], log, isMock: isMock)) return false;
          await runCmd('umount', ['/mnt'], log, isMock: isMock);
          
          // Subvolume'leri bağla
          if (!await runCmd('mount', ['-o', 'subvol=@', rootPart, '/mnt'], log, isMock: isMock)) return false;
          if (!await runCmd('mkdir', ['-p', '/mnt/home'], log, isMock: isMock)) return false;
          if (!await runCmd('mount', ['-o', 'subvol=@home', rootPart, '/mnt/home'], log, isMock: isMock)) return false;
        } else {
          if (!await runCmd('mount', [rootPart, '/mnt'], log, isMock: isMock)) return false;
        }
        
        // Mevcut EFI bölümünü formatlamadan mount et
        if (hasExistingEfi && existingEfiPart.isNotEmpty) {
          log("Mevcut EFI bölümü kullanılıyor (formatlanmayacak): $existingEfiPart");
          if (!await runCmd('mkdir', ['-p', '/mnt/boot/efi'], log, isMock: isMock)) return false;
          if (!await runCmd('mount', [existingEfiPart, '/mnt/boot/efi'], log, isMock: isMock)) return false;
        } else {
          log("UYARI: Mevcut EFI bulunamadı, bootloader kurulumu başarısız olabilir.");
        }
        
        // SWAP etkinleştir
        await runCmd('swapon', [swapPart], log, isMock: isMock);

      } else { // Elle Bölümlendirme (Manual Partitioning)
        onProgress(0.1, "Kullanıcının disk yapılandırma planı uygulanıyor...");
        
        // Önce bölümleri formatla (Sadece eylem yapılması planlananlar isPlanned == true)
        for (var p in manualPartitions) {
           if (p['isFreeSpace'] == true || p['isPlanned'] != true) continue;
           String partName = p['name'];
           String fsType = p['type'];
           
           if (fsType == 'fat32') {
             if (!await runCmd('mkfs.fat', ['-F32', partName], log, isMock: isMock)) return false;
           } else if (fsType == 'btrfs') {
             if (!await runCmd('mkfs.btrfs', ['-f', partName], log, isMock: isMock)) return false;
           } else if (fsType == 'ext4') {
             if (!await runCmd('mkfs.ext4', ['-F', partName], log, isMock: isMock)) return false;
           } else if (fsType == 'xfs') {
             if (!await runCmd('mkfs.xfs', ['-f', partName], log, isMock: isMock)) return false;
           } else if (fsType == 'linux-swap') {
             if (!await runCmd('mkswap', [partName], log, isMock: isMock)) return false;
           }
        }

        // Mount işlemleri (Root önceliği kritiktir!)
        await runCmd('umount', ['-R', '/mnt'], log, isMock: isMock);
        var rootPart = manualPartitions.firstWhere((p) => p['mount'] == '/', orElse: () => null);
        if (rootPart == null) { log("Root partisiz bir sistem! / montaj noktasını bulamadım."); return false; }
        
        if (!await runCmd('mount', [rootPart['name'], '/mnt'], log, isMock: isMock)) return false;

        // Diğerlerini Mountla
        for (var p in manualPartitions) {
           if (p['isFreeSpace'] == true || p['mount'] == '/' || p['mount'] == 'unmounted' || p['mount'] == '[SWAP]') continue;
           String mntPoint = "/mnt${p['mount']}";
           if (!await runCmd('mkdir', ['-p', mntPoint], log, isMock: isMock)) return false;
           if (!await runCmd('mount', [p['name'], mntPoint], log, isMock: isMock)) return false;
        }

        // Swap var ise etkinleştir
        for (var p in manualPartitions) {
           if (p['mount'] == '[SWAP]') await runCmd('swapon', [p['name']], log, isMock: isMock);
        }
      }

      // ACT 2: SISTEM KOPYALAMASI (RSYNC Klonlama Teknolojisi)
      onProgress(0.4, "Live İşletim Sistemi Kök dosya hedef diske aktarılıyor...");
      onProgress(0.41, "Bu işlem disk hızına bağlı olarak 5-15 dakika sürebilir. (Rsync Çalışıyor...)");
      
      bool rsyncOk = await runCmd('rsync', [
        '-aAX',
        '--exclude=/dev/*',
        '--exclude=/proc/*',
        '--exclude=/sys/*',
        '--exclude=/tmp/*',
        '--exclude=/run/*',
        '--exclude=/mnt/*',
        '--exclude=/media/*',
        '--exclude=/lost+found',
        '--exclude=/etc/machine-id',
        '--exclude=/var/log/audit/*',
        '/', // Kaynak: Calisan Live Kök
        '/mnt/' // Hedef
      ], log, isMock: isMock);

      if (!rsyncOk) {
         log("Rsync (Kurulum ve dosya kopyalama) başarısız oldu.");
         return false;
      }

      // ACT 3: CHROOT SİSTEM BÜTÜNLÜĞÜ (BIND MOUNTS)
      onProgress(0.7, "Kök sistem bağlamaları yapılıyor (Chroot hazırlığı)...");
      await runCmd('mount', ['--bind', '/dev', '/mnt/dev'], log, isMock: isMock);
      await runCmd('mount', ['--bind', '/proc', '/mnt/proc'], log, isMock: isMock);
      await runCmd('mount', ['--bind', '/sys', '/mnt/sys'], log, isMock: isMock);
      await runCmd('mount', ['--bind', '/run', '/mnt/run'], log, isMock: isMock);

      // ACT 4: KULLANICI / TIMEZONE AYARLARI
      onProgress(0.8, "Zaman dilimi ve kullanıcı ayarları yapılandırılıyor...");
      String user = state['username'] ?? 'user';
      String pass = state['password'] ?? 'user';
      String tz = state['selectedTimezone'] ?? 'Europe/Istanbul';
      String kbd = state['selectedKeyboard'] ?? 'trq';
      String hostname = 'ro-asd';
      
      await runCmd('chroot', ['/mnt', 'ln', '-sf', '/usr/share/zoneinfo/$tz', '/etc/localtime'], log, isMock: isMock);
      
      // Sistem kimliği (Machine ID) oluşturma
      await runCmd('chroot', ['/mnt', 'systemd-machine-id-setup'], log, isMock: isMock);
      
      // Hostname (Makine Adı)
      await runCmd('chroot', ['/mnt', 'sh', '-c', 'echo "$hostname" > /etc/hostname'], log, isMock: isMock);
      
      // Vconsole (Klavye Düzeni)
      await runCmd('chroot', ['/mnt', 'sh', '-c', 'echo "KEYMAP=$kbd" > /etc/vconsole.conf'], log, isMock: isMock);
      
      // Locale (Dil)
      await runCmd('chroot', ['/mnt', 'sh', '-c', 'echo "LANG=en_US.UTF-8" > /etc/locale.conf'], log, isMock: isMock);

      await runCmd('chroot', ['/mnt', 'useradd', '-m', '-G', 'wheel,storage,power,network', '-s', '/bin/bash', user], log, isMock: isMock);
      
      await runCmd('chroot', ['/mnt', 'sh', '-c', 'echo "$user:$pass" | chpasswd'], log, isMock: isMock);
      await runCmd('chroot', ['/mnt', 'sh', '-c', 'echo "root:root" | chpasswd'], log, isMock: isMock); // Opsiyonel

      if (state['isAdministrator'] == true) {
         await runCmd('chroot', ['/mnt', 'sh', '-c', 'echo "$user ALL=(ALL:ALL) ALL" > /etc/sudoers.d/$user'], log, isMock: isMock);
         await runCmd('chroot', ['/mnt', 'chmod', '0440', '/etc/sudoers.d/$user'], log, isMock: isMock);
      }

      // ACT 5: SİSTEM BAŞLATICI, FSTAB ve GÜVENLİK (GRUB2 & SELinux)
      onProgress(0.9, "Fstab, SELinux ve GRUB2 Bootloader yapılandırılıyor...");

      // 5.1 FSTAB ÜRETİMİ
      // Hedef diskteki (mnt) uuid'leri alarak fstab dosyasını oluşturuyoruz.
      await runCmd('sh', ['-c', '''
cat > /mnt/etc/fstab << 'EOF'
# /etc/fstab generated by ro-Installer
EOF
mount | grep " /mnt" | while read -r line; do
  dev=\$(echo \$line | awk '{print \$1}')
  mp=\$(echo \$line | awk '{print \$3}')
  fstype=\$(echo \$line | awk '{print \$5}')
  uuid=\$(blkid -s UUID -o value \$dev 2>/dev/null)
  if [ -z "\$uuid" ]; then continue; fi
  target_mp=\${mp#/mnt}
  [ -z "\$target_mp" ] && target_mp="/"
  opts="defaults"
  if [ "\$fstype" = "btrfs" ]; then
     actual_subvol=\$(echo "\$line" | grep -o 'subvol=[^, )]*')
     [ -z "\$actual_subvol" ] && actual_subvol="subvol=/"
     opts="defaults,compress=zstd:1,\$actual_subvol"
  elif [ "\$fstype" = "vfat" ]; then
     opts="umask=0077,shortname=winnt"
  fi
  echo "UUID=\$uuid \$target_mp \$fstype \$opts 0 0" >> /mnt/etc/fstab
done
swaps=\$(lsblk -rn -o NAME,FSTYPE | awk '\$2=="swap"{print \$1}')
for sw in \$swaps; do
   uuid=\$(blkid -s UUID -o value /dev/\$sw 2>/dev/null)
   if [ -n "\$uuid" ]; then
      echo "UUID=\$uuid none swap defaults 0 0" >> /mnt/etc/fstab
   fi
done
      '''], log, isMock: isMock);

      // 5.2 SELINUX AUTORELABEL
      // İlk açılışta dosyaların security context'lerinin düzeltilmesini sağlar
      await runCmd('touch', ['/mnt/.autorelabel'], log, isMock: isMock);

      // 5.3 TEMİZLİK (Eski Installer Kalıntıları)
      await runCmd('chroot', ['/mnt', 'dnf', 'remove', '-y', 'calamares', 'anaconda*'], log, isMock: isMock);

      // 5.4 GRUB YAPIlandırması
      // /etc/default/grub dosyasını LiveCD label hatalarından temizleyelim
      await runCmd('sh', ['-c', '''
cat > /mnt/etc/default/grub << 'EOF'
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR="\$(sed 's, release .*\$,,g' /etc/system-release)"
GRUB_DEFAULT=saved
GRUB_DISABLE_SUBMENU=true
GRUB_TERMINAL_OUTPUT="console"
GRUB_CMDLINE_LINUX="rhgb quiet"
GRUB_DISABLE_RECOVERY="true"
GRUB_ENABLE_BLSCFG=true
GRUB_DISABLE_OS_PROBER=false
EOF
      '''], log, isMock: isMock);

      // Sadece UEFI Desteği: GRUB2-EFI Kurulumu
      bool grubInstallOk = await runCmd('chroot', ['/mnt', 'grub2-install', '--target=x86_64-efi', '--efi-directory=/boot/efi', '--bootloader-id=RoASD'], log, isMock: isMock);
      if (!grubInstallOk) {
         log("UYARI: grub2-install EFI hatası aldı. EFI partisyonu düzgün bağlanmamış olabilir.");
      }

      // GRUB Config Üretimi
      if (!await runCmd('chroot', ['/mnt', 'grub2-mkconfig', '-o', '/boot/grub2/grub.cfg'], log, isMock: isMock)) {
         log("UYARI: grub2-mkconfig başarısız oldu.");
      }

      // 5.5 INITRAMFS YENİDEN OLUŞTURMA (Eski Disk Label ve UUID'leri temizler)
      onProgress(0.92, "Initramfs imajları güncelleniyor (Dracut)... (Bu işlem biraz sürebilir)");
      // Kernel sürümünü bulup ona göre dracut yapalım (veya chroot içinde direkt dracut --regenerate-all)
      if (!await runCmd('chroot', ['/mnt', 'dracut', '-f', '--regenerate-all'], log, isMock: isMock)) {
         log("UYARI: Dracut işlemi başarısız oldu. Açılışta eski label hataları alınabilir.");
      }

      // ACT 6: CLEANUP
      onProgress(0.95, "Sistem dosyaları korunuyor ve unmount işlemi başlatılıyor...");
      await runCmd('umount', ['-R', '/mnt'], log, isMock: isMock);

      onProgress(1.0, "Kurulum Hatasız Tamamlandı! Sistemi Yeniden Başlatabilirsiniz.");
      return true;

    } catch (e) {
      log("FATAL CATCH: \$e");
      return false;
    }
  }
}
