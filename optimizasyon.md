# ro-Installer Optimizasyon Takip Dosyasi

Bu dosya ro-Installer icin uzun sureli optimizasyon ve kalite calismasinin ana
hafiza dosyasidir. Yeni oturumlarda once bu dosya okunacak, isaretli maddeler
kontrol edilecek ve kalan islerden devam edilecek.

## Amac

- [ ] Kurulum suresini stage ve komut bazinda olculebilir hale getirmek.
- [ ] Yanina kur akisini otomatik, kolay ve veri guvenligini one alan hale getirmek.
- [ ] Onceden ayrilmis bos alana hizli dual boot kurulumu eklemek.
- [ ] Manuel bolumleme ile yanina kur arasindaki ortak resize risklerini azaltmak.
- [ ] Intel+NVIDIA yeni nesil cihazlarda live ISO acilis uyumlulugunu artirmak.

## Mevcut Bulgular

- [x] Kurulum motoru stage tabanli: disk hazirligi, bolumleme, format, mount, rsync, chroot, bootloader, validation ve cleanup.
- [x] %8 civarindaki 15-30 dakikalik bekleme buyuk olasilikla rsync degil; NTFS/EXT4/BTRFS shrink ve partition islemleri bu bolumu domine ediyor.
- [x] Manuel bolumleme ve yanina kur ayni resize motorunu kullandigi icin benzer uzun bekleme ve hata davranisini paylasiyor.
- [x] Mevcut `PartitionService` disk geometrisini ve unallocated alanlari sector bazinda uretebiliyor.
- [x] Mevcut `PartitioningStage` `sgdisk` ile sector bazli yeni bolum olusturmaya uygun.

## 2026-05-24 Uygulananlar

- [x] `free_space` kurulum yontemi state, profil, UI ve install stage tarafina eklendi.
- [x] Gelismis kurulumda `Ayrilmis Alana Kur` secenegi eklendi.
- [x] Disk secim ekraninda segmentli disk haritasi ve bos alan secimi eklendi.
- [x] `free_space` modu resize yapmadan secilen bos alanda `RoASD_Swap` + `RoASD_Root` olusturuyor.
- [x] Mevcut EFI bolumu bu modda formatlanmadan kullaniliyor.
- [x] Yanina kur maksimum alan hesabi kaynak bolumde `max(40 GB, %10)` + 10 GB tampon birakacak sekilde sikilastirildi.
- [x] Dogrulama: `flutter analyze` ve `flutter test` gecti.
- [x] Stage ve komut bazli sure/exit-code loglari eklendi.
- [x] `rsync` argumanlari `--info=progress2,stats2`, `--human-readable` ve `--numeric-ids` ile daha olculebilir hale getirildi.
- [x] `rsync` dislama listesine cache/gecici alanlar eklendi.
- [x] Bootloader asamasinda `dracut --regenerate-all` yerine yalnizca Ro kernel surumleri icin initramfs uretimi eklendi.
- [x] Chroot asamasinda dil/experimental paketleri zaten kuruluysa `dnf install` atlanacak hale getirildi.
- [x] Fedora stock kernel temizleme script'i kurulu stock kernel yoksa `dnf remove` calistirmayacak hale getirildi.
- [x] Intel+NVIDIA icin GRUB troubleshooting girdileri eklendi: X11, X11 software render, nouveau GSP kapali ve nouveau kapali.
- [x] ISO audit normal boot/safe graphics/tanı girdisi ayrimini kontrol edecek sekilde guncellendi.
- [x] Live-only SDDM oturum secici ve software render override dosyalari kurulu sistemden temizlenecek hale getirildi.
- [x] ISO kokune live kernel config ve firmware manifestleri eklenip audit tarafindan kontrol edilecek hale getirildi.
- [x] Yanina kur stage seviyesinde UEFI/GPT/EFI ve NTFS guvenlik on kontrolleri eklendi.
- [x] NTFS shrink oncesi `ntfsresize --info --force` zorunlu hale getirildi; hibernation/Fast Startup/dirty/BitLocker durumunda resize baslamadan duruyor.
- [x] Resize basarisizliginda GPT yedegi geri yukleme ve `partprobe/udevadm settle` yeniden tarama akisi guclendirildi.

## 2026-05-27 Uygulananlar

- [x] Standart kurulum akisi gelismis-only `manual` ve `free_space` secimlerini tasimayacak hale getirildi.
- [x] Reboot oncesi root UUID, EFI UUID, BLS kernel/initramfs girdileri ve BLS `root=UUID` dogrulamasi eklendi.
- [x] BTRFS kurulumlarda BLS `rootflags=subvol=@` dogrulamasi eklendi.
- [x] Hibernate resume UUID degeri `/etc/fstab` SWAP UUID'siyle eslesecek sekilde dogrulanir hale getirildi.
- [x] Dogrulama: `flutter analyze` ve `flutter test` gecti.
- [x] Yanina kur NTFS dirty durumunda kullaniciyi Windows'a gondermeden sinirli `ntfsfix -d` onarimi deneyip tekrar `ntfsresize --info --force` dogrulayacak hale getirildi.
- [x] BitLocker ve hibernation/Fast Startup kesin blok olarak korunurken dirty NTFS UI tarafinda uyarili/onarilabilir durum olarak gosterilecek hale getirildi.
- [x] ISO payload kopyalama alternatifi icin kuruluma dokunmayan `scripts/04-benchmark-copy-paths.sh` benchmark araci eklendi.
- [x] Sanal makinesiz dry-run/script entrypoint ve gercek sistem log audit testleri eklendi.

## Oncelik Sirasi

- [x] P0: `Ayrilmis alana kur` akisini ekle ve resize yapmadan bos alan secimiyle kurulum yap.
- [x] P0: Yanina kur progress ve hata raporlamasini komut bazinda gorunur hale getir.
- [x] P0: Gercek cihazda basarisiz kurulum sonrasi yan OS'ye zarar vermeme garantisini guclendir.
- [x] P1: `rsync` kopyalama suresini olc ve dislama listesini temizle.
- [x] P1: `dracut`, `dnf` ve bootloader adimlarini hizlandir.
- [x] P1: Intel+NVIDIA live boot test matrisini ISO'ya ekle.

## Kurulum Secenekleri

- [x] Tam diske kur: basit ve gelismis kurulumda gorunur.
- [x] Yanina kur: mevcut OS bolumunu guvenli sinirlarla otomatik kucultur.
- [x] Ayrilmis alana kur: sadece gelismis kurulumda gorunur; kullanici disk haritasindan bos alani secer.
- [x] Elle bolumle: sadece gelismis kurulumda gorunur.

## Ayrilmis Alana Kur

- [x] `partitionMethod=free_space` state ve install profile tarafina eklenecek.
- [x] Disk secim ekraninda Calamares benzeri segmentli disk haritasi gosterilecek.
- [x] Kullanici yalnizca `unallocated/free space` segmenti secebilecek.
- [x] Secilen bos alan icinde `RoASD_Swap` ve `RoASD_Root` olusturulacak.
- [x] Mevcut EFI uygun ise formatlanmadan kullanilacak.
- [x] UEFI + GPT + mevcut ESP sartlari acik hata ile dogrulanacak.
- [x] Bu akista partition resize yapilmayacak.

## Yanina Kur

- [x] Yanina kur kullaniciyi Windows'a gondermeden otomatik calismali.
- [x] Slider ust siniri kaynak bolumde en az `max(40 GB, %10)` ve ek 10 GB tampon birakacak sekilde hesaplanmali.
- [x] BitLocker, hibernation/fast startup, GPT/UEFI/EFI eksigi ve mount riski preflight'ta durdurulmali; dirty NTFS sinirli onarim sonrasi tekrar dogrulanmali.
- [x] `ntfsresize --info`, gercek resize, `parted resizepart`, `sgdisk` ve `partprobe/udevadm settle` ayri alt asamalar olarak loglanmali.
- [x] Resize basarisiz olursa GPT yedegi geri yuklenmeli ve disk yeniden taranmali.

## Dosya Kopyalama ve Hiz

- [x] `rsync` icin toplam byte, dosya sayisi, sure ve exit code loglanacak.
- [x] `rsync --info=progress2` veya esdeger canli cikti kullanilacak.
- [x] `/var/cache/dnf`, gecici dosyalar, live-only loglar ve installer kalintilari dislama listesine alinacak.
- [x] ISO payload'undan dogrudan kopyalama alternatifi benchmark edilecek.

## Chroot ve Bootloader

- [x] Gereksiz `dnf remove/install` komutlari paket varlik kontrolune baglanacak.
- [x] `dracut --regenerate-all` yerine yalnizca gerekli Ro kernel surumleri icin initramfs uretilecek.
- [x] EFI, BLS, rootflags, resume UUID ve fstab dogrulamalari reboot oncesi net hata verecek.

## Intel+NVIDIA Live Boot

- [x] Normal boot, safe graphics, X11 fallback, nouveau GSP kapali, nouveau blacklist ve text console test girdileri ayrilacak.
- [x] ISO audit `i915`, `xe`, `nouveau` ve live dracut modullerini kontrol edecek.
- [x] ISO audit firmware varligini ayrıca kontrol edecek.
- [x] Kernel config kontrol listesi: `CONFIG_DRM_I915`, `CONFIG_DRM_XE`, `CONFIG_DRM_NOUVEAU`, `CONFIG_DRM_SIMPLEDRM`, `CONFIG_VMD`, `CONFIG_TYPEC`, `CONFIG_I2C_HID_ACPI`, `CONFIG_MMC`.

## Test Matrisi

- [ ] QEMU tam disk kurulum + reboot.
- [ ] QEMU ayrilmis bos alana kurulum + reboot.
- [ ] QEMU yanina kur, shrink gerekmeyen bitisik bos alan.
- [ ] Gercek cihaz Windows yanina otomatik kur.
- [ ] Gercek cihaz Windows'ta onceden ayrilmis bos alana kur.
- [ ] Gercek cihaz Intel+NVIDIA normal/safe/X11/nouveau test girdileri.
