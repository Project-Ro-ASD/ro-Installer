# Eksikler

Bu dosya, Fedora Live ISO ve QEMU testlerinde ortaya cikan eksikleri ve o anki durumlarini ozetler.

## Cozulen Eksikler

1. `fstab` uretimi canli sistem mountlarini hedef sisteme sizdiriyordu.
   Durum: Cozuldu.
   Not: `/run/initramfs/live`, `/dev/sr0`, `loop`, `zram` ve canli swap girdileri artik hedef `fstab` icine yazilmiyor.

2. UEFI/Secure Boot akisinda `grub2-install` kullaniliyordu.
   Durum: Cozuldu.
   Not: Fedora'ya uygun sekilde `shimx64.efi` + ESP stub `grub.cfg` + `efibootmgr` zincirine gecildi.

3. Bootloader asamasi tam disk kurulumda ayri `/boot` varmis gibi davraniyordu.
   Durum: Cozuldu.
   Not: Ayri `/boot` yoksa artik bosuna `/mnt/boot` UUID aranmiyor; gerekli durumda root UUID kullaniliyor.

4. Btrfs `subvol=@` kurulumunda ESP icindeki GRUB stub yanlis yola bakiyordu.
   Durum: Cozuldu.
   Not: `grub.cfg` artik Btrfs tam kurulumda `@/boot/grub2/grub.cfg` yolunu hedefliyor.

5. Kurulum ekrani uzerindeki `Yeniden Baslat` butonu bos bir `TODO` idi.
   Durum: Cozuldu.
   Not: Buton artik reboot komutu gonderiyor; daha once sadece gorunuyordu ama hicbir sey yapmiyordu.

6. QEMU otomatik testte guest disk yolu profil ile uyusmuyordu.
   Durum: Cozuldu.
   Not: VM profili otomatik uretilip disk secimi `/dev/vda` olarak override ediliyor.

7. Linux build sirasinda yanlis `clang++` wrapper kullanilabiliyordu.
   Durum: Cozuldu.
   Not: Host tarafinda gercek `/usr/bin/clang` ve `/usr/bin/clang++` seciliyor.

## Tespit Edilen Operasyonel Eksikler

1. Stok Fedora Live ISO icinde `gdisk` yok.
   Durum: Biliniyor.
   Etki: Raw bundle ile manuel testte Stage 2 (`sgdisk`) baslamadan hata veriyor.
   Gecici cozum: Live ortamda `sudo dnf install -y gdisk`.
   Kalici cozum: RPM/remaster yolunda bagimliligi garanti etmek.

2. Host share icindeki binary dogrudan calistirilinca polkit policy devreye girmiyor.
   Durum: Biliniyor.
   Etki: `/mnt/host/.../ro_installer` normal kullanici olarak acilinca izin sorunu olusuyor.
   Gecici cozum: `sudo -E /mnt/host/build/linux/x64/release/bundle/ro_installer`.
   Kalici cozum: Paketli `/usr/bin/ro-installer` yolu ile entegrasyon testi yapmak.

3. Live ortamda SELinux popup gurultusu olusabiliyor.
   Durum: Biliniyor.
   Etki: Kurulum bozulmus gibi gorunebiliyor ama cogu zaman yalnizca `setroubleshoot` bildirimi.
   Not: Ilk boot'taki `autorelabel` ekrani ise normal Fedora davranisi.

4. Manuel test akisi yazma ve klavye uyumsuzlugu yuzunden yorucu.
   Durum: Biliniyor.
   Etki: Uzun komutlar canli ortamda zor yaziliyor.
   Not: Daha kisa debug/host-copy komutlari veya yardimci script faydali olur.

## Hala Dogrulanmasi Gerekenler

1. `ext4` tam disk kurulumunun gercek VM testi.
   Durum: Kod yolu hazir, manuel gercek test henuz yapilmadi.

2. `xfs` tam disk kurulumunun gercek VM testi.
   Durum: Kod yolu hazir, manuel gercek test henuz yapilmadi.

3. RPM paketli kurulum akisinin tekrar test edilmesi.
   Durum: Henuz yapilmadi.
   Not: Uygulamanin menu entegrasyonu, polkit policy davranisi ve paket bagimliliklari bu yolda yeniden dogrulanmali.

4. Otomatik QEMU testinin yeni bootloader duzeltmeleriyle tekrar kosulmasi.
   Durum: Henuz yapilmadi.
   Not: Manuel akista kritik sorunlar giderildi; simdi otomatik smoke test de tekrar yesile donmeli.

## Ogrenilen Dersler

1. Fedora UEFI/Secure Boot tarafinda `grub2-install` kullanmak dogru yaklasim degil.

2. Btrfs `subvol=@` kullaniliyorsa boot zincirindeki yol varsayimlari ayri ele alinmali.

3. Canli sistemden `findmnt -R /mnt` gibi genis taramalarla `fstab` uretmek guvenilir degil.

4. Kurulum motoru basarili olsa bile son UI aksiyonlari ayri test edilmedikce kritik eksikler kacabiliyor.
