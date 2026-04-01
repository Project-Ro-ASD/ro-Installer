import 'stage_context.dart';
import 'stage_result.dart';

/// AŞAMA 6: Chroot Yapılandırma
///
/// Hedef sistemi chroot ortamında yapılandırır:
/// - Bind mount'ları oluşturur (/dev, /proc, /sys, /run, /tmp)
/// - Zaman dilimi ayarlar
/// - Machine ID oluşturur
/// - Hostname, Klavye, Locale ayarlar
/// - Kullanıcı hesabı ve şifre oluşturur
/// - SELinux context'leri düzeltir
/// - Eski installer kalıntılarını temizler
/// - FSTAB üretir
/// - .autorelabel oluşturur
class ChrootConfigStage {
  const ChrootConfigStage();

  Future<StageResult> execute(StageContext ctx) async {
    ctx.log('════════════════════════════════════════════');
    ctx.log('[AŞAMA 6] Chroot Yapılandırma Başlatılıyor');
    ctx.log('════════════════════════════════════════════');

    // ── 6.1: Bind Mount'ları Oluştur ──
    ctx.onProgress(0.7, 'Kök sistem bağlamaları yapılıyor (Chroot hazırlığı)...');

    // Rsync tarafından dışlanan dizinlerin bağlama noktalarını oluştur
    await ctx.runCmd('mkdir', ['-p', '/mnt/dev', '/mnt/proc', '/mnt/sys', '/mnt/run', '/mnt/tmp'], ctx.log, isMock: ctx.isMock);

    // /tmp için tmpfs mount et (os-prober ve dracut için şart)
    await ctx.runCmd('mount', ['-t', 'tmpfs', 'tmpfs', '/mnt/tmp'], ctx.log, isMock: ctx.isMock);

    // --rbind: /dev/pts, /dev/shm, /sys/firmware/efi/efivars gibi alt mount'ları da dahil eder
    // Bu dracut ve grub2-install için EFI ve cihaz erişiminde kritik önemdedir
    await ctx.runCmd('mount', ['--rbind', '/dev', '/mnt/dev'], ctx.log, isMock: ctx.isMock);
    await ctx.runCmd('mount', ['--make-rslave', '/mnt/dev'], ctx.log, isMock: ctx.isMock);
    await ctx.runCmd('mount', ['--rbind', '/proc', '/mnt/proc'], ctx.log, isMock: ctx.isMock);
    await ctx.runCmd('mount', ['--make-rslave', '/mnt/proc'], ctx.log, isMock: ctx.isMock);
    await ctx.runCmd('mount', ['--rbind', '/sys', '/mnt/sys'], ctx.log, isMock: ctx.isMock);
    await ctx.runCmd('mount', ['--make-rslave', '/mnt/sys'], ctx.log, isMock: ctx.isMock);
    await ctx.runCmd('mount', ['--rbind', '/run', '/mnt/run'], ctx.log, isMock: ctx.isMock);
    await ctx.runCmd('mount', ['--make-rslave', '/mnt/run'], ctx.log, isMock: ctx.isMock);

    // ── 6.2: Kullanıcı ve Sistem Ayarları ──
    ctx.onProgress(0.8, 'Zaman dilimi ve kullanıcı ayarları yapılandırılıyor...');

    String user = ctx.state['username'] ?? 'user';
    String pass = ctx.state['password'] ?? 'user';
    String tz = ctx.state['selectedTimezone'] ?? 'Europe/Istanbul';
    String kbd = ctx.state['selectedKeyboard'] ?? 'trq';
    String hostname = 'ro-asd';

    // Zaman dilimi
    await ctx.runCmd('chroot', ['/mnt', 'ln', '-sf', '/usr/share/zoneinfo/$tz', '/etc/localtime'], ctx.log, isMock: ctx.isMock);

    // Sistem kimliği (Machine ID) oluşturma
    await ctx.runCmd('chroot', ['/mnt', 'systemd-machine-id-setup'], ctx.log, isMock: ctx.isMock);

    // Hostname (Makine Adı)
    await ctx.runCmd('chroot', ['/mnt', 'sh', '-c', 'echo "$hostname" > /etc/hostname'], ctx.log, isMock: ctx.isMock);

    // Vconsole (Klavye Düzeni)
    await ctx.runCmd('chroot', ['/mnt', 'sh', '-c', 'echo "KEYMAP=$kbd" > /etc/vconsole.conf'], ctx.log, isMock: ctx.isMock);

    // Locale (Dil)
    await ctx.runCmd('chroot', ['/mnt', 'sh', '-c', 'echo "LANG=en_US.UTF-8" > /etc/locale.conf'], ctx.log, isMock: ctx.isMock);

    // ── 6.3: SELinux Context Düzeltmesi (chpasswd öncesi) ──
    await ctx.runCmd('chroot', ['/mnt', 'restorecon', '/etc/passwd', '/etc/shadow', '/etc/gshadow', '/etc/group'], ctx.log, isMock: ctx.isMock);

    // ── 6.4: Kullanıcı Hesabı ve Şifre ──
    await ctx.runCmd('chroot', ['/mnt', 'sh', '-c', "echo '$user:$pass' | chpasswd"], ctx.log, isMock: ctx.isMock);
    await ctx.runCmd('chroot', ['/mnt', 'sh', '-c', "echo 'root:root' | chpasswd"], ctx.log, isMock: ctx.isMock); // Opsiyonel

    if (ctx.state['isAdministrator'] == true) {
      await ctx.runCmd('chroot', ['/mnt', 'sh', '-c', 'echo "$user ALL=(ALL:ALL) ALL" > /etc/sudoers.d/$user'], ctx.log, isMock: ctx.isMock);
      await ctx.runCmd('chroot', ['/mnt', 'chmod', '0440', '/etc/sudoers.d/$user'], ctx.log, isMock: ctx.isMock);
    }

    // ── 6.5: Eski Installer ve Live CD Kalıntıları Temizliği ──
    ctx.onProgress(0.82, 'Live CD ve eski installer kalıntıları temizleniyor...');

    // Eski installer paketlerini kaldır
    await ctx.runCmd('chroot', ['/mnt', 'dnf', 'remove', '-y', 'calamares', 'anaconda*'], ctx.log, isMock: ctx.isMock, allowedExitCodes: [0, 1]);

    // Live CD servis kalıntılarını devre dışı bırak ve kaldır
    // Bu servisler yalnızca Live ortamda gereklidir, kurulu sistemde çalışmamalıdır
    await ctx.runCmd('chroot', ['/mnt', 'sh', '-c', '''
      systemctl disable livesys.service 2>/dev/null || true
      systemctl disable livesys-late.service 2>/dev/null || true
      rm -f /etc/systemd/system/livesys.service 2>/dev/null || true
      rm -f /etc/systemd/system/livesys-late.service 2>/dev/null || true
      rm -f /usr/lib/systemd/system/livesys.service 2>/dev/null || true
      rm -f /usr/lib/systemd/system/livesys-late.service 2>/dev/null || true
    '''], ctx.log, isMock: ctx.isMock, allowedExitCodes: [0, 1]);

    // ro-Installer autostart dosyasını kurulu sistemden kaldır
    // (Kurulu sistemde artık yükleyiciye gerek yok)
    await ctx.runCmd('chroot', ['/mnt', 'rm', '-f', '/etc/xdg/autostart/ro-Installer.desktop'], ctx.log, isMock: ctx.isMock, allowedExitCodes: [0, 1]);

    // liveuser kalıntılarını temizle (kurulu sistemde bulunmamalı)
    await ctx.runCmd('chroot', ['/mnt', 'sh', '-c', '''
      userdel -r liveuser 2>/dev/null || true
      rm -f /etc/sudoers.d/ro-installer-live 2>/dev/null || true
    '''], ctx.log, isMock: ctx.isMock, allowedExitCodes: [0, 1]);

    // /var/lib/dbus/machine-id senkronizasyonu
    await ctx.runCmd('chroot', ['/mnt', 'sh', '-c', 'ln -sf /etc/machine-id /var/lib/dbus/machine-id 2>/dev/null || true'], ctx.log, isMock: ctx.isMock);

    // ── 6.6: FSTAB Üretimi ──
    // findmnt kullanarak güvenilir fstab üretimi:
    // - Sanal FS'leri (tmpfs, devtmpfs, proc, sysfs, devpts) filtreler
    // - Sadece gerçek blok cihazlarını (/dev/ ile başlayanları) yazar
    // - BTRFS subvolume bilgisini mount seçeneklerinden doğru alır
    ctx.onProgress(0.85, 'Fstab ve SELinux yapılandırılıyor...');

    await ctx.runCmd('sh', ['-c', '''
cat > /mnt/etc/fstab << 'FSTAB_HEADER'
# /etc/fstab generated by ro-Installer
# <device>  <mount>  <type>  <options>  <dump>  <pass>
FSTAB_HEADER

# findmnt ile /mnt altındaki tüm gerçek mount noktalarını tara
findmnt -rn -o SOURCE,TARGET,FSTYPE,OPTIONS -R /mnt | while read -r src target fstype options; do
  # Sanal dosya sistemlerini atla
  case "\$fstype" in
    tmpfs|devtmpfs|proc|sysfs|devpts|cgroup|cgroup2|pstore|efivarfs|securityfs|debugfs|configfs|fusectl|hugetlbfs|mqueue|binfmt_misc)
      continue
      ;;
  esac

  # Sadece gerçek blok cihazlarını al (/dev/ ile başlayanlar)
  case "\$src" in
    /dev/*) ;;
    *) continue ;;
  esac

  # UUID al
  uuid=\$(blkid -s UUID -o value "\$src" 2>/dev/null)
  if [ -z "\$uuid" ]; then continue; fi

  # Mount noktasından /mnt prefix'ini kaldır
  target_mp=\${target#/mnt}
  [ -z "\$target_mp" ] && target_mp="/"

  # Dosya sistemine göre mount opsiyonları belirle
  opts="defaults"
  if [ "\$fstype" = "btrfs" ]; then
     # Mevcut mount seçeneklerinden subvol bilgisini al
     actual_subvol=\$(echo "\$options" | grep -o 'subvol=[^,]*')
     [ -z "\$actual_subvol" ] && actual_subvol="subvol=/"
     opts="defaults,compress=zstd:1,\$actual_subvol"
  elif [ "\$fstype" = "vfat" ]; then
     opts="umask=0077,shortname=winnt"
  fi

  echo "UUID=\$uuid \$target_mp \$fstype \$opts 0 0" >> /mnt/etc/fstab
done

# Aktif swap bölümlerini fstab'a ekle
swaps=\$(lsblk -rn -o NAME,FSTYPE | awk '\$2=="swap"{print \$1}')
for sw in \$swaps; do
   uuid=\$(blkid -s UUID -o value /dev/\$sw 2>/dev/null)
   if [ -n "\$uuid" ]; then
      echo "UUID=\$uuid none swap defaults 0 0" >> /mnt/etc/fstab
   fi
done
      '''], ctx.log, isMock: ctx.isMock);

    // Üretilen fstab'ı doğrulama için logla
    ctx.log('Üretilen /etc/fstab içeriği kontrol ediliyor...');
    await ctx.runCmd('cat', ['/mnt/etc/fstab'], ctx.log, isMock: ctx.isMock);

    // ── 6.7: SELinux Autorelabel ──
    // İlk açılışta dosyaların security context'lerinin düzeltilmesini sağlar
    await ctx.runCmd('touch', ['/mnt/.autorelabel'], ctx.log, isMock: ctx.isMock);

    ctx.log('[AŞAMA 6] Chroot yapılandırma tamamlandı.');
    return StageResult.ok('Chroot yapılandırma tamamlandı.');
  }
}
