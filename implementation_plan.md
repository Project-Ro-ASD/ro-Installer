# Ro-Installer İlerleme Planı

## Projenin Mevcut Durumu — Özet

Tüm kaynak kodları ve belgeleri (durum.md + plan.md) detaylıca inceledim. İşte projenin kısa bir fotoğrafı:

### Güçlü Yönler
- **Stage-bazlı mimari** — Kurulum 8 bağımsız aşamaya bölünmüş, bu bakım kolaylığı sağlıyor
- **Modern arayüz** — Glassmorphism, gradient'ler, animasyonlar ile etkileyici UI
- **Gerçek sistem araç entegrasyonu** — `lsblk`, `sgdisk`, `rsync`, `chroot`, `dracut`, `grub2` kullanımı
- **Log dışa aktarma** — Kurulum oturumunu `.log` ve `.summary.json` olarak kaydetme
- **3 dil desteği** — Türkçe, İngilizce, İspanyolca çevirileri mevcut

### Kritik Sorunlar
| # | Sorun | Etki |
|---|-------|------|
| 1 | **Test altyapısı yok** | Herhangi bir değişikliğin etkisi ölçülemiyor |
| 2 | **Boot zinciri eksik** | Kurulum sonrası sistem açılmıyor |
| 3 | **`useradd` çağrısı yok** | Kullanıcı oluşturulmadan parola atanıyor |
| 4 | **Root parolası `root:root`** | Ciddi güvenlik açığı |
| 5 | **Manuel bölümleme hayali** | UI'da plan yapılıyor ama diske uygulanmıyor |
| 6 | **BLS girişleri üretilmiyor** | Fedora 43'te `grub2-mkconfig` tek başına yetmeyebilir |
| 7 | **`/etc/kernel/cmdline` yok** | Boot parametreleri eksik |
| 8 | **Reboot butonu TODO** | Kurulum bitince yeniden başlatma çalışmıyor |
| 9 | **C++ backend ölü kod** | Derleniyor ama hiçbir yerden çağrılmıyor |
| 10 | **Versiyon tutarsızlığı** | `pubspec.yaml`: 1.2.7 vs UI: v2.4.0 |

---

## plan.md'ye Sadık Kalarak İlerleme Stratejisi

`plan.md` şu öncelik sırasını belirliyor:

```
1. Önce test
2. Sonra boot zinciri
3. Sonra kurulum motoru güvenilirliği
4. Sonra mimari temizlik
5. En son belge
```

Bu sıraya tamamen sadık kalacağız. Aşağıda **Sprint 1**'in her adımını detaylandırıyorum.

---

## Sprint 1: Test Altyapısı ve Temel Sağlamlaştırma

Sprint 1, `plan.md`'nin **Aşama 0** ve **Aşama 1**'ini kapsıyor. Toplam **6 ana adım** var.

---

### Adım 1: `CommandRunner`'ı Arayüz (Abstract Class) Haline Getir

#### Ne Yapacağız?
Mevcut `CommandRunner` sınıfı `singleton` olarak doğrudan `Process.start` çağırıyor. Bunu bir **soyut sınıf (abstract class)** + **somut uygulamalar** yapısına çevireceğiz.

#### Dosya Değişiklikleri

##### [MODIFY] [command_runner.dart](file:///home/smurat/Ro-ASD/Installer/ro-Installer/lib/services/command_runner.dart)
- `CommandRunner` → `abstract class CommandRunner` olacak
- `run()` metodu `abstract` olacak
- Mevcut `Process.start` kodu → `RealCommandRunner` sınıfına taşınacak

##### [NEW] `lib/services/fake_command_runner.dart`
- `FakeCommandRunner implements CommandRunner` sınıfı oluşturulacak
- Fixture dosyalarından cevap döndürecek
- Test ortamında gerçek komut çalıştırmadan davranış simüle edecek

#### Ne İşe Yarar?
Şu an `CommandRunner.instance` her yerde doğrudan kullanılıyor. Bu da demek oluyor ki **herhangi bir testi çalıştırabilmek için gerçek bir Linux sisteme ve root yetkisine ihtiyaç var**. Bu adımdan sonra:
- Testlerde `FakeCommandRunner` kullanılabilecek
- Gerçek kurulumda `RealCommandRunner` kullanılmaya devam edecek
- Her servis hangi runner'ı kullandığını bilmeyecek (bağımlılık enjeksiyonu)

#### Avantajları
1. **Donanımsız test** — Masaüstünde bile test çalıştırılabilir
2. **Hata senaryoları** — "sgdisk başarısız olursa ne olur?" sorusu test edilebilir
3. **CI/CD uyumluluğu** — GitHub Actions'ta bile test çalışabilir
4. **Geliştirme hızı** — Her değişiklik için ISO yazmak gerekmez

#### Nasıl Kullanacaksınız?
```dart
// Gerçek kurulumda:
final runner = RealCommandRunner();

// Testlerde:
final runner = FakeCommandRunner({
  'lsblk -J -b -o NAME,MODEL,SIZE,TYPE,RM,MOUNTPOINTS':
    File('test/fixtures/lsblk_output.json').readAsStringSync(),
});
```

---

### Adım 2: `FakeCommandRunner` Oluştur

#### Ne Yapacağız?
Testlerde kullanılmak üzere sahte komut çalıştırıcısı yazacağız. Bu sınıf:
- Komut + argüman eşleşmesine göre önceden tanımlanmış çıktı döndürür
- Hata senaryolarını simüle edebilir
- Hangi komutların çağrıldığını kaydeder (doğrulama için)

##### [NEW] `lib/services/fake_command_runner.dart`

#### Ne İşe Yarar?
Gerçek disklere, ağa veya sisteme dokunmadan tüm kurulum akışını test edebilirsiniz.

#### Avantajları
1. **Güvenli** — Yanlışlıkla disk silme riski sıfır
2. **Hızlı** — Test saniyeler içinde biter
3. **Tekrarlanabilir** — Aynı test her seferinde aynı sonucu verir
4. **Hata simülasyonu** — "mkfs.btrfs başarısız olursa akış ne yapar?" test edilebilir

---

### Adım 3: Fixture Dosyaları Oluştur

#### Ne Yapacağız?
Fedora 43 canlı sistemden örnek komut çıktılarını dosya olarak saklayacağız:

##### [NEW] `test/fixtures/lsblk_single_disk.json` — Tek diskli sistem
##### [NEW] `test/fixtures/lsblk_multi_disk.json` — Çok diskli sistem
##### [NEW] `test/fixtures/lsblk_nvme.json` — NVMe diskli sistem
##### [NEW] `test/fixtures/nmcli_wifi_list.txt` — Wi-Fi tarama çıktısı
##### [NEW] `test/fixtures/nmcli_ethernet_connected.txt` — Ethernet bağlı çıktısı
##### [NEW] `test/fixtures/sgdisk_print.txt` — sgdisk bölüm tablosu çıktısı
##### [NEW] `test/fixtures/findmnt_output.txt` — findmnt çıktısı

#### Ne İşe Yarar?
Parser testlerinin gerçekçi veriyle çalışmasını sağlar. Gerçek sistemden toplanan çıktılar "altın standart" (golden test) olarak kullanılır.

#### Avantajları
1. **Gerçekçi test verisi** — Sentetik değil, gerçek sistem çıktısı
2. **Regresyon tespiti** — Parser bozulursa hemen yakalanır
3. **Edge case** — NVMe, çok diskli, boş disk gibi farklı senaryolar

#### Nasıl Kullanacaksınız?
```dart
test('DiskService tek diski doğru parse eder', () {
  final runner = FakeCommandRunner({
    'lsblk -J -b -o NAME,MODEL,SIZE,TYPE,RM,MOUNTPOINTS':
      fixture('lsblk_single_disk.json'),
  });
  final service = DiskService(runner);
  final disks = await service.getDisks();
  expect(disks.length, 1);
  expect(disks[0]['name'], '/dev/sda');
});
```

---

### Adım 4: Parser ve Servis Testleri Yaz

#### Ne Yapacağız?
`DiskService`, `NetworkService`, `PartitionService` için birim testler yazacağız.

##### [NEW] `test/services/disk_service_test.dart`
- Tek disk, çok disk, NVMe disk, boş disk, live disk ayrımı testleri
- EFI partition algılama, mevcut OS algılama testleri

##### [NEW] `test/services/network_service_test.dart`
- Ethernet bağlı/bağlı değil testleri
- Wi-Fi listesi parse testleri
- SSID'de özel karakter (:) testleri

##### [NEW] `test/services/partition_service_test.dart`
- Bölüm listesi parse testleri
- Boş alan hesaplama testleri
- Ham disk (bölümsüz) testleri

#### Ne İşe Yarar?
Disk algılama, ağ tarama ve bölüm okuma kodlarının doğru çalıştığını **her kod değişikliğinde otomatik doğrular**.

#### Avantajları
1. **Erken hata yakalama** — Parser bozulursa CI'da düşer
2. **Güvenli refactoring** — Kod yeniden düzenlerken kılavuz olur
3. **Donanımsız doğrulama** — Hiçbir fiziksel disk gerekmez

---

### Adım 5: Kurulum Profili Modeli (`InstallProfile`) Oluştur

#### Ne Yapacağız?
Kurulum motoru şu an `Map<String, dynamic>` ile çalışıyor. Bunu **tipli bir modele** çevireceğiz.

##### [NEW] `lib/models/install_profile.dart`
```dart
class InstallProfile {
  final String selectedDisk;
  final String partitionMethod; // 'full', 'alongside', 'manual'
  final String fileSystem;      // 'btrfs', 'ext4', 'xfs'
  final String username;
  final String password;
  final String timezone;
  final String keyboard;
  final bool isAdministrator;
  final double linuxDiskSizeGB;
  final List<Map<String, dynamic>> manualPartitions;
  // ...

  factory InstallProfile.fromJson(Map<String, dynamic> json);
  Map<String, dynamic> toJson();
}
```

#### Ne İşe Yarar?
- GUI bu modeli doldurur → kurulum motoruna verir
- Test sistemi JSON dosyasından aynı modeli okur → kurulum motoruna verir
- Böylece **aynı kurulum senaryosu hem GUI'den hem JSON'dan çalıştırılabilir**

#### Avantajları
1. **Tip güvenliği** — `state['selectedDisk']` yerine `profile.selectedDisk`
2. **JSON test desteği** — `InstallProfile.fromJson(file)` ile test senaryosu
3. **Tekrarlanabilir kurulum** — Aynı profil ile aynı sonuç
4. **Hata azaltma** — Yanlış key adı veya tip hatası derleme zamanında yakalanır

#### Nasıl Kullanacaksınız?
```bash
# Test için JSON profili:
{
  "selectedDisk": "/dev/sda",
  "partitionMethod": "full",
  "fileSystem": "btrfs",
  "username": "testuser",
  "password": "test1234",
  "timezone": "Europe/Istanbul",
  "keyboard": "trq",
  "isAdministrator": true
}
```

---

### Adım 6: Stage Sırası ve Akış Testleri Yaz

#### Ne Yapacağız?
Her stage'in doğru komutları doğru sırada çağırdığını test edeceğiz.

##### [NEW] `test/services/install_stages/disk_preparation_stage_test.dart`
##### [NEW] `test/services/install_stages/partitioning_stage_test.dart`
##### [NEW] `test/services/install_stages/formatting_stage_test.dart`

#### Ne İşe Yarar?
- "full" modda `sgdisk -Z`, `sgdisk -n 1:0:+512M`, `sgdisk -n 2:0:0` sırasıyla çağrılıyor mu?
- Bir komut başarısız olursa stage durduruluyor mu?
- `partprobe` çağrılıyor mu?

#### Avantajları
1. **Sıra garantisi** — Komutlar yanlış sırada çağrılırsa test düşer
2. **Hata dayanıklılığı** — Başarısız komut sonrası akış testi
3. **Stage izolasyonu** — Her stage bağımsız test edilir

---

## İlerleme Sırası

| Sıra | Adım | Bağımlılık | Tahmini Süre |
|------|------|------------|-------------|
| 1 | CommandRunner soyutlama | — | ~30 dk |
| 2 | FakeCommandRunner | Adım 1 | ~20 dk |
| 3 | Fixture dosyaları | — | ~15 dk |
| 4 | Parser/Servis testleri | Adım 1, 2, 3 | ~45 dk |
| 5 | InstallProfile modeli | — | ~30 dk |
| 6 | Stage akış testleri | Adım 1, 2, 5 | ~45 dk |

---

## Sonraki Sprintler (Özet)

### Sprint 2 (plan.md Aşama 2-3)
- QEMU/KVM test laboratuvarı
- Tam kurulum + reboot otomasyonu
- Boot zinciri inceleme ve düzeltme

### Sprint 3 (plan.md Aşama 4-6)
- `useradd` düzeltmesi
- Root parola güvenliği
- Manuel bölümleme kararı
- Mimari temizlik

---

## Onay Bekleniyor

> [!IMPORTANT]
> Bu plan, `plan.md`'nin Sprint 1 maddelerine tamamen sadık kalarak hazırlanmıştır. İlerlemeye **Adım 1: CommandRunner soyutlama** ile başlamayı öneriyorum.
>
> Her adımı yapmadan önce size ne yapacağımı açıklayacağım, avantajlarını anlatacağım ve sonra uygulayacağız.

Onaylarsanız, Adım 1 ile başlayalım mı?
