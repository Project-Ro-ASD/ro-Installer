# Ro-Installer Test Rehberi

## 1. Bu Belgenin Amacı

Bu belge, Ro-Installer projesinde bugün kullanılan test yollarını tek yerde toplamak için hazırlanmıştır. Amaç; daha sonra bu projeyi tekrar test etmek istediğinizde aynı işleri bensiz de tekrar edebilmeniz, hangi komutun neyi doğruladığını bilmeniz ve çıkan sonucun ne anlama geldiğini doğru yorumlayabilmenizdir.

Bu belge iki ana test katmanını kapsar:

1. Kod seviyesi testler
   - unit test (birim testi, yani tek bir sınıfın veya fonksiyonun kontrollü doğrulaması)
   - stage test (aşama testi, yani kurulum motorundaki tek bir kurulum aşamasının doğrulaması)
   - analyze (statik analiz, yani kod çalışmadan önce kalite ve tutarlılık denetimi)
2. Sanal makine testleri
   - QEMU/VM otomatik kurulum testi
   - ilk açılış (first boot, yani kurulum sonrası ilk sistem açılışı) doğrulaması

## 2. Temel Ön Kabul

Bu proje için en önemli gerçek şudur:

**`flutter test` yeşil olsa bile bu tek başına “ISO içine gömülü kurulum kesin açılır” anlamına gelmez.**

Bu yüzden testleri şu sıra ile düşünmek gerekir:

1. Önce kod bozuk mu diye unit ve stage testleri
2. Sonra mantıkta sessiz hata var mı diye analyze
3. Sonra gerçek kurulum + reboot + boot doğrulaması için VM testi

## 3. Gerekli Ortam

## 3.0 Nereden Çalıştırmalısınız?

Bu belgedeki `flutter test`, `flutter analyze` ve `./test_qemu_vm.sh` komutlarının tamamı **proje kök dizininden** çalıştırılmalıdır:

```bash
cd /home/roasd/Masaüstü/Ro-ASD/Installer/ro-Installer
```

Hızlı doğrulama için:

```bash
pwd
ls pubspec.yaml test_qemu_vm.sh
```

Beklenen sonuç:

1. `pwd` çıktısı `/home/roasd/Masaüstü/Ro-ASD/Installer/ro-Installer` olmalıdır.
2. `pubspec.yaml` görünmelidir; aksi halde `flutter test` "No pubspec.yaml file found" hatası verir.
3. `test_qemu_vm.sh` görünmelidir; aksi halde `./test_qemu_vm.sh` "böyle bir dosya ya da dizin yok" hatası verir.

### 3.1 Flutter Tarafı

Projede kullanılan Flutter yolu şu şekildedir:

- `$HOME/development/flutter/bin/flutter`

Eğer `flutter` komutu doğrudan çalışmıyorsa şu kullanım güvenlidir:

```bash
PATH="$HOME/.local/bin:$HOME/development/flutter/bin:$PATH" flutter --version
```

### 3.2 VM Tarafı

Otomatik sanal makine testi için şu araçlar gerekir:

1. `qemu-system-x86_64`
2. `qemu-img`
3. `python3`
4. `edk2-ovmf`
5. Proje klasöründe bir Fedora Live ISO

Fedora tarafında tipik kurulum:

```bash
sudo dnf install qemu-system-x86 qemu-img edk2-ovmf python3
```

Eğer ISO proje kökünde değilse script’e açık yol da verebilirsiniz:

```bash
RO_INSTALLER_TEST_ISO=/tam/yol/Fedora-Live.iso ./test_qemu_vm.sh auto
```

## 4. Hızlı Sağlık Kontrolü

Her şeye başlamadan önce bunu çalıştırın:

```bash
PATH="$HOME/.local/bin:$HOME/development/flutter/bin:$PATH" flutter doctor -v
```

### Ne Anlamalısınız?

1. Flutter bulunuyorsa temel araç zinciri ayakta demektir.
2. Linux toolchain görünüyorsa Linux release build alma ihtimali yüksektir.
3. Android SDK veya Chrome eksikse bu proje için birinci öncelik değildir.

### Kötü Sonuç Ne Demek?

1. `flutter` bulunamıyorsa testlerin çoğuna başlayamazsınız.
2. Linux toolchain kırık görünüyorsa `flutter build linux` başarısız olabilir.

## 5. Tam Test Paketi

Bu komut tüm Dart/Flutter testlerini çalıştırır:

```bash
cd /home/roasd/Masaüstü/Ro-ASD/Installer/ro-Installer
PATH="$HOME/.local/bin:$HOME/development/flutter/bin:$PATH" flutter test
```

### Bu Ne İşe Yarar?

Bu komut servisleri ve kurulum aşamalarını sahte komut çalıştırıcı (fake command runner, yani gerçek disk yerine kontrollü sahte komut cevabı veren test altyapısı) ile doğrular.

### Başarılı Sonuçtan Ne Anlamalısınız?

`All tests passed!` görüyorsanız:

1. temel kurulum akışı kod seviyesinde kırık değildir
2. son refactor bir stage davranışını bariz biçimde bozmamıştır
3. sessiz hata sınıflarının bir kısmı testle korunmaktadır

### Yetersiz Kalan Tarafı Nedir?

Bu testler:

1. gerçek diske yazmaz
2. gerçek GRUB açılışını doğrulamaz
3. ISO içindeki gerçek Live ortam davranışını tek başına kanıtlamaz

## 6. Hedefli Stage Testleri

Bazı hatalarda tüm paketi değil, ilgili stage’i çalıştırmak daha hızlıdır.

### 6.1 Chroot Yapılandırma Testleri

```bash
cd /home/roasd/Masaüstü/Ro-ASD/Installer/ro-Installer
PATH="$HOME/.local/bin:$HOME/development/flutter/bin:$PATH" \
flutter test test/services/install_stages/chroot_config_stage_test.dart
```

### Ne Doğrular?

1. `useradd`, `chpasswd`, `passwd -l root` gibi kritik adımların çağrıldığını
2. yönetici olmayan kullanıcının yanlışlıkla `wheel` grubuna eklenmediğini
3. bind mount veya `fstab` üretimi gibi kritik adımlar patlarsa stage’in durduğunu
4. VM test modu açıksa ilk açılış smoke service dosyasının üretildiğini

### Başarılı Sonuç Ne Demektir?

`ChrootConfigStage ... All tests passed!` sonucu:

1. chroot aşaması artık sessizce başarısız olup başarı döndürmüyor
2. kullanıcı/rol mantığı en azından test edilen senaryolarda tutarlı

### 6.2 Bootloader Testleri

```bash
cd /home/roasd/Masaüstü/Ro-ASD/Installer/ro-Installer
PATH="$HOME/.local/bin:$HOME/development/flutter/bin:$PATH" \
flutter test test/services/install_stages/bootloader_stage_test.dart
```

### Ne Doğrular?

1. boot zincirinin sırasını
2. BTRFS için `rootflags=subvol=@` yazımını
3. `kernel-install` patlarsa stage’in durmasını
4. `grub2-mkconfig` patlarsa stage’in durmasını

### Başarılı Sonuç Ne Demektir?

Boot aşamasında artık “uyarı ver geç” yerine “kritik hata varsa stage’i düşür” davranışı korunuyor demektir.

### 6.3 Kurulum Sonrası Doğrulama Testleri

```bash
cd /home/roasd/Masaüstü/Ro-ASD/Installer/ro-Installer
PATH="$HOME/.local/bin:$HOME/development/flutter/bin:$PATH" \
flutter test test/services/install_stages/post_install_validation_stage_test.dart
```

### Ne Doğrular?

1. `fstab` ve `kernel cmdline` var mı
2. BLS girişleri oluşmuş mu
3. live parametreleri hedef sisteme sızmış mı
4. `kernel-core` veya `ro-kernel-*-core` alternatifi ile `dracut`, `grub2-efi-x64`, `shim-x64` paketleri doğrulanabiliyor mu
5. kernel, initramfs ve EFI artefaktları var mı

### Başarılı Sonuç Ne Demektir?

Kurulum sonunda yalnızca “komutlar çalıştı” değil, “çıktılar oluştu” seviyesinde de bir kontrol hattı vardır demektir.

## 7. Statik Analiz

Dokunduğunuz dosyaları önce hedefli analiz edin:

```bash
cd /home/roasd/Masaüstü/Ro-ASD/Installer/ro-Installer
PATH="$HOME/.local/bin:$HOME/development/flutter/bin:$PATH" \
flutter analyze lib/main.dart \
  lib/services/install_stages/chroot_config_stage.dart \
  lib/services/install_stages/bootloader_stage.dart \
  lib/services/install_stages/post_install_validation_stage.dart
```

Tüm projeyi görmek isterseniz:

```bash
cd /home/roasd/Masaüstü/Ro-ASD/Installer/ro-Installer
PATH="$HOME/.local/bin:$HOME/development/flutter/bin:$PATH" flutter analyze
```

### Ne Anlamalısınız?

1. `No issues found!` ise dokunduğunuz alan temizdir.
2. Tüm projede hâlâ çok sayıda deprecated (eskiyip kaldırılmaya aday) uyarı vardır.
3. Bu uyarılar boot zincirini hemen bozmaz ama teknik borçtır.

## 8. Shell ve Yardımcı Script Kontrolü

VM otomasyon scriptlerini değiştirdiğinizde önce sentaks kontrolü yapın:

```bash
cd /home/roasd/Masaüstü/Ro-ASD/Installer/ro-Installer
bash -n test_qemu_vm.sh test_qemu_guest_runner.sh
python3 -m py_compile linux/qmp_send_keys.py
```

### Başarılı Sonuç Ne Demektir?

Hiç çıktı yoksa sentaks düzeyi temizdir.

### Bu Neyi Doğrulamaz?

1. scriptin mantıksal olarak doğru olduğunu kanıtlamaz
2. QEMU’nun gerçekten kurulu olduğunu kanıtlamaz
3. Live ISO ile gerçekten başarıya ulaşacağını tek başına göstermez

## 9. Başsız Profil Tabanlı Kurulum Modu

Artık yükleyici aynı binary içinden başsız (headless, yani GUI açmadan) profil tabanlı çalıştırılabilir.

### Örnek Kullanım

```bash
sudo env \
  RO_INSTALLER_AUTO_PROFILE=/mnt/host/test/fixtures/profile_full_btrfs.json \
  RO_INSTALLER_VM_TEST_MODE=1 \
  RO_INSTALLER_AUTO_REBOOT=1 \
  RO_INSTALLER_LOG_DIR=/mnt/host/outputs/vm-logs \
  /mnt/host/build/linux/x64/release/bundle/ro_installer
```

### Bu Ne İşe Yarar?

1. GUI ekranlarını tek tek dolaşmadan gerçek kurulum akışını başlatır
2. JSON profilini kurulum motoruna verir
3. başarı durumunda otomatik reboot yapabilir
4. VM testi için ilk açılış smoke service mekanizmasını aktive edebilir

### Hangi Ortamda Kullanılır?

Bu mod özellikle Live ISO içindeki testlerde ve QEMU otomasyonunda kullanılmak içindir.

## 10. Otomatik QEMU/VM Testi

Bu artık bu depo içinden çalıştırılabilir.

### 10.1 Varsayılan Otomatik Test

```bash
./test_qemu_vm.sh auto test/fixtures/profile_full_btrfs.json
```

Not:

1. `test_qemu_vm.sh` VM için geçici bir profil üretir ve `selectedDisk` alanını varsayılan olarak `/dev/vda` yapar.
2. Bu yüzden fixture içindeki disk adı host veya başka test ortamı için farklı olsa bile QEMU koşusunda ayrıca elle düzeltmeniz gerekmez.
3. İsterseniz farklı guest disk yolu için `VM_GUEST_DISK=/dev/... ./test_qemu_vm.sh auto ...` kullanabilirsiniz.

### 10.2 EXT4 Profili ile Test

```bash
./test_qemu_vm.sh auto test/fixtures/profile_full_ext4_nvme.json
```

### 10.3 Manual Mod

Tam otomasyon yerine VM’yi açıp sizin müdahale etmenizi isterseniz:

```bash
./test_qemu_vm.sh manual
```

### Bu Script Ne Yapar?

1. Linux release binary derler
2. `outputs/vm/TARIH-SAAT/` altında çalışma klasörü açar
3. QCOW2 disk oluşturur
4. yazılabilir `OVMF_VARS.fd` kopyası üretir
5. Fedora Live ISO’yu bir kez ISO’dan boot eder
6. QMP (QEMU Machine Protocol, yani QEMU’ya dışarıdan komut gönderme arabirimi) ile Live oturuma komut yollar
7. guest içinde `test_qemu_guest_runner.sh` ile otomatik kurulumu başlatır
8. guest tarafında logları önce yerel geçici dizine yazar, sonra host paylaşımına kopyalar
9. kurulu sistem reboot ettikten sonra ilk açılış smoke service’inden gelen seri port çıktısını bekler

### Başarı Kriteri Nedir?

Seri log içinde şu işaret görülmelidir:

```text
RO_INSTALLER_VM_BOOT_OK
```

Bu işaretin anlamı şudur:

1. kurulum bitmiş
2. sistem diskten gerçekten açılmış
3. hedef sistemde test amaçlı ilk açılış servisi çalışmış

Bu, yalnızca “kurulum tamamlandı” değil, “ilk açılış da gerçekleşti” anlamına gelir.

## 11. Otomatik VM Testinde Üretilen Dosyalar

Varsayılan çıktı klasörü:

```text
outputs/vm/TARIH-SAAT/
```

Burada tipik olarak şunları görürsünüz:

1. `test_disk.qcow2`
   - kurulan hedef disk imajı
2. `serial.log`
   - reboot sonrası seri port logu
3. `OVMF_VARS.fd`
   - UEFI değişken dosyası
4. `qmp.sock`
   - QEMU kontrol socket’i

Başsız kurulum logları ise tipik olarak burada olur:

```text
outputs/vm-logs/
```

veya çalışma sırasında verilen `RO_INSTALLER_LOG_DIR` altında tutulur.

## 12. Hata Olduğunda Nasıl Okunur?

### 12.1 `flutter test` Kırılırsa

Önce test adını okuyun:

1. `ChrootConfigStage` ise chroot ve kullanıcı yönetimi
2. `BootloaderStage` ise GRUB/BLS/cmdline zinciri
3. `PostInstallValidationStage` ise kurulum sonrası artefakt doğrulaması

### 12.2 Otomatik VM Testi Kırılırsa

Önce şu soruları sırayla cevaplayın:

1. `serial.log` içinde `RO_INSTALLER_VM_BOOT_OK` var mı
2. hiç yoksa kurulum mu bitmedi, yoksa reboot sonrası sistem mi açılmadı
3. `outputs/vm-logs` altında başsız kurulum logları yazılmış mı
4. `test_disk.qcow2` oluştu mu
5. kurulum logunda stage bazlı ilk hata nerede

### 12.3 Tipik Başarısızlık Sınıfları

1. Live oturuma komut hiç enjekte edilemedi
   - QMP tarafı, Live açılış süresi veya GNOME hazır olma zamanı sorunlu olabilir
2. Kurulum başladı ama stage düştü
   - başsız kurulum logunda ilgili stage mesajı görünür
3. Kurulum bitti ama marker gelmedi
   - diskten boot edememiş olabilir
   - EFI/BLS/grub zinciri kırılmış olabilir
   - smoke service etkinleşmemiş olabilir

## 13. Ne Zaman Hangi Testi Çalıştırmalısınız?

### Küçük Kod Değişikliği Sonrası

1. ilgili stage testini çalıştırın
2. ilgili dosyalara hedefli analyze çalıştırın

### Kurulum Motoruna Dokunduysanız

1. `flutter test`
2. ilgili stage testleri
3. mümkünse otomatik VM testi

### Release Öncesi

1. `flutter test`
2. `flutter analyze`
3. BTRFS otomatik VM testi
4. EXT4 otomatik VM testi

## 14. Şu Anki Gerçek Durum

Bu belge yazıldığı anda:

1. `flutter test` yeşildir
2. kritik chroot adımları fail-fast haldedir
3. kritik bootloader komutları fail-fast haldedir
4. kurulum sonrası doğrulama paket ve artefakt seviyesine çıkarılmıştır
5. otomatik VM akışı için gerekli scriptler hazırlanmıştır

Ama şu gerçeği unutmamalısınız:

**Otomatik VM testi gerçek QEMU ortamında düzenli çalıştırılmadan “tam çözüldü” hükmü verilmemelidir.**

## 15. Kısa Komut Özeti

### Tam test

```bash
PATH="$HOME/.local/bin:$HOME/development/flutter/bin:$PATH" flutter test
```

### Hedefli boot testi

```bash
PATH="$HOME/.local/bin:$HOME/development/flutter/bin:$PATH" \
flutter test test/services/install_stages/bootloader_stage_test.dart
```

### Hedefli chroot testi

```bash
PATH="$HOME/.local/bin:$HOME/development/flutter/bin:$PATH" \
flutter test test/services/install_stages/chroot_config_stage_test.dart
```

### Hedefli post-install testi

```bash
PATH="$HOME/.local/bin:$HOME/development/flutter/bin:$PATH" \
flutter test test/services/install_stages/post_install_validation_stage_test.dart
```

### Tüm proje analizi

```bash
PATH="$HOME/.local/bin:$HOME/development/flutter/bin:$PATH" flutter analyze
```

### Otomatik VM testi

```bash
./test_qemu_vm.sh auto test/fixtures/profile_full_btrfs.json
```
