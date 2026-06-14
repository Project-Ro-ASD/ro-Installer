# Ro-Installer Güncel Teknik Yol Haritası

## 1. Bu Belgenin Amacı

Bu belge, Ro-Installer projesinin bugünkü gerçek durumuna göre yeniden hazırlanmış ana çalışma planıdır. Amaç; açık kalan eksikleri netleştirmek, işleri doğru sıraya koymak, test odaklı ilerlemek, Fedora 43 tabanlı kurulum akışını güvenilir hale getirmek ve kurulum sonrası açılış problemini kalıcı olarak çözmektir.

Bu plan hazırlanırken yalnızca kod okunmamış, ayrıca araç zinciri ve proje sağlığı da doğrulanmıştır.

## 2. Bugün Doğrulanan Teknik Durum

Bu bölüm varsayım değil, doğrudan çalıştırılmış komutlara dayanır.

### 2.1 Flutter ve Dart Durumu

Projede Flutter vardır ve çalışmaktadır. Tespit edilen yollar:

- `flutter`: `$HOME/development/flutter/bin/flutter`
- `dart`: `$HOME/development/flutter/bin/dart`

Bu araçlar sistemde vardır; ayrıca kullanıcı ortamında erişimi kolaylaştırmak için `PATH` tarafında düzenleme yapılmıştır. Yine de bazı kabuk oturumlarında tam yol kullanımı veya proje içi yardımcı komut ihtiyacı devam etmektedir. Yani sorun “araç yok” değil, “araç erişimi standart değil” seviyesindedir.

### 2.2 `flutter doctor -v` Sonucu

Doğrulanan önemli noktalar:

1. Flutter kurulu ve kullanılabilir.
2. Dart, Flutter ile birlikte kullanılabilir durumda.
3. Linux desktop hedefi teorik olarak açık.
4. Linux toolchain tarafındaki `clang` ve `clang++` görünürlüğü düzenlenmiş ve Flutter tarafında doğrulama alınmıştır.
5. Android SDK ve Chrome eksikleri bu proje için şu anda birinci öncelik değildir.

Bu nedenle şu an için en önemli ortam problemi:

**Geliştirici komutlarının proje içinde standart bir giriş noktasına bağlanmamış olması**

### 2.3 `flutter analyze` Sonucu

`flutter analyze` çalışmış ve toplam yaklaşık **130 issue** üretmiştir.

Bunların büyük kısmı:

1. `withOpacity` kullanımının yeni Flutter sürümlerinde deprecated (kullanımdan kaldırılmaya aday) olması
2. bazı widget API değişimleri
3. gereksiz importlar
4. kıvrımlı parantez (`curly braces`) uyarıları

Bu uyarıların çoğu uygulamayı şu anda doğrudan bozmaz; fakat teknik borcu (technical debt, yani sonradan maliyet çıkaracak kod kalitesi yükünü) artırır.

### 2.4 `flutter test` Sonucu

`flutter test` artık tamamen yeşildir.

Şu an doğrulanan durum:

1. Test altyapısı çalışır durumdadır.
2. Servis ve stage testleri birlikte geçmektedir.
3. Manual partition testleri güncel davranışa göre düzeltilmiştir.
4. Yeni eklenen boot doğrulama ve chroot sertleştirme testleri de yeşildir.

Bu çok önemli bir eşiktir. Çünkü artık yerel refactor sonrası “hemen geri bildirim” alınabilmektedir. Ancak bunun sınırı da nettir:

**Unit ve stage testleri yeşildir, fakat tam kurulum + reboot + açılış doğrulaması hâlâ otomatik değildir.**

## 3. Önceki Planlardan Sonra Gerçekten İyileşen Alanlar

Eski `durum.md` ve önceki `plan.md` ile karşılaştırınca aşağıdaki alanlarda gerçek ilerleme vardır.

### 3.1 Test Temeli Atılmış

Aşağıdaki önemli adımlar atılmıştır:

1. `CommandRunner` soyut sınıf (abstract class, yani ortak davranış sözleşmesi) haline getirilmiş.
2. `RealCommandRunner` ve `FakeCommandRunner` ayrımı yapılmış.
3. `DiskService`, `NetworkService`, `PartitionService` test edilebilir hale yaklaşmış.
4. Fixture (sabit test girdisi) dosyaları eklenmiş.
5. Bir dizi servis ve stage testi eklenmiş.

Bu çok önemli bir kazanımdır.

### 3.2 Hata Teşhis Mekanizması Başlamış

`InstallArtifactCollector` eklenmiş. Bu sayede kurulum aşamasında hata olursa bazı artefaktlar (inceleme çıktıları) toplanabiliyor.

Bu, önceki tamamen kör ilerlemeye göre ciddi gelişmedir.

### 3.3 Root Parolası Sorununda İlk İyileştirme Var

Önceden sabit `root:root` parolası atanıyordu. Bu kaldırılmış ve root hesabı kilitlenmeye başlanmış.

Bu olumlu bir adımdır.

### 3.4 Manual Partition Tamamen Sahte Durumdan Çıkmış

Önceden manual partition yalnızca UI planıydı. Şimdi fiziksel diske bazı işlemleri uygulamaya çalışan bir akış var.

Bu da bir ilerlemedir.

Fakat henüz güvenilir ve tamamlanmış değildir.

### 3.5 Boot Zincirinde İlk Sertleştirme Yapıldı

Aşağıdaki iyileştirmeler artık kodda vardır:

1. BTRFS ve non-manual kurulumlarda `rootflags=subvol=@` otomatik eklenmektedir.
2. `rsync` tarafında live ortama ait kritik boot dosyaları dışlanmaktadır.
3. `PostInstallValidationStage` eklenmiş ve `fstab`, `kernel cmdline`, BLS girişleri ile live parametre sızıntısı kontrol edilmektedir.
4. `kernel-install` ve `grub2-mkconfig` gibi kritik boot komutları artık warning yerine stage düşüren hata üretmektedir.
5. Temel boot paketleri ile kernel, initramfs ve EFI artefaktlarının varlığı kurulum sonunda doğrulanmaktadır.

Bu çok değerlidir; ancak gerçek kazanç ancak tam otomatik VM reboot testi geldiğinde ispatlanmış sayılacaktır.

### 3.6 Chroot Aşamasında Kritik Komutlar Sertleştirildi

Artık şu adımlar sessizce başarısız olup stage’i başarılı gösteremez:

1. bind mount hazırlıkları
2. timezone, machine-id, hostname, keyboard ve locale yazımı
3. `useradd`, `chpasswd`, `passwd -l root`
4. `fstab` üretimi ve `findmnt --verify` doğrulaması
5. `.autorelabel` üretimi

Ayrıca yönetici olmayan kullanıcı artık varsayılan olarak `wheel` grubuna eklenmemektedir.

## 4. Hâlâ Açık Kalan Ana Problemler

Bu bölüm, yeni planın omurgasını oluşturur.

## 4.1 Kritik Problemler

### Kritik 1: BTRFS Açılış Zinciri Kodda Sertleşti Ama Hâlâ Sahada Kanıtlanmış Değil

Root bölüm BTRFS ise `@` subvolume oluşturuluyor ve artık boot tarafında non-manual kurulumlar için `rootflags=subvol=@` üretiliyor.

Bu şu riski doğurur:

1. Kurulum bitiyor gibi görünür.
2. GRUB açılır.
3. Kod doğru görünse bile gerçek reboot testinde kernel başka bir nedenle yanlış köke düşebilir.
4. Sistem açılmaz.

Bu alan doğrudan kurulum sonrası boot failure (önyükleme başarısızlığı) ile ilişkilidir.

### Kritik 2: Live ISO Kalıntıları İçin İlk Temizlik Yapıldı Ama Gerçek Boot Kanıtı Eksik

Canlı sistemden rsync ile kopyalama yapılırken aşağıdaki alanlar özel dikkat istiyor:

1. `/boot/loader/entries/`
2. `/etc/kernel/cmdline`
3. `/boot/grub2/grubenv`
4. canlı sisteme özel kernel parametreleri
5. live ortama özel EFI girdileri

Bu alanın bir bölümü artık `rsync` dışlamaları ve `PostInstallValidationStage` ile korunmaktadır. Ancak gerçek EFI/BLS davranışının reboot sonrası doğrulaması hâlâ otomatik değildir.

### Kritik 3: Testler Yeşil Ama Tam Otomatik Boot Testi Hâlâ Yok

Bir planın yürüyebilmesi için ilk şart güncel test tabanının yeşil olmasıydı; bu eşik geçildi.

Ancak şu an eksik olan şey daha üst doğrulama katmanıdır:

1. tam kurulum akışı otomatik doğrulanmıyor
2. reboot sonrası açılış gerçekten test edilmiyor
3. “ISO içine gömülü kurulum gerçekten açılıyor mu” sorusunun cevabı hâlâ ağırlıkla manuel

### Kritik 4: `alongside` Gerçek Anlamda Yanına Kurulum Değil

Kod hâlâ mevcut sistemi küçültüp güvenli boş alan üretmiyor. Yalnızca diskin sonunda bölüm açmaya çalışıyor gibi davranıyor.

Bu nedenle UI’daki “yanına kur” ile gerçek davranış arasında tam uyum yoktur.

### Kritik 5: Manual Partition Hâlâ Güvenilir Değil

Manual partition fiziksel diske uygulama yapmaya başlamış olsa da:

1. gerçek boş alan konumunu doğru modellemiyor
2. resize (yeniden boyutlandırma) fiilen desteklenmiyor
3. bölüm sırası ve tam yerleşim garantilenmiyor
4. karmaşık senaryolarda veri kaybı riski devam ediyor

## 4.2 Yüksek Öncelikli Problemler

### Yüksek 1: Locale ve Kullanıcı Tercihleri Tam Entegre Değil

Klavye, locale ve benzeri kullanıcı tercihleri için yapı mevcut olsa da bütün seçimler kurulum profiline ve gerçek sistem yapılandırmasına tam bağlanmış değildir.

Özellikle locale tarafı hâlâ sabit yazıldığı için bu alan tamamlanmış sayılmaz.

### Yüksek 2: Bootloader İçeriğinin Semantik Doğrulaması Hâlâ Sınırlı

Paket ve dosya varlığı artık doğrulanıyor. Ancak şu alanlar hâlâ daha derin kontrole ihtiyaç duyuyor:

1. BLS girdilerindeki UUID içeriği doğru mu
2. EFI tarafında üretilen dosyalar gerçekten beklenen Fedora açılış zincirine mi işaret ediyor
3. grub ve BLS içeriği gerçek reboot olmadan ne kadar güvenilir doğrulanabiliyor

### Yüksek 3: `InstallProfile` Var Ama Ana Akışta Tam Kullanılmıyor

Model eklenmiş olsa da GUI ana akışı hâlâ ham `Map<String, dynamic>` ile kurulum başlatıyor.

Bu da tip güvenliğini (type safety, yanlış tip/anahtar kullanımını derlemede yakalama kabiliyeti) tam devreye sokmuyor.

### Yüksek 4: C++ Backend Hâlâ Kararsız Durumda

`linux/backend/installer_core.cpp` yapısı hâlâ projede mevcut. Ama aktif kullanım stratejisi net değil.

Bu kod:

1. ya net biçimde kullanılmalı
2. ya deneysel alana taşınmalı
3. ya da projeden çıkarılmalı

## 4.3 Orta Öncelikli Problemler

### Orta 1: `flutter analyze` Çıktısı Temiz Değil

Yaklaşık 130 issue doğrudan boot zincirini bozmasa da uzun vadede bakım zorluğu yaratır.

### Orta 2: QEMU Test Betiği Tam Otomatik Değil

Sanal makine betiği var, fakat hâlâ içeride manuel terminal açıp kurulum başlatma adımlarına dayanıyor.

Bu, “gerçek donanımdan kurtulma” hedefinin ancak yarısına ulaşıldığını gösterir.

### Orta 3: Disk ve Bölüm Algılama Hâlâ Basit Hesaplara Dayanıyor

Boş alan hesabı hâlâ büyük ölçüde:

`toplam disk - toplam bölüm boyutu`

mantığına dayanıyor. Bu gerçek disk geometrisinde her zaman doğru değildir.

## 5. Bu Planın Öncelik Felsefesi

Bu planda değişmeyen ana ilke şudur:

1. Önce test
2. Sonra boot zinciri
3. Sonra kurulum motoru doğruluğu
4. Sonra güvenlik ve mimari temizlik
5. En son arayüz cilası ve dokümantasyon

Belgeler yine en son iş olacaktır.

## 6. Hedef Durum

Bu plan tamamlandığında şu tabloya ulaşmak istiyoruz:

1. `flutter test` yeşil olacak.
   Bu eşik aşıldı; şimdi bunu korumak gerekiyor.
2. `flutter analyze` en azından warnings-only seviyesine indirilecek, kritik kalite sorunları temizlenecek.
3. Tam disk kurulumu sanal makinede otomatik çalışacak.
4. Kurulum sonrası sistem otomatik reboot testinden geçecek.
5. BTRFS ve EXT4 için boot zinciri doğrulanmış olacak.
6. Manual partition ya gerçekten güvenilir olacak ya da release dışında bırakılacak.
7. `alongside` ya gerçek anlamda düzeltilecek ya da geçici olarak devre dışı bırakılacak.

## 7. Aşamalandırılmış Güncel Plan

## Aşama 0: Zemin Sağlamlaştırma

### Durum

Kısmen tamamlandı.

### Amaç

Geliştirme ortamını ve temel kontrol komutlarını standart hale getirmek.

### Yapılacaklar

1. Proje içinde geliştirici komutları için tek giriş noktası belirleyin.
2. `flutter`, `dart` yollarını kapsayan küçük bir yardımcı betik ekleyin.
3. `clang++` ve Linux toolchain görünürlüğünü kalıcı olarak standart hale getirin.
4. Aşağıdaki komutlar tek komutla çalıştırılabilir hale gelsin:

- analyze
- test
- hızlı smoke test (küçük doğrulama testi)
- VM test

### Çıktı

Bir geliştirici şu komutları ezberlemek zorunda kalmamalı:

- `$HOME/development/flutter/bin/flutter ...`

Bunun yerine proje içi bir komut seti olmalı.

### Kabul Kriteri

Yeni biri projeye girdiğinde 5 dakika içinde analiz ve test çalıştırabilmeli.

## Aşama 1: Test Tabanını Yeşile Çek

### Durum

Tamamlandı.

### Amaç

Önce mevcut kırık testleri düzeltmek ve test altyapısını güvenilir referans haline getirmek.

### Yapılacaklar

1. `PartitioningStage` manual testlerini güncel davranışa göre düzeltin.
2. Hangi davranışın doğru olduğuna karar verin:
   - Kod mu doğru?
   - Test mi doğru?
3. Eğer manual partition akışı hatalıysa önce kodu düzeltin, sonra testi düzeltin.
4. Test dosyalarındaki gereksiz importları temizleyin.
5. Testlerin hepsi tek komutta yeşil duruma getirilsin.

### Özellikle Ele Alınacak Dosyalar

- `test/services/install_stages/partitioning_stage_test.dart`
- `test/services/install_stages/partitioning_manual_test.dart`
- `lib/services/install_stages/partitioning_stage.dart`

### Kabul Kriteri

`flutter test` sıfır kırık test ile tamamlanmalı.

## Aşama 2: Boot Zincirini Doğrula ve Sertleştir

### Durum

Kısmen tamamlandı.

### Amaç

Kurulum sonrası sistemin gerçekten açılmasını garanti altına almak.

### Yapılacaklar

1. Boot zincirini iki profile ayırıp test edin:
   - EXT4 root
   - BTRFS root
2. BTRFS için `/etc/kernel/cmdline` içinde `rootflags=subvol=@` gerekip gerekmediğini doğrulayın.
3. `/boot/loader/entries/*.conf` dosyalarının içeriğini kurulum sonunda otomatik denetleyin.
4. Eski live BLS kayıtlarını temizleyin.
5. `grub2-install`, `kernel-install`, `dracut`, `grub2-mkconfig` sonrasında hedef sistemde aşağıdakileri doğrulayın:

- `/boot/loader/entries/` dolu mu
- kernel ve initramfs var mı
- UUID doğru mu
- live parametreleri kaldı mı
- EFI yolu doğru mu

6. Başarılı kurulum sonrasında bir `PostInstallValidationStage` ekleyin.
   Bu madde tamamlandı, şimdi bu aşamanın VM reboot testiyle desteklenmesi gerekiyor.

### Bu Aşamada Eklenecek Kontroller

1. `grep -R "rd.live.image\|inst.stage2\|CDLABEL" /mnt/boot /mnt/etc/kernel/cmdline`
2. `test -f /mnt/etc/kernel/cmdline`
3. `ls /mnt/boot/loader/entries/*.conf`
4. `kernel-core` veya `ro-kernel-*-core` alternatifi ile `dracut grub2-efi-x64 shim-x64` paket doğrulaması
5. `findmnt --verify --tab-file /mnt/etc/fstab`

### Kabul Kriteri

Tam disk kurulum senaryosu sanal makinede üç kez üst üste açılmalı.

## Aşama 3: Live ISO Kalıntılarını Temizle

### Durum

Kısmen tamamlandı.

### Amaç

Canlı sistemden hedefe yanlış boot bilgisi taşınmasını engellemek.

### Yapılacaklar

1. `rsync` dışlama listesine boot ile ilgili taşınmaması gereken dosyaları ekleyin.
   Bu madde büyük ölçüde tamamlandı; kalan iş reboot sonrası davranışı kanıtlamaktır.
2. Özellikle aşağıdakileri değerlendirin:

- `/boot/loader/entries/*`
- `/etc/kernel/cmdline`
- `/boot/grub2/grubenv`
- live ortamdan gelen EFI giriş kırıntıları

3. Kopyalama sonrası gerekli dosyaları hedef sisteme özel yeniden üretin.

### Kabul Kriteri

Kurulum sonrası hedef sistemde live ISO’ya ait kernel parametresi kalmamalı.

## Aşama 4: Chroot ve Kullanıcı Yönetimini Sertleştir

### Durum

Kısmen tamamlandı.

### Amaç

Kurulumun başarı dediği yerde gerçekten geçerli bir kullanıcı ve geçerli bir sistem oluşmasını sağlamak.

### Yapılacaklar

1. `useradd`, `chpasswd`, `passwd -l root`, locale, timezone ve fstab üretimi gibi kritik adımların tümünde dönüş kodunu sert kontrol edin.
   Bu madde büyük ölçüde tamamlandı.
2. `wheel` grubu kullanımı ile `isAdministrator` mantığını netleştirin.
   Bu madde büyük ölçüde tamamlandı.
3. Yönetici olmayan kullanıcı gerçekten yönetici olmamalı.
   Bu madde tamamlandı.
4. Parola akışını loglara sızmayacak biçimde gözden geçirin.
   Shell quote güvenliği iyileştirildi; log sızıntısı ayrıca denetlenmeli.
5. Locale değerini kullanıcı seçimiyle uyumlu hale getirin.
   Bu madde açık kalmaktadır.

### Kabul Kriteri

Kurulum sonrası:

1. kullanıcı gerçekten vardır
2. home dizini vardır
3. root kilitlidir veya net tanımlanmış politika ile yönetilir
4. seçilen yönetici rolü sistemde gerçek davranış olarak karşılık bulur

## Aşama 5: `InstallProfile` Geçişini Tamamla

### Amaç

Kurulum motorunu ham `Map<String, dynamic>` kullanımından çıkarmak.

### Yapılacaklar

1. `InstallingScreen` içindeki `stateMap` üretimini `InstallProfile` ile değiştirin.
2. `InstallService.runInstall()` imzasını profille çalışacak şekilde evrimleştirin.
3. Gerekirse geçiş dönemi için adapter (uyarlayıcı) katmanı kullanın.
4. JSON profilden kurulum başlatan küçük bir CLI veya test sürücüsü ekleyin.

### Neden Gerekli

Bu adım olmadan:

1. tip güvenliği eksik kalır
2. otomatik kurulum senaryosu zorlaşır
3. GUI ile test senaryosu tam birleşmez

### Kabul Kriteri

Aynı kurulum senaryosu hem GUI’den hem JSON profilden tetiklenebilmeli.

## Aşama 6: `alongside` Özelliği İçin Net Karar Ver

### Amaç

Kullanıcıya vaat edilen davranış ile gerçek davranışın birebir örtüşmesini sağlamak.

### Seçenekler

1. Gerçek küçültme ve yeniden yerleşim desteği eklemek
2. Özelliği geçici olarak kapatmak
3. Deneysel olarak işaretlemek ve release dışında bırakmak

### Şu Anda Doğru Yaklaşım

Eğer yakın vadede güvenilir küçültme desteği gelmeyecekse:

**`alongside` release için devre dışı bırakılmalı veya açıkça deneysel ilan edilmelidir.**

### Kabul Kriteri

Bu özellik release’te varsa gerçekten çalışan senaryolarla test edilmiş olmalı.

## Aşama 7: Manual Partition İçin Ürün Kararı Ver

### Amaç

Manual partition özelliğini ya güvenilir hale getirmek ya da geçici olarak sınırlandırmak.

### Yapılacaklar

1. Desteklenen senaryoları yazılı olarak daraltın.
2. Gerçekte desteklenmeyen resize işlemini UI’dan veya release’ten kaldırın.
3. Bölüm yerleşim mantığını netleştirin.
4. Gerçek boş alan modeli gerekiyorsa `parted -m` veya benzeri daha sağlam veri kaynağı kullanın.
5. Karmaşık disk topolojileri için test fixture ekleyin.

### Ürün Kararı

Manual partition, güvenilir değilse release’te “advanced experimental” seviyesine çekilmelidir.

### Kabul Kriteri

Manual partition destekleniyorsa:

1. yeni bölüm oluşturma
2. silme
3. mount atama
4. formatlama
5. boot sonrası açılış

senaryoları testten geçmelidir.

## Aşama 8: Sanal Test Laboratuvarını Tam Otomatik Hale Getir

### Amaç

Gerçek donanıma bağımlılığı ciddi biçimde azaltmak.

### Şu Andaki Durum

QEMU betiği var ama içeride elle terminal açıp komut girilmesini istiyor.

### Hedef Durum

Test akışı şu şekilde olmalı:

1. disk oluştur
2. VM başlat
3. installer otomatik çalışsın
4. kurulum profili otomatik uygulansın
5. VM reboot etsin
6. açılış sonucu otomatik raporlansın
7. artefaktlar host sisteme taşınsın

### Yapılacaklar

1. QEMU betiğini iki moda ayırın:
   - interaktif mod
   - tam otomatik mod
2. seri konsol log kaydı ekleyin.
3. QCOW2 overlay kullanın.
4. başarısız boot sonrasında disk içeriğini hosttan inceleyen yardımcı betik yazın.
5. VM test profillerini JSON tabanlı hale getirin.

### Kabul Kriteri

Geliştirici gerçek bilgisayara çıkmadan:

1. kurulum yapabilmeli
2. reboot edebilmeli
3. boot sonucunu alabilmeli
4. hata artefaktlarını inceleyebilmeli

## Aşama 9: CI ve Kalite Kapısı

### Amaç

Projeyi kişisel doğrulama düzeyinden çıkarıp otomatik kalite kapısına bağlamak.

### Yapılacaklar

1. CI hattı kurun.
2. En az şu adımlar çalışsın:
   - `flutter analyze`
   - `flutter test`
3. Daha sonra uygun ortam bulunursa hızlı VM smoke test ekleyin.

### Yayın Kapısı

Bir sürüm release adayı olmadan önce:

1. analyze kabul edilebilir seviyede olmalı
2. testler tamamen yeşil olmalı
3. otomatik boot testi geçmeli

## Aşama 10: Kod Temizliği ve UI Teknik Borcu

### Amaç

Boot ve test tarafı sağlama alındıktan sonra kod kalitesini toparlamak.

### Yapılacaklar

1. `withOpacity` uyarılarını yeni API’ye taşıyın.
2. gereksiz importları temizleyin.
3. deprecated widget alanlarını güncelleyin.
4. `InstallerState` parçalanmalı mı değerlendirin.
5. versiyon bilgisini tek kaynaktan üretin.

### Not

Bu aşama önemlidir ama boot ve test çözülmeden birinci öncelik değildir.

## Aşama 11: Dökümantasyon

### Amaç

Bu planın bilerek en sona bıraktığı iş budur.

### Ancak Ne Zaman?

Yalnızca şu koşullar sağlandıktan sonra:

1. testler yeşil
2. boot zinciri doğru
3. VM laboratuvarı çalışıyor
4. release davranışı net

### O Zaman Yapılacaklar

1. `README.md` güncellenecek
2. test çalışma rehberi yazılacak
3. release süreci yazılacak
4. sorun giderme rehberi hazırlanacak

## 8. İlk Çalışma Bloku: Sıradaki Uygulanacak Sıra

Bu bölüm, tamamlanan ilk dalgadan sonra şimdi doğrudan uygulanacak iş listesidir.

### Adım 1

VM içinde tam otomatik kurulum + reboot + boot sonucu alma hattını kur.

### Adım 2

`PostInstallValidationStage` ve boot zinciri tarafında semantik içerik doğrulamasını derinleştir:

1. BLS içeriğinde UUID ve parametre denetimi
2. EFI çıktılarında beklenen Fedora zinciri denetimi
3. mümkün olan yerde reboot öncesi içerik parse testi

### Adım 3

Kurulum sonrası otomatik doğrulama hattını VM testine bağla:

1. BTRFS root
2. EXT4 root
3. EFI girdileri
4. BLS içeriği

### Adım 4

`InstallProfile` geçişini başlat ve GUI dışından profil tabanlı kurulum sürücüsü ekle.

### Adım 5

`alongside` için release kararı ver:

1. gerçekten düzelt
2. deneysel ilan et
3. geçici olarak kapat

### Adım 6

Manual partition için desteklenen senaryoları daralt ve release sınırını netleştir.

### Adım 7

QEMU/VM betiğini seri konsol loglu tam otomatik moda geçir.

## 9. Bu Planın Başarı Ölçütü

Bu belge başarılı olmuş sayılacaktır eğer:

1. geliştirme gerçek donanım bağımlılığından büyük ölçüde çıkarsa
2. `flutter test` tamamen yeşil olursa
3. Fedora 43 tabanlı tam kurulum sanal makinede açılırsa
4. BTRFS ve EXT4 boot senaryoları doğrulanırsa
5. `alongside` ve manual partition için ya güvenilir çözüm ya net ürün kararı verilirse
6. proje “kurulum bitiyor ama sistem açılmıyor” sınıfı belirsizlikten çıkarsa

## 10. Son Hüküm

Projede ilerleme vardır, fakat ana sorunlar çözülmüş değildir. En kritik gerçek şudur:

**Test tabanı artık yeşildir; fakat projenin ana riski artık boot zincirinin gerçek reboot senaryosunda otomatik kanıtlanmıyor oluşudur.**

Bundan sonraki çalışma sırası bozulmamalıdır:

1. Otomatik VM laboratuvarını tamamla
2. Boot zincirini reboot ile kanıtla
3. Kalan kritik stage’leri fail-fast hale getir
4. `alongside` ve manual partition için net karar ver
5. `InstallProfile` geçişini tamamla
6. En son UI temizliği ve belgeye geç

Bu sıra korunursa proje gerçekten toparlanır. Sıra bozulursa tekrar yavaş ve belirsiz döngüye dönülür.
