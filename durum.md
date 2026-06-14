# Ro-Installer Proje Durum Raporu

## 1. Raporun Amacı

Bu rapor, `/home/smurat/Ro-ASD/Installer/ro-Installer` klasörü içindeki projeyi dosya dosya inceleyerek hazırlanmıştır. Amaç; projenin mimarisini, çalışma şeklini, güçlü ve zayıf yönlerini, avantajlarını, dezavantajlarını, teknik risklerini, bakım durumunu ve üretim kullanımı açısından taşıdığı sonuçları tamamen Türkçe biçimde ortaya koymaktır.

Bu proje genel olarak Flutter (Google'ın çoklu platform arayüz geliştirme çatısı) ile yazılmış, Linux odaklı çalışan bir grafiksel kurulum aracı (installer, yani işletim sistemi yükleyicisi) görünümündedir. Ancak sadece görsel bir prototip değildir; doğrudan disk, bölümleme, biçimlendirme, bağlama, dosya kopyalama, chroot (hedef sistemi geçici olarak kök sistem gibi çalıştırma), bootloader (önyükleyici) kurulumu gibi gerçek sistem işlemlerine girecek altyapıyı da içermektedir.

## 2. Genel Yönetici Özeti

Proje teknik olarak iki ana katmanda ilerliyor:

1. Flutter tabanlı arayüz katmanı (kullanıcıyla etkileşim kuran görsel katman).
2. Dart üzerinden sistem komutları çalıştıran kurulum motoru (arka planda gerçek Linux araçlarıyla çalışan katman).

Bu yapı, teorik olarak hafif, hızlı ve bağımlılığı nispeten düşük bir kurulum sihirbazı sunuyor. Özellikle Calamares (Linux dağıtımlarında sık kullanılan modüler kurulum aracı) veya Anaconda (özellikle Fedora/RHEL tarafında kullanılan daha ağır kurulum altyapısı) gibi büyük çatıların yerine daha kontrollü ve proje özelinde şekillenebilir bir çözüm amaçlanmış.

Bununla birlikte proje henüz tam anlamıyla üretim sertliğinde (production-grade, yani gerçek son kullanıcı ve veri güvenliği için olgun) görünmüyor. Bunun ana sebepleri:

- Bazı işlemler gerçek disklerde geri döndürülemez sonuçlar doğuracak kadar güçlü.
- Güvenlik doğrulaması ve hata toleransı bazı kritik noktalarda eksik.
- Manuel bölümleme ile gerçek disk uygulaması arasında tam bir köprü kurulmamış.
- Belgelerde anlatılan bazı özelliklerle gerçek kod arasında kısmi uyumsuzluklar var.
- Test altyapısı neredeyse yok.

Özetle: Proje vizyon olarak güçlü, mimari olarak umut verici, kullanıcı deneyimi bakımından iddialı; fakat disk işlemleri yapan bir ürün için halen yüksek riskli alanlar barındırıyor.

## 3. Projenin Ana İşlevi

Ro-Installer, Ro-ASD işletim sistemini Linux üzerinde grafik arayüzle kurmak için tasarlanmış bir yükleyicidir. Kullanıcı aşağıdaki akıştan geçer:

1. Dil seçimi.
2. Tema seçimi.
3. Bölge, saat dilimi ve klavye seçimi.
4. Ağ bağlantısı denetimi ve Wi-Fi bağlanma.
5. Kullanıcı hesabı oluşturma.
6. Kurulum türü seçimi.
7. Disk seçimi ve bölümleme yöntemi belirleme.
8. Gelişmiş modda kernel (çekirdek) tipi seçimi.
9. Gerçek kurulumun başlatılması.

Kurulum başladığında uygulama aşağıdaki sistem araçlarını çalıştıracak şekilde tasarlanmıştır:

- `lsblk` (blok aygıtlarını listeleme aracı)
- `nmcli` (NetworkManager komut satırı aracı)
- `sgdisk` (GPT bölüm tablosu yönetim aracı)
- `wipefs` (disk üzerindeki dosya sistemi imzalarını temizleme aracı)
- `mkfs.*` araçları (dosya sistemi oluşturma araçları)
- `mount` / `umount` (bağlama ve ayırma)
- `rsync` (dosya eşitleme ve hızlı kopyalama aracı)
- `chroot` (hedef sistemi geçici olarak aktif ortam gibi kullanma)
- `grub2-install` ve `grub2-mkconfig` (GRUB önyükleyicisini kurma ve yapılandırma)
- `dracut` (initramfs, yani başlangıçta gerekli geçici kök dosya sistemi imajını üretme)

## 4. Mimari Yapı

### 4.1 Arayüz Katmanı

`lib/screens/` altındaki ekranlar kurulum sihirbazının görsel adımlarını oluşturuyor. `Provider` (Flutter içinde durum paylaşımı için kullanılan durum yönetim çözümü) ile `InstallerState` sınıfından besleniyorlar.

### 4.2 Durum Katmanı

`lib/state/installer_state.dart` tüm akışın merkezi durum deposu (state store, yani ekranlar arası taşınan veri merkezi) gibi çalışıyor. Kullanıcının dil, disk, hesap, bölümleme ve ağ gibi tüm seçimleri burada tutuluyor.

### 4.3 Servis Katmanı

`lib/services/` klasörü gerçek iş mantığını taşıyor. Burada disk tarama, ağ tarama, bölüm okuma, komut çalıştırma, log dışa aktarma ve asıl kurulum orkestra yönetimi bulunuyor.

### 4.4 Aşamalı Kurulum Katmanı

`lib/services/install_stages/` klasörü projedeki en iyi tasarlanmış alanlardan biri. Kurulum tek parça değil, 8 ayrı stage (aşama) olarak modellenmiş:

1. Disk hazırlığı
2. Bölümleme
3. Biçimlendirme
4. Bağlama
5. Dosya kopyalama
6. Chroot yapılandırma
7. Bootloader kurulumu
8. Temizlik

Bu ayrım bakım kolaylığı (maintainability, yani kodun sürdürülebilir şekilde geliştirilebilmesi) açısından artıdır.

### 4.5 Linux Yerel Katman

`linux/` klasörü Flutter Linux masaüstü uygulaması için gereken yerel derleme ve paketleme dosyalarını içeriyor. Ayrıca C++ tabanlı bir backend (arka uç yerel kütüphane) taslağı da bulunuyor; ancak mevcut Dart akışında bu backend fiilen kullanılmıyor.

## 5. Güçlü Yönler

### 5.1 Aşamalı Kurulum Tasarımı

Kurulum motorunun stage yapısına ayrılmış olması çok olumlu. Bu yaklaşım:

- Hataları hangi aşamada aldığını anlamayı kolaylaştırır.
- Geliştiricinin bir bölümü diğerlerinden bağımsız iyileştirmesine izin verir.
- Gelecekte test yazmayı kolaylaştırır.
- Günlükleme (logging, yani işlem kaydı tutma) kalitesini artırır.

### 5.2 Arayüz ve Sistem Katmanının Ayrılması

Ekranlar doğrudan disk komutları çalıştırmıyor; bunun yerine servisler üzerinden ilerliyorlar. Bu da katmanlı mimari (layered architecture, yani sorumlulukların ayrı katmanlara dağıtılması) açısından doğru bir yaklaşım.

### 5.3 Ağ ve Disk Algılama Denemesi

Uygulama sadece sabit form alanı sunmuyor; mevcut diski, canlı sistemi (live USB), mevcut işletim sistemini ve ağ durumunu algılamaya çalışıyor. Bu, yükleyicinin gerçek kullanım senaryosuna uygun geliştirildiğini gösteriyor.

### 5.4 Log Dışa Aktarma Servisi

`InstallLogExportService`, kurulum oturumunu `.log` ve `.summary.json` olarak dışa aktarıyor. Bu, hata analizi ve kullanıcı desteği için önemli bir artı.

### 5.5 Root Yetkisi Kontrolü

`main.dart` içinde uygulama root (en yüksek yönetici yetkisi) ile çalışıp çalışmadığını kontrol ediyor ve gerekirse `pkexec` ile yeniden başlatmaya çalışıyor. Disk yazma yapan bir ürün için bu zorunlu bir koruma.

### 5.6 Manuel Bölümleme Doğrulaması

Manuel bölümleme ekranı, en azından kağıt üzerinde şu doğrulamaları yapıyor:

- `/` kök dizini var mı
- EFI bölümü var mı
- EFI boyutu uygun mu
- Uygun dosya sistemi seçilmiş mi
- SWAP var mı, yoksa kullanıcı uyarılıyor mu

Bu ekran, projenin en ciddi düşünülmüş alanlarından biri.

## 6. Zayıf Yönler ve Riskler

### 6.1 Gerçek Disk İşlemleri İçin Halen Yüksek Risk

Uygulama gerçek `wipefs`, `sgdisk`, `mkfs`, `mount`, `rsync`, `chroot` komutları çalıştırıyor. Bu, ürünün sadece vitrin olmadığını gösterse de güvenlik ve doğrulama eksik olduğunda veri kaybı riski çok yüksektir.

Özellikle şu riskler dikkat çekiyor:

- Yanlış disk seçimi geri döndürülemez veri kaybı doğurabilir.
- Disk doğrulama katmanı bazı varsayımlara dayanıyor.
- Bazı komutlar başarısız olsa bile sonraki komutlara geçilen yerler var.

### 6.2 Manuel Bölümleme Gerçekte Tam Uygulanmıyor

En kritik bulgulardan biri budur.

`ManualPartitionScreen` içinde kullanıcı yeni bölüm ekliyor, silme planı yapıyor, yeniden boyutlandırma planı yapıyor ve format planı yapıyor. Ancak `PartitioningStage` manuel modda sadece:

"Kullanıcı planı kullanılacak."

anlamına gelen bir onay dönüyor; gerçek disk üstünde yeni bölüm oluşturma veya yeniden boyutlandırma işlemi yapılmıyor.

Yani kullanıcı arayüzünde oluşturulan "plan" ile fiziksel disk üstündeki gerçek GPT/MBR bölüm tablosu değişiklikleri arasında eksik bir bağ var.

Bu şu sonuca yol açabilir:

- Kullanıcı "yeni bölüm oluşturdum" sanır.
- Fakat gerçekte diskte o bölüm yoktur.
- Sonraki aşamada biçimlendirme veya bağlama, hayali ya da yanlış bölüm adlarıyla çalışmaya kalkabilir.

Bu tek başına üretim kullanımı için büyük bir engeldir.

### 6.3 Şifre İşleme Güvenlik Açısından Zayıf

`ChrootConfigStage` içinde kullanıcı şifresi ve root şifresi kabuk komutlarıyla düz metin (plain text, yani açık metin) olarak işleniyor:

- Kullanıcı parolası `echo 'user:pass' | chpasswd`
- Root parolası `echo 'root:root' | chpasswd`

Buradaki problemler:

- Komut geçmişi ve süreç görünürlüğü açısından hassas veri riski oluşabilir.
- Root şifresinin sabit olarak `root` atanması ciddi güvenlik açığıdır.
- Log sanitization (günlükte hassas veri maskeleme) bazı durumları temizlemeye çalışsa da kökten güvenli çözüm değildir.

### 6.4 Root Şifresinin Varsayılan Olarak `root` Yapılması

Bu çok ciddi bir zayıflıktır. Kurulan sistemde root hesabına sabit ve tahmin edilebilir parola verilmesi saldırı yüzeyini (attack surface, yani kötü niyetli erişim ihtimalini) ciddi biçimde artırır.

### 6.5 Ağ ve Çeviri Alanında Yarım Kalmış Tutarlılık

Uygulama Türkçe, İngilizce ve İspanyolca çeviri taşıyor. Ancak ekranların önemli bölümlerinde hala doğrudan İngilizce sert yazılmış metinler var:

- `Connected`
- `Disconnected`
- `Rescan`
- `No Wi-Fi networks found`
- `Full Name`
- `Username`
- `Password`
- `Confirm Password`

Bu da yerelleştirme (localization, yani çok dilli kullanım desteği) altyapısının yarım kaldığını gösteriyor.

### 6.6 Dokümantasyon ile Kod Tam Örtüşmüyor

README dosyası projeyi çok olgun, çok güvenli ve ileri düzey doğrulamaları tamamlanmış gibi anlatıyor. Ancak gerçek kodda:

- Testler yok.
- Manual partition fiziksel uygulaması eksik.
- C++ backend kullanımı pasif.
- Bazı versiyon numaraları tutarsız.
- Reboot butonu `TODO` halinde bırakılmış.

Bu yüzden belgede anlatılan olgunluk seviyesi ile gerçek uygulama arasında mesafe var.

### 6.7 Statik Analiz ve Test Altyapısı Görünmüyor

Projede `test/` klasörü yok. Birim test (unit test, küçük fonksiyon seviyesinde doğrulama), widget test (Flutter arayüz parçası testi), entegrasyon test (bileşenler arası uçtan uca doğrulama) bulunmuyor.

Bu kadar kritik disk işlemi yapan bir projede test eksikliği büyük risktir.

### 6.8 `flutter` Aracı Bu Ortamda Kurulu Değil

Çalışma ortamında `flutter --version` ve `flutter analyze` komutları denenmiş, ancak `flutter: command not found` sonucu alınmıştır. Bu yüzden otomatik statik doğrulama bu inceleme sırasında yapılamamıştır.

Bu, doğrudan proje kusuru olmayabilir; fakat mevcut incelemede analiz sonuçlarının derleme ile teyit edilemediği anlamına gelir.

### 6.9 C++ Backend Mevcut Ama Fiilen Kullanılmıyor

`linux/backend/installer_core.cpp` ve `system_command.h` içinde gerçek sistem komutları çalıştırabilen C++ kodu var. Ancak Dart tarafında buna bağlı bir FFI (Foreign Function Interface, yani farklı programlama dilindeki kütüphanelerle haberleşme köprüsü) kullanımı görünmüyor.

Bu durum şu anlama gelir:

- Kodun bir bölümü aktif kullanımda değil.
- Geleceğe dönük taslak bırakılmış.
- Bakımı yapılmazsa ölü kod (dead code, yani var ama çalışmayan/çağrılmayan kod) haline gelir.

## 7. Avantajlar

- Hafif bağımlılık yaklaşımı var.
- Arayüz modern ve dikkat çekici.
- Linux kurulum akışı gerçek sistem araçlarıyla entegre.
- Stage temelli mimari ileride profesyonelleştirilmeye çok uygun.
- Log dışa aktarma bulunuyor.
- Disk ve ağ tespiti salt statik form değil, dinamik veriyle besleniyor.
- BTRFS subvolume (alt hacim) kurulum düşüncesi eklenmiş.

## 8. Dezavantajlar

- Kritik disk işlemleri için güvenlik olgunluğu henüz yeterli değil.
- Manuel bölümleme büyük ölçüde "planlama arayüzü" düzeyinde kalmış.
- Test yok.
- Yerelleştirme tam değil.
- Dokümantasyon pazarlama dili ile gerçek kod arasında fark var.
- Sürüm tutarlılığı zayıf.
- Root parola politikası ciddi biçimde sorunlu.
- Reboot sonrası akış bitmemiş.

## 9. Dosya Dosya İnceleme

Bu bölümde `.git` içindeki Git iç verileri hariç, proje kapsamında anlamlı olan dosyalar tek tek özetlenmiştir.

### 9.1 Kök Dizin Dosyaları

#### `README.md`

Projenin vitrin ve tanıtım belgesi. İngilizce ve Türkçe açıklama içeriyor. Projeyi iddialı ve gelişmiş biçimde sunuyor. Mimariyi iki katmanlı anlatıyor. Gerçek disk araçlarından söz ediyor. Ancak belgede anlatılan "ileri güvenlik/doğrulama" seviyesinin tümü kodda eksiksiz karşılık bulmuyor.

#### `pubspec.yaml`

Flutter paket tanımı. Paket adı `ro_installer`. Sürüm `1.2.7+1`. Bağımlılıklar çok az:

- `flutter`
- `provider`
- `cupertino_icons`

Az bağımlılık avantajdır; ancak bazı ihtiyaçlar yerel komutlarla çözüldüğü için riskin kod içine taşındığını da gösterir.

#### `pubspec.lock`

Bağımlılıkların kilitlenmiş sürümleri. `provider` kilitli sürümü `6.1.5+1` iken `pubspec.yaml` içinde `^6.1.2` yazıyor. Bu doğal bir durum olabilir. Genel olarak küçük ölçekli bağımlılık setini doğruluyor.

#### `analysis_options.yaml`

Varsayılan `flutter_lints` (Flutter için önerilen lint kuralları, yani kod kalite denetimleri) kullanılıyor. Özel sıkılaştırma görünmüyor. Bu da kod kalite standardının varsayılan seviyede kaldığını gösteriyor.

#### `.gitignore`

Flutter, IDE ve derleme çıktıları için standart dışlama kuralları içeriyor. Uygun ve beklenen bir dosya.

#### `.metadata`

Flutter araç zinciri tarafından yönetilen proje metaverisi (yardımcı teknik kimlik bilgileri). Linux dahil birçok platform için oluşturulmuş klasik Flutter uygulaması olduğunu gösteriyor.

#### `.idea/*`

JetBrains tabanlı IDE ayar dosyaları. Çalışma ortamı tercihlerini gösterir; proje mantığına doğrudan etkisi yoktur. Sürüm kontrolüne girmemesi gerekir; kök `.gitignore` zaten `.idea/` dizinini dışlıyor.

### 9.2 Varlık Dosyaları

#### `assets/images/slide1.png`
Kurulum ekranında gösterilen tanıtım slaytı. Boyut olarak büyükçe bir görsel dosya.

#### `assets/images/slide2.png`
Kurulum sırasında gösterilen ikinci tanıtım görseli.

#### `assets/images/slide3.png`
Kurulum sırasında gösterilen üçüncü tanıtım görseli.

Bu üç dosya kullanıcı deneyimini (UX, yani kullanım deneyimi) güçlendiriyor; ancak uygulamanın gerçek işlevine etkileri görseldir.

### 9.3 `lib/` Altı Ana Uygulama Dosyaları

#### `lib/main.dart`

Uygulamanın başlangıç noktası. Root kontrolü yapıyor. Root değilse `pkexec` ile yeniden açmaya çalışıyor. Sonra `InstallerState` ile uygulamayı başlatıyor. Dinamik step (adım) seçimi ile doğru ekranı gösteriyor.

Artıları:

- Root kontrolü var.
- Ekran geçişi merkezi.
- Uygulama başlatma akışı temiz.

Eksileri:

- `pkexec` başarısızlık durumu kullanıcıya arayüzle değil, yalnızca log ile bildiriliyor.

#### `lib/state/installer_state.dart`

Projenin merkezi durum deposu. Ağ kontrol zamanlayıcısı (timer, yani belirli aralıklarla çalışan sayaç) kuruyor. Dil, tema, konum, ağ, hesap, kurulum türü, disk seçimi, kernel türü gibi tüm verileri tutuyor. Çeviri sözlüğünü de içeriyor.

Artıları:

- Tüm akış tek yerden yönetiliyor.
- Dinamik adım sistemi mevcut.
- Disk seçildiğinde arka planda mevcut işletim sistemi algılanıyor.

Eksileri:

- Çok fazla sorumluluk tek dosyada toplanmış.
- Çeviri sistemi bu dosyanın içinde tutulmuş; ölçek büyürse zorlaşır.
- Varsayılan kullanıcı adı ve parola gibi test değerleri üretim riski doğurabilir.

#### `lib/theme/app_theme.dart`

Açık ve koyu tema tanımları. Modern, canlı ve belirgin renk paleti sunuyor.

Artıları:

- Görsel kimlik güçlü.
- Temalar merkezi dosyada.

Eksileri:

- `Inter` yazı tipi tanımlanmış ama `pubspec.yaml` içinde özel font dosyası tanımı yok; sistemde yoksa beklenen görünüm garanti değildir.

### 9.4 `lib/screens/` Ekranları

#### `welcome_screen.dart`

Dil seçimi ve ilk adım. Basit, anlaşılır ve temiz.

#### `theme_screen.dart`

Tema seçimi ekranı. Görsel olarak en güçlü ekranlardan biri. İki kartlı seçim yapısı var.

#### `location_screen.dart`

Bölge, saat dilimi ve klavye seçimi. Sabit liste kullanıyor.

Eksisi:

- Dinamik zaman dilimi veya klavye tespiti yok.

#### `network_screen.dart`

Ethernet ve Wi-Fi tarama ekranı. `nmcli` üzerinden ağları listeliyor. Wi-Fi şifresi sorabiliyor.

Artıları:

- Gerçek ağ tarama yapıyor.
- Bağlı ağı algılıyor.

Eksileri:

- Metinlerin bir kısmı çevrilmemiş.
- Ağ başarısızlık detayları sınırlı.

#### `account_screen.dart`

Kullanıcı hesabı oluşturma ekranı. Form doğrulaması içeriyor.

Artıları:

- Parola doğrulaması var.
- Yönetici yetkisi anahtarı var.

Eksileri:

- Etiketler çoğunlukla İngilizce.
- Parola politikası çok zayıf; 4 karakter alt sınırı güvenli değil.

#### `type_screen.dart`

Standart ve gelişmiş kurulum seçimi.

Artıları:

- Kurulum karmaşıklığı kullanıcı seviyesine göre ayrılıyor.

#### `disk_selection_screen.dart`

Disk listesi, dosya sistemi ve kurulum yöntemi seçimi.

Artıları:

- Live disk ve host disk için uyarılar var.
- Alongside (yanına kurulum) mantığı için boş alan ve mevcut OS algısı kullanılıyor.

Eksileri:

- Disk güvenliği için gösterilen uyarılar iyi olsa da alt katmandaki mutlak güvence yetersiz.
- Boyut ve güvenlik mantığı bazı kaba varsayımlara dayanıyor.

#### `manual_partition_screen.dart`

Elle bölümleme ekranı.

Artıları:

- Görsel olarak güçlü.
- Doğrulama mantığı ciddi emek içeriyor.
- Kullanıcıyı EFI, root, swap gibi gereksinimlerde yönlendiriyor.

Eksileri:

- Arayüzde yapılan yeni bölümleme planı fiziksel disk üstünde uygulanmıyor.
- Bu nedenle şu haliyle güven hissi verse de gerçek davranış açısından yanıltıcı olabilir.

#### `kernel_screen.dart`

Kararlı ve deneysel kernel seçimi ekranı.

Artıları:

- Ağ bağlantısı yoksa deneysel seçeneği kısıtlıyor.

Eksileri:

- Kernel sürümleri sabit metin halinde; dinamik kaynak yok.
- Seçilen kernelin gerçekten kurulumda nasıl uygulanacağı koddaki diğer aşamalarda görünmüyor.

#### `installing_screen.dart`

Kurulum süreci, durum geçmişi, teknik log ve tanıtım slaytları burada gösteriliyor.

Artıları:

- Teknik log görünürlüğü çok değerli.
- Kurulum sonunda oturum logunu dışa aktarıyor.

Eksileri:

- Yeniden başlatma butonu gerçek reboot işlemine bağlı değil, `TODO`.

### 9.5 `lib/services/` Servisleri

#### `command_runner.dart`

Merkezi komut çalıştırıcı. `Process.start` ile komutları çalıştırıyor, stdout/stderr akışlarını ayrı topluyor, log olayları üretiyor.

Bu dosya projenin en kritik ve iyi yazılmış parçalarından biri.

#### `network_service.dart`

`nmcli` ile ethernet kontrolü, Wi-Fi tarama ve bağlanma sağlıyor.

Artıları:

- SSID içinde `:` karakteri olmasını hesaba katması dikkatli bir detay.

Eksileri:

- Hata detayları daha zengin döndürülmüyor.

#### `disk_service.dart`

`lsblk` ile disk listesi çıkarıyor, mevcut işletim sistemi ve EFI algısı yapıyor.

Artıları:

- Live ortam ve host disk ayrımı için çaba var.

Eksileri:

- Boş alan hesabı gerçek bölüm tablosu boşluklarını değil, çoğu zaman `toplam disk - toplam bölüm boyutu` mantığını kullanıyor; bu her durumda doğru olmayabilir.
- EFI tespitinde `vfat` varlığını görüyor ama son kararı GPT tip UUID ile sınırlıyor; bu iyi ama yine de pratikte bazı diskleri yanlış yorumlama ihtimali var.

#### `partition_service.dart`

Diskteki bölümleri okuyor ve serbest alanı tablo sonunda varsayımsal biçimde ekliyor.

Eksileri:

- Diskteki gerçek boşluklar bölüm aralarındaysa, bu servis onları modelleyemiyor.
- Yani arada duran unallocated area (atanmamış boş alan) bilgisi tam temsil edilmiyor.

#### `install_log_export_service.dart`

Kurulum loglarını diske yazıyor, hassas bilgileri maskelemeye çalışıyor.

Artıları:

- Destek süreçleri için çok faydalı.

Eksileri:

- Hassas bilgiyi önce üretip sonra maskelemek, en güvenli yöntem değildir.

#### `install_service.dart`

Asıl orkestratör. 8 stage'i sırayla çalıştırıyor.

Artıları:

- Sorumluluk ayrımı iyi.
- Başarısız aşamada duruyor.

Eksileri:

- Bazı stage içi `runCmd` çağrılarının dönüş değeri kontrol edilmeden devam edilen yerler var; bu da stage içi sessiz başarısızlık riski doğurabilir.

### 9.6 `lib/services/install_stages/` Dosyaları

#### `install_stages.dart`

Toplu dışa aktarım dosyası. Temiz bir düzenleme tercihi.

#### `stage_context.dart`

Tüm stage'lere ortak veri taşıyan bağlam nesnesi. Gayet uygun.

#### `stage_result.dart`

Stage dönüş sözleşmesi. Basit ve yeterli.

#### `disk_preparation_stage.dart`

Diskteki bağları kesmeye ve swap kapatmaya çalışıyor.

Risk:

- `umount -f $selectedDisk*` gibi ifadeler çok güçlü ve kaba davranabilir.

#### `partitioning_stage.dart`

Tam disk ve yanına kurulum bölümlemesini yapıyor.

Artıları:

- Tam disk ve alongside ayrımı net.
- SWAP boyutunu RAM'e göre hesaplıyor.

Eksileri:

- Manual mod gerçek bölüm uygulamasını yapmıyor.
- Alongside işlemi mevcut bölümü küçültmüyor; yalnızca sona yeni bölüm ekleme varsayımına dayanıyor gibi görünüyor. Bu her disk yapısında çalışmayabilir.

#### `formatting_stage.dart`

Yeni bölümleri dosya sistemiyle biçimlendiriyor.

Artıları:

- BTRFS, EXT4, XFS, FAT32 ve SWAP desteklenmiş.

Eksileri:

- Manual modda `name` alanını bölüm yolu gibi kullanıyor; planlı yeni bölümlerde bu alan `"New Partition"` olabilir. Bu durumda gerçek sistemde biçimlendirme başarısız olur.

#### `mounting_stage.dart`

Bölümleri `/mnt` altına bağlıyor.

Artıları:

- BTRFS için `@` ve `@home` subvolume oluşturuyor.

Eksileri:

- Manual modda önce kök bölüm basit `mount` ile bağlanıyor; BTRFS ise burada subvolume mantığı uygulanmıyor.
- `firstWhere(... orElse: () => null)` yaklaşımı null güvenliği (null safety, yani boş değer güvenliği) açısından kırılgan.

#### `file_copy_stage.dart`

Canlı sistemi hedef diske `rsync` ile aktarıyor.

Artıları:

- Dinamik dışlama listesi düşünülmüş.
- `xattr` (genişletilmiş öznitelik, yani dosya sistemi ek meta bilgisi) desteklemeyen dizinler için ikinci kopyalama yolu var.

Eksileri:

- Dinamik dışlamalar karmaşık; gerçek sistemlerde beklenmedik mount noktaları sorun çıkarabilir.

#### `chroot_config_stage.dart`

Hedef sistem ayarlarını oluşturuyor.

Artıları:

- `machine-id`, timezone, sudoers, fstab, `.autorelabel` gibi noktaları düşünüyor.

Eksileri:

- Root parolası sorunu var.
- Locale sabit `en_US.UTF-8`; kullanıcı dilinden türetilmiyor.
- Klavye ayarı var ama bölge ve dil tam entegre değil.

#### `bootloader_stage.dart`

GRUB kurulumunu yapıyor.

Artıları:

- EFI bağlı mı diye doğruluyor.
- `dracut -> grub2-install -> grub2-mkconfig` sıralaması mantıklı.

Eksileri:

- `grub2-install` içinde `--bootloader-id=fedora` sabitlenmiş; Ro-ASD için isimlendirme açısından tuhaf ve dağıtıma özel bağımlılık göstergesi.

#### `cleanup_stage.dart`

Temizlik aşaması. Basit ama işlevsel.

### 9.7 `lib/widgets/` Yardımcı Bileşenleri

#### `glass_container.dart`

Cam efekti (glassmorphism, yani yarı saydam bulanık kart görünümü) sağlayan kapsayıcı bileşen.

#### `installer_layout.dart`

Tüm ekranların genel iskeleti. Arka plan, üst çubuk, adım çubuğu ve içerik alanını yönetiyor.

Artıları:

- Tasarım dili tutarlı.

Eksileri:

- Sürüm metni burada `v2.4.0 Build`, ama `pubspec.yaml` içinde `1.2.7+1`; bu tutarsızlık kafa karıştırır.

### 9.8 `linux/` Yerel Platform Dosyaları

#### `linux/CMakeLists.txt`

Linux Flutter derleme ana dosyası. `ro_backend` adlı paylaşımlı kütüphaneyi de kurulum paketine dahil ediyor.

#### `linux/backend/CMakeLists.txt`

C++ backend kütüphanesini tanımlıyor.

#### `linux/backend/installer_core.cpp`

Yerel C++ backend taslağı. Disk listeleme, bölüm biçimlendirme, shrink, squashfs çıkarma, chroot ve ilerleme simülasyonu içeriyor.

Artıları:

- Gelecekte yüksek performanslı veya sistem seviyesi daha kontrollü bir backend'e evrilebilecek bir yön gösteriyor.

Eksileri:

- Şu an aktif kullanım izi yok.
- Kod içinde tekrar eden include satırları var.
- Komut birleştirme ve kabuk üzerinden çalışma, güvenlik açısından sertleştirilmeli.

#### `linux/backend/system_command.h`

Kabuk komutu çalıştıran C++ yardımcı sınıfı.

Eksileri:

- Komutları kabuk üzerinden doğrudan çalıştırdığı için enjeksiyon (command injection, yani dış girdinin komut üretmesine neden olması) riski taşır.

#### `linux/org.roasd.installer.policy`

Polkit (grafiksel yetki yükseltme sistemi) policy dosyası. Uygulamanın yönetici yetkisi istemesi için gerekli.

Not:

- `allow_any`, `allow_inactive`, `allow_active` değerleri `auth_admin_keep`; açıklama yorumunda "şifresiz yetki yükseltme" denmiş ama gerçek değer tam olarak sınırsız otomatik yükseltme anlamına gelmez.

#### `linux/ro-installer-launcher.sh`

Başlatıcı kabuk betiği. Root ise doğrudan, değilse `pkexec` ile başlatıyor.

#### `linux/ro-installer.desktop`

Masaüstü kısayol dosyası.

Not:

- Yorum satırında launcher script'ten söz edilse de `Exec` satırı doğrudan binary'yi çağırıyor. Yani dosya ile yorum birebir örtüşmüyor.

#### `linux/ro-installer.spec.reference`

RPM paketleme için referans spec dosyası.

Artıları:

- Paketleme düşünülmüş.
- Çalışma zamanı bağımlılıkları listelenmiş.

Eksileri:

- Referans dosya niteliğinde; otomatik üretim hattı (CI/CD, yani sürekli entegrasyon ve sürekli dağıtım boru hattı) görünmüyor.

#### `linux/runner/CMakeLists.txt`, `main.cc`, `my_application.cc`, `my_application.h`

Flutter Linux masaüstü kabuğu. GTK pencere başlatma ve ilk çerçeve sonrası görünür yapma mantığını içeriyor. Standart Flutter Linux runner yapısının hafif özelleştirilmiş hali.

#### `linux/flutter/CMakeLists.txt`

Flutter Linux derleme ara katmanı. Büyük ölçüde üretilmiş standart dosya.

#### `linux/flutter/generated_plugin_registrant.cc`
#### `linux/flutter/generated_plugin_registrant.h`
#### `linux/flutter/generated_plugins.cmake`

Otomatik üretilmiş dosyalar. Şu anda ek Flutter eklentisi (plugin, yani dış paket tabanlı yerel genişletme modülü) kullanılmadığını doğruluyor.

## 10. Teknik Tutarsızlıklar

Projede dikkat çeken başlıca tutarsızlıklar şunlardır:

- `pubspec.yaml` sürümü `1.2.7+1`, arayüz üst çubuğunda `v2.4.0 Build`.
- README çok olgun bir ürün izlenimi veriyor, fakat kod hala bazı alanlarda yarım.
- `ro-installer.desktop` yorumları launcher mantığını anlatırken `Exec` doğrudan binary gösteriyor.
- C++ backend paketleniyor ama aktif olarak kullanılmıyor.
- Kernel ekranında versiyon seçiliyor ama stage'lerde kernel kurulumu net görünmüyor.

## 11. Güvenlik Değerlendirmesi

Bu proje için güvenlik değerlendirmesi kritik önem taşıyor çünkü uygulama diskleri silebiliyor.

Başlıca güvenlik riskleri:

- Sabit root parolası atanması.
- Düz metin parola işleme.
- Kabuk komutlarına yoğun bağımlılık.
- Manuel bölümleme ekranının güven hissi verip fiziksel uygulamada eksik kalması.
- Hata durumlarında bazı komutların sonuçlarının sıkı kontrol edilmemesi.

Olumlu güvenlik noktaları:

- Root kontrolü var.
- Live disk seçimine karşı uyarı var.
- Host disk riski için görsel işaretleme var.
- Loglarda parola maskeleme denemesi var.

Ancak toplam tabloda risk seviyesi halen yüksektir.

## 12. Bakım ve Geliştirilebilirlik Değerlendirmesi

Bakım açısından proje orta seviyede umut veriyor.

Olumlu taraflar:

- Dizin yapısı mantıklı.
- Stage ayrımı temiz.
- Komut çalıştırıcı tek merkezde.
- Görsel bileşenler ayrı dosyalara dağılmış.

Olumsuz taraflar:

- `InstallerState` aşırı büyüme riski taşıyor.
- Yerelleştirme ayrı dosya/sistem yerine state içine gömülü.
- Test olmadığı için refactor (yeniden düzenleme) maliyeti yüksek.
- C++ backend ve Dart backend arasında net strateji yok.

## 13. Üretim Hazırlık Seviyesi

Mevcut haliyle proje:

- Demo ve dahili test için etkileyici,
- kontrollü laboratuvar ortamı için kullanılabilir,
- ama gerçek son kullanıcı kurulum aracı olarak doğrudan güvenle dağıtılmaya henüz hazır görünmüyor.

Hazır olmamasının temel nedenleri:

- Manuel bölümleme eksikliği
- parola güvenliği
- test eksikliği
- versiyon ve belge tutarsızlıkları
- gerçek cihaz senaryolarında hata toleransının sınırlı olması

## 14. Öncelikli İyileştirme Önerileri

1. Manuel bölümleme planını gerçek disk işlemlerine bağlayın.
2. Root parolasını sabit atamayı tamamen kaldırın.
3. Parola işleme için daha güvenli yöntem kullanın.
4. Disk boş alan ve mevcut bölüm tespitini daha doğru hale getirin.
5. `flutter analyze`, testler ve mümkünse sanal disk entegrasyon testleri ekleyin.
6. Yerelleştirme metinlerini tamamen merkezi hale getirin.
7. Kernel seçimini gerçek kurulum aşamalarıyla bağlayın.
8. C++ backend ya aktif kullanılmalı ya da projeden çıkarılmalı.
9. Sürüm numaralarını ve belge iddialarını kodla uyumlu hale getirin.
10. Reboot akışını tamamlayın.

## 15. Sonuç

Ro-Installer, sıradan bir görsel prototipten daha ileride, ciddi bir kurulum aracı olma hedefi taşıyan bir projedir. En dikkat çekici yönleri modern arayüzü, gerçek sistem araçlarıyla entegrasyonu, stage tabanlı kurulum motoru ve loglama yeteneğidir.

Buna karşılık proje, özellikle disk işlemleri ve güvenlik tarafında henüz "tam güvenilir son kullanıcı ürünü" seviyesine ulaşmamıştır. En büyük yapısal sorun, kullanıcıya güçlü görünen manuel bölümleme arayüzünün fiziksel disk işlemlerine eksik bağlanmasıdır. Buna ek olarak parola yönetimi, test eksikliği ve belge-kod tutarsızlıkları da önemli zayıflıklardır.

Kısa hüküm şudur:

- Mimari potansiyeli yüksek.
- Tasarım kalitesi dikkat çekici.
- Sistem entegrasyonu cesur ve gerçekçi.
- Güvenlik ve operasyonel sağlamlık açısından daha fazla mühendislik çalışması gerekiyor.

Bu nedenle proje "güçlü bir temel ve iddialı bir başlangıç" olarak değerlendirilebilir; ancak üretim ortamına çıkmadan önce özellikle disk yönetimi, parola güvenliği ve test altyapısı alanlarında ciddi sertleştirme (hardening, yani güvenlik ve dayanıklılık güçlendirmesi) gerektirir.
