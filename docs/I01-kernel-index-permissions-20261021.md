# I01 — Kernel modül indeks izinleri

Tarih: 21 Ekim 2026 (Europe/Istanbul). Çalışma: G14 yerel checkout.

## Başlangıç

- Checkout: `/home/smurat/Ro-ASD/ro-Installer`.
- Branch: `release/prepare-2.4.5`.
- HEAD: `57c9e179f68006e162fe8cfddccf08c59f1e2e8a` — Prepare Ro-Installer 2.4.5 and preserve Fedora release evidence.
- Başlangıçta tracked/untracked kullanıcı değişikliği yoktu. Checkout ve üst dizinlerde uygulanabilir AGENTS.md bulunmadı.
- Ro-ASD üst dizini bir Git deposu değil; tüm kaynak değişiklikleri ro-Installer içinde.

## Kök neden değerlendirmesi

**GÜÇLÜ OLASI:** Integration-0002 fiziksel ISO'sunda gözlenen root:root 0600 indekslerin kesin üretici aşaması henüz kanıtlanmadı.

**KANITLANDI (yerel mekanizma):** Mevcut helper `main()` içinde `os.umask(0o077)` uyguluyor. `run_backend()` Popen çağrısı maskeyi değiştirmiyor. Dart RealCommandRunner da Process.start ile bu maskeyi miras bırakıyor. Bootloader scriptleri hedefte kernel-install çağırıyor. systemd'nin 50-depmod.install eklentisi depmod çalıştırabiliyor. G14'te gerçek kmod 34.2 / depmod ile geçici modül ağacında 0077 altında üretilen indeksler 0600 oldu; yalnızca depmod alt süreci 0022 olduğunda aynı indeksler 0644 olarak yeniden üretildi.

Kaynaklar: mevcut `linux/ro-installer-helper`, `lib/services/command_runner.dart`, `lib/services/install_stages/bootloader_stage.dart`; yerel `/usr/lib/kernel/install.d/50-depmod.install`; [systemd kernel-install belgesi](https://www.freedesktop.org/software/systemd/man/latest/kernel-install.html). Yerel eklenti ve kmod sürümü fiziksel ISO'nun eklenti/sürüm envanterinin kanıtı değildir.

## Düzeltme ve diff özeti

`lib/services/install_stages/bootloader_stage.dart`: 6 satır eklendi. Her tam hazırlanmış kernel adayı için:

1. Dracut öncesinde `(umask 022; exec depmod -a "$kver")` çalışır.
2. Kernel-install başarıyla döndükten sonra aynı komut tekrar çalışır.

İlk adım, Live/Compose'dan kopyalanmış 0600 depmod çıktılarını dracut öncesinde yeniden üretir. İkinci adım, kernel-install eklentisinin miras aldığı 0077 ile indeksleri tekrar daraltması durumunda hedefteki nihai izinleri düzeltir. `-a` kullanılır; `-A` ile mevcut indekslerin yeniden üretimi atlanmaz. Sürüm tırnaklı argüman olarak verilir; mevcut ortak kernel keşfi, sıralama ve merged-/usr tekilleştirmesi korunur.

Shell `set -e` davranışı korunur. Depmod yoksa veya başarısızsa script hata verir; mevcut BootloaderStage `_requireCommand` akışı başarısız kurulum aşaması döndürür, sonraki boot/firmware adımlarına geçmez.

`test/services/install_stages/bootloader_stage_test.dart`: 6 satır eklendi. Eski keşif/sıralama fixture'ına başarılı sahte depmod eklendi; bu testlerin gerçek host depmod'a ulaşması engellendi. Gerçek izin davranışı ayrı regresyon testindedir.

`test/services/install_stages/kernel_index_permissions_test.dart`: yeni 4 regresyon testi. `docs/I01-kernel-index-permissions-20261021.md`: bu rapor.

## Regresyon kapsamı

- Gerçek sh alt süreçleri 0077 parent maskesiyle başlatılır. Üretimdeki Dart script sabitleri import edilir; yalnızca hedef yolları geçici dizine yönlendirilir.
- Gerçek depmod yalnızca `-b <geçici kök>` ile çalışır. Önce gerçek 0600 çıktı üretilerek hata yeniden oluşturulur, sonra aynı dosyaların yeniden üretimle 0644 olduğu kontrol edilir.
- `modules.alias`, `modules.alias.bin`, `modules.dep`, `modules.dep.bin`, `modules.symbols`, `modules.symbols.bin`, `modules.softdep`, `modules.devname`, `modules.builtin.bin`, `modules.builtin.alias.bin` doğrulanır. Varsa `modules.weakdep` de diğer kullanıcı okuma biti açısından kontrol edilir.
- Dosyalar ayrıcalıksız test kullanıcısıyla gerçekten okunur ve diğer kullanıcılar için okuma biti denetlenir. Fixture dosyalarının sahibi test kullanıcısıdır; root sahipliği veya başka UID'ye geçiş taklit edilmez. Gerçek kurulumda depmod root olarak çalışacaktır.
- İki kernel sürümü ve merged-/usr ağacı gerçek depmod ile sınanır; mevcut testler bağımsız /lib, farklı kernel adları ve eksik adayların atlanmasını kapsar.
- Kernel-install ve dracut kontrollü fixture programlarıdır. Kernel-install fixture'ı eklenti davranışını gerçek depmod'u 0077 ile çalıştırarak modeller ve indeksin yeniden 0600 olduğunu kontrol eder. Sonraki üretim adımının 0644'e dönüştürmesi doğrulanır.
- Parent/sonraki süreç, dracut ve eklenti özel dosyaları/kilitler 0600; özel dizin 0700 kalır. İz kaydı depmod için 0022, eklenti için 0077 gösterir.
- Gerçek `modprobe -d <geçici kök> -S <sürüm> -R i01:test`, iki kernel için builtin alias indeksinden `i01` sonucunu verir. `-R` yalnızca sorgular, modül yüklemez.
- Dracut öncesindeki ve kernel-install sonrasındaki depmod hataları 23 koduyla dışarı taşınır ve ikinci kernel işlenmez. Mevcut BootloaderStage hata testleri script hata kodunun başarısız stage sonucuna dönüşmesini kapsar.
- Depmod/modprobe yoksa ilgili gerçek araç testi açıkça SKIP olur; mock ile başarı üretilmez. Bu ortamda yeni testlerin hiçbiri atlanmadı.

## Test komutları ve sonuçlar

Mevcut SDK: `/home/smurat/development/flutter/bin/cache/dart-sdk/bin/dart`. Flutter başlatıcısı salt okunur SDK önbelleğinde engine stamp yazmaya çalıştığından mevcut `flutter_tools.snapshot` doğrudan çalıştırıldı. Tam suite, SDK kilidi ve yerel UNIX soketleri için sandbox dışında çalıştırıldı; fiziksel disk, modül ağacı veya fiziksel test bilgisayarı kullanılmadı.

```sh
DART=/home/smurat/development/flutter/bin/cache/dart-sdk/bin/dart
"$DART" test test/services/install_stages/kernel_index_permissions_test.dart test/services/install_stages/bootloader_stage_test.dart
"$DART" /home/smurat/development/flutter/bin/cache/flutter_tools.snapshot test --no-pub
"$DART" analyze lib/services/install_stages/bootloader_stage.dart test/services/install_stages/bootloader_stage_test.dart test/services/install_stages/kernel_index_permissions_test.dart
PATH=/home/smurat/development/flutter/bin/cache/dart-sdk/bin:$PATH python3 -m unittest discover -s test/scripts -p '*_test.py'
git diff --check
```

- Hedefli Dart testleri: **34 PASS** (4 yeni regresyon + 30 mevcut bootloader testi).
- Son tam Flutter suite: **420 PASS / 0 FAIL / 2 SKIP**. Atlanan iki mevcut test, depoya dahil edilmeyen fiziksel sistem log corpus'unu gerektiriyor. Yeni regresyonların tamamı PASS.
- Değişen Dart dosyaları için analyze: **PASS**, issue yok.
- Diff whitespace kontrolü: **PASS**.
- Python suite, Python 3.14: **86 PASS / 1 FAIL / 0 SKIP**, toplam 87. Tek hata: `LoopKernelIdentityTests.test_kernel_device_encoding_including_large_minor_and_readonly_ioctl`; `os.close` mock'u beklenen `close(41)` yanında `close(5)` ve `close(8)` görüyor. Tam suite tekrarında ve Git HEAD'den /tmp içine çıkarılan değiştirilmemiş kopyada aynı hata oluştu. Tek başına çalışınca PASS. Bu değişikliğin getirdiği regresyon değil; test sırası/GC etkisinin ayrıntılı nedeni bu görevde düzeltilmedi.
- İlk sandbox içi Python denemesi: 87 test, 6 FAIL / 21 ERROR; SDK yazma ve UNIX soketi engelleri ile bir süreç yarışı içeriyordu. Uygun yerel test erişimiyle yapılan koşular yukarıdaki tek mevcut hataya indi. İlk engelli koşu başarı olarak sayılmadı.

## Güvenlik değerlendirmesi ve kalan sınırlar

Helper ve tüm backend için 0077 korunur. 0022 yalnızca açık depmod çağrısının subshell'inde uygulanır. Kernel-install'ın BLS, initramfs, UKI veya yerel üçüncü taraf eklentilerine gevşek maske aktarılmaz. Genel chmod, recursive izin düzeltmesi, kalıcı ortam/mask değişikliği eklenmedi. Gizli verilerin izinleri değiştirilmez.

Bu düzeltme hedefteki tam kernel adaylarının depmod çıktıları içindir. Çalışan Live ortamındaki mevcut 0600 indeksler değiştirilmez. FileCopyStage `rsync -aAX --numeric-ids` ile izin/ACL taşıdığından Live/Compose kaynaklı hatalı indeksler hedefe gelebilir; bu hedef indeksleri yeniden üretilir. Ancak `.ko` dosyaları, `modules.order`, `modules.builtin`, `modules.builtin.modinfo`, üst dizinlerin arama izinleri, ACL/SELinux ve diğer paket dosyalarının hatalı izinleri onarılmaz. Eksik kernel imajı nedeniyle keşfin atladığı modül ağaçları da mevcut davranış gereği işlenmez.

Gerçek Fedora kernel-install/dracut eklenti seti veya gerçek initramfs içeriği bu testlerde çalıştırılmadı. Kernel-install içindeki bir eklenti depmod'dan sonra initramfs'i tekrar oluşturuyorsa ara indeksler 0077 altında olabilir; son depmod yalnızca hedef modül ağacını düzeltir, eklentinin ürettiği initramfs'in içeriği için garanti vermez. İlk açık dracut çağrısı öncesinde indekslerin okunabilir olduğu test edildi. Fiziksel ISO'nun tam eklenti sırası ve initramfs çıktısı ayrıca incelenmelidir.

Fiziksel ISO'da hangi aşamanın ilk 0600 indeksleri ürettiği, Compose/Live ağacında daha önce 0600 olup olmadığı, gerçek RPM/ISO kmod sürümü ve eklentileri **BELİRSİZ**. Kaynak düzeltmesi bu olasılıkları ortadan kaldırdığı iddiasında değildir.

## Karar

**GO — PR incelemesine hazırlık için.** Düzeltme dar kapsamlıdır; gerçek depmod ve modprobe testleri geçer, mevcut testlerde yeni hata gözlenmemiştir. Python suite'in HEAD üzerinde de bulunan tek hatası açıkça belirtilmelidir. Bu karar RPM/ISO/Beta yayını veya fiziksel doğrulama onayı değildir.

Commit, push, PR, merge, RPM release veya ISO üretimi yapılmadı. RTX 3090 fiziksel test bilgisayarına erişilmedi. Ana sistem kernel/modül izinlerine dokunulmadı; dosya modu değişiklikleri yalnızca atılabilir test fixture'larıyla sınırlıydı. İnceleme bekleniyor.
