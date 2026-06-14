# Ro-Installer Profesyonel Installer Ana Plani

Tarih: 2026-05-28
Amac: Bu dosya, oturum gecmisi sifirlansa bile Ro-Installer icin neyi hedefledigimizi, projenin bugunku durumunu, guclu/zayif taraflari ve gelistirme planini hatirlatmak icin tutulur.

## Urun Niyeti

Ro-Installer genel amacli bir Anaconda veya Calamares kopyasi olmayacak. Hedef, Ro-ASD Linux Desktop icin son kullaniciya kolay, sade ve guvenilir bir kurulum deneyimi vermek.

Temel kararlar:

- Basit kurulumda kullaniciya gereksiz teknik secimler sorulmayacak.
- Gelismis kurulum, gercekten ihtiyac duyan kullaniciya daha fazla kontrol verecek.
- Btrfs, UEFI, GPT, Fedora/Ro-ASD ve x86_64 hedefi birinci sinif akistir.
- LUKS, LVM, RAID, rescue, netinstall, BIOS boot gibi alanlar onemlidir; ama basit kurulumun onune konulmayacak, gelismis/lab akisi olarak planlanacak.
- Guvenlik ve veri kaybi riski olan backend hatalari "sadelik" gerekcesiyle ertelenmeyecek.

## Projenin Bugunku Yapisi

Kod tabani Flutter/Dart uzerinde:

- UI ekranlari: `lib/screens/`
- Kurulum durumu: `lib/state/installer_state.dart`
- Kurulum orkestrasyonu: `lib/services/install_service.dart`
- Kurulum asamalari: `lib/services/install_stages/`
- Komut calistirma katmani: `lib/services/command_runner.dart`
- Test runner: `lib/services/fake_command_runner.dart`
- Oturum log export: `lib/services/install_log_export_service.dart`
- Otomatik profil modeli: `lib/models/install_profile.dart`
- Dil dosyalari: `assets/i18n/`
- Testler: `test/`

Kurulum motoru asamalara bolunmus durumda:

1. Disk hazirligi
2. Bolumleme
3. Bicimlendirme
4. Mount
5. Dosya kopyalama
6. Chroot sistem ayarlari
7. Bootloader
8. Kurulum sonrasi dogrulama
9. Temizlik

Bu stage yapisi iyi bir temel. Profesyonel installer seviyesine cikmak icin en kritik eksik, disk/storage tarafinda daha deklaratif, dogrulanabilir ve geri alinabilir bir model.

## Anaconda ve Calamares Kiyaslamasi

Guclu taraflar:

- Ro-ASD hedefine odakli oldugu icin genel amacli installer karmasasina dusmuyor.
- UI akisi son kullanici icin sade tutulmus.
- Stage mimarisi okunabilir ve test edilebilir.
- Btrfs/Fedora/Ro-ASD hedefi net.
- Otomatik profil modu, ileride Kickstart benzeri Ro-ASD kurulum profiline evrilebilir.
- QEMU ve stage testleri icin altyapi baslamis durumda.

Zayif taraflar:

- Storage backend henuz Anaconda/Blivet veya Calamares/KPMCore olgunlugunda degil.
- Disk islemleri halen buyuk oranda komut dizisi seviyesinde.
- Tam transaction, iptal edilebilir job, cihaz kilidi ve hata sonrasi kurtarma modeli eksik.
- LUKS, LVM, RAID, multipath, iSCSI, BIOS boot, ARM, netinstall, rescue/headless/text installer kapsami yok veya cok sinirli.
- Tedarik zinciri ve live ISO yetki politikalari sikilastirilmali.
- C++ backend varligi belirsiz; kullanilmiyorsa kaldirilmali, kullaniliyorsa guvenlik ve test kapsamina alinmali.

## Kritik Guvenlik Kararlari

### Parola ve secret loglari

Hedef: Kullanici parolasi, Wi-Fi parolasi, token, passphrase gibi secret degerler hicbir GUI teknik logunda, export logunda, otomatik kurulum logunda veya komut goruntuleme satirinda acik gorunmeyecek.

Ilk uygulama diliminde yapilanlar:

- `CommandRunner` icine merkezi `SecretRedactor` eklendi.
- Komut display loglari maskelemeden geciyor.
- stdout/stderr callback loglari maskelemeden geciyor.
- `InstallService` sure ve hata loglarinda redacted komut satiri kullaniyor.
- `InstallLogExportService` merkezi redactor kullaniyor ve context icinde password/passphrase/secret/token alanlarini cikartiyor.
- Auto install log sanitizer merkezi redactor'a baglandi.
- `chpasswd` artik `user:password` bilgisini shell argumani olarak almiyor; stdin ile veriyor.

### Varsayilan hesap

Hedef: Uretim installer acildiginda `roasd / 1234` gibi hazir hesap veya parola gelmeyecek.

Ilk uygulama diliminde yapilanlar:

- `InstallerState` icindeki full name, username ve password varsayilanlari bosaltildi.
- Hesap ekrani zayif parola tespit ederse kurulumdan once acik onay istiyor.
- Bos/4 karakter alti parola hala bloke ediliyor.
- `1234` gibi zayif parolalar kullanici israr ederse kabul edilebiliyor; bu basitlik hedefiyle uyumlu ama risk kullaniciya gosteriliyor.

### Tedarik zinciri

Hedef:

- Ro repo tarafinda `gpgcheck=0` kalici uretim davranisi olmamali.
- Paketler imzali repo metadatasi ve imzali RPM ile dogrulanmali.
- ISO build icinde gecici NOPASSWD politikasi sadece live installer ihtiyaci kadar daraltilmali.

Plan:

- Ro `.repo` dosyalari `gpgcheck=1`, `repo_gpgcheck=1` ve `RPM-GPG-KEY-ro-asd` ile guncellendi.
- COPR depolari RPM imzasi (`gpgcheck=1`) ile kaliyor; COPR metadata imzasi yayinlanmadigi icin `repo_gpgcheck=0` istisnasi belgelendi.
- Live ISO `NOPASSWD: ALL` kullanmiyor; otomatik baslatma installer launcher + liveuser ile sinirli polkit kuralina tasindi.
- Hala gereken dis is: 2026-06-15 kontrolunde Ro-Repo tarafinda `RPM-GPG-KEY-ro-asd` ve imzali `repodata/repomd.xml.asc` dosyalari 404 donuyor; bunlar yayinlanmali.

## Storage Plani

### V1 Stabil Storage

Kapsam:

- x86_64
- UEFI
- GPT
- Btrfs
- Full disk
- Alongside
- Free-space
- Manual partition

Yapilacaklar:

- Disk islemlerinde shell wildcard ve kacsisiz string kullanimi kaldirilacak.
- Her disk islemi oncesi hedef cihaz dogrulanacak.
- Mount, swap, LUKS/LVM olmasa bile mevcut kullanim algisi guclendirilecek.
- Disk degisikliklerinden once plan ekrani kullaniciya net gosterilecek.
- Partition plan once model olarak hesaplanacak, sonra uygulanacak.
- Uygulama sonrasi `lsblk`, `blkid`, `findmnt`, `efibootmgr` ile dogrulama yapilacak.
- GPT backup sadece alongside/manual/free-space ile sinirli kalmayacak; riskli degisikliklerde standart hale getirilecek.

### V2 Gelismis Storage Lab

Kapsam:

- LUKS once gelmeli.
- LVM, LUKS uzerinde opsiyonel gelmeli.
- RAID ve diger enterprise konular lab/ileri seviye olarak kalmali.

UI ilkesi:

- Basit kurulumda LUKS/LVM sorulmayacak.
- Gelismis kurulumda "Disk sifreleme" ana secenek olarak sunulacak.
- LVM, ancak teknik kullanici icin "gelismis depolama" altinda sunulacak.

Karar:

- Stable surume LUKS/LVM koymak icin once storage motoru deklaratif ve testli hale gelmeli.

## Rollback ve Kurtarma Plani

Profesyonel installer icin hedef:

- Her stage uygulamadan once ne yapacagini modellemeli.
- Basarili adimlar journal'a yazilmali.
- Iptal veya hata durumunda temizlik sirasi bilinmeli.
- Mount/swap/loop cihazlari guvenli kapatilmali.
- Veri kaybi yaratabilecek rollback iddialari abartilmamali.

V1 hedefi:

- "Tam geri alma" iddiasi yerine "guvenli durdurma ve temizleme" hedefi.
- Mount/swap cleanup daha deterministik hale getirilecek.
- Stage hata raporu hangi cihazlara dokunuldugunu gosterecek.

V2 hedefi:

- Transaction benzeri plan/apply/verify/rollback modeli.
- Cihaz kilidi.
- Iptal edilebilir job queue.
- Hata sonrasi kurtarma raporu.

## UI/UX Plani

Basit kurulum:

- Dil, tema, konum, ag, hesap, kurulum tipi, disk, kurulum.
- Teknik secimler minimumda kalacak.
- Kullaniciya "neyi silecegiz, nereye kuracagiz" net anlatilacak.

Gelismis kurulum:

- Manuel/free-space/alongside daha iyi aciklanacak.
- Kernel secimi gelismis akista kalacak.
- Gelecekte LUKS ve LVM burada sorulacak.

Eksik UI alanlari:

- Disk plan onizleme ekrani daha net olmali.
- Riskli islem onayi tek tek daha acik olmali.
- Zayif parola uyarisi eklendi.
- Kurulum sonrasi rapor ve hata raporu daha okunur hale getirilmeli.

## Otomatik Profil Plani

Mevcut JSON profil iyi baslangic. Hedef, Ro-ASD icin Kickstart alternatifi gibi calismasi.

Yapilacaklar:

- Profil schema versiyonu.
- Strict validation.
- Secret alanlari icin log maskeleme.
- Ornek profil dosyalari.
- QEMU otomatik testte profil kullanimi.
- Hata mesajlari makine tarafindan okunabilir kodlarla donmeli.

## Test ve Kalite Kapilari

Stable kabul kapilari:

- `flutter analyze` temiz.
- `flutter test` yesil.
- i18n key setleri eslesiyor.
- Secret scan: loglarda parola/token yok.
- QEMU full disk kurulum ve boot testi.
- QEMU alongside/free-space testi.
- ISO build smoke testi.
- Repo GPG audit.
- Live sudo/polkit audit.

Eklenmesi gereken testler:

- Parola komut argumaninda gorunmuyor testi.
- Log export secret redaction testi.
- Disk komutlari shell wildcard kullanmiyor testi.
- Manual partition model/apply tutarlilik testi.
- Bootloader EFI dogrulama testi.
- Hata sonrasi cleanup testi.

## Onceliklendirilmis Yol Haritasi

### Faz 0: Hafiza ve guvenlik temeli

Durum: Bu oturumda baslandi.

- Bu dokuman olusturuldu.
- Varsayilan `roasd / 1234` kaldirildi.
- Zayif parola onayi eklendi.
- Secret redaction merkezi hale getirildi.
- `chpasswd` parolasi komut argumanindan stdin'e tasindi.

### Faz 1: Log ve tedarik zinciri sertlestirme

- Export log testleri genisletilecek.
- Repo GPG plani uygulanacak.
- ISO live yetki politikasi daraltilacak.
- Teknik loglarda kalan olasi secret pattern'leri taranacak.

### Faz 2: Storage motoru sertlestirme

- Disk islemleri plan/apply/verify seklinde ayrilacak.
- Shell wildcard kullanimi kaldirilacak.
- Hedef disk ve partition path dogrulama katmani yazilacak.
- GPT backup/restore akisi genellestirilecek.
- Hata sonrasi cleanup guclendirilecek.

### Faz 3: Gelismis kurulum yetenekleri

- LUKS tasarimi ve UI.
- LVM tasarimi ve UI.
- Bu ozellikler once lab flag ile gelecek.
- Stable'a cikmadan QEMU matrisi zorunlu olacak.

### Faz 4: Profesyonel dogrulama ve dagitim

- QEMU otomasyon matrisi.
- ISO build pipeline.
- Paket imzalama.
- Kurulum sonrasi artifact raporu.
- Kullaniciya verilecek hata raporu formatlari.

## Acik Kararlar

- LUKS varsayilan onerilecek mi, yoksa sadece gelismis kurulumda mi kalacak?
- LVM hic stable'a girecek mi, yoksa sadece teknik/lab profilinde mi kalacak?
- BIOS boot desteklenecek mi, yoksa proje UEFI-only kalacak mi?
- Netinstall hedeflenecek mi?
- C++ backend kaldirilacak mi, yoksa storage icin kullanilacak mi?

Mevcut urun yonu acisindan onerilen cevaplar:

- LUKS: Gelismis kurulumda opsiyonel.
- LVM: LUKS sonrasi, lab/ileri seviye.
- BIOS boot: Simdilik kapsam disi.
- Netinstall: Simdilik kapsam disi.
- C++ backend: Kullanilmiyorsa kaldir; kullanilacaksa test ve guvenlik kapsaminda sahiplen.
