# Siyah Ekran Kernel ve ISO Notlari

Bu not, Ro-ASD live ISO QEMU veya gercek donanimda siyah ekranda kaldiginda
izlenecek ayrimi kaydeder.

## Kullanici tarafinda alinacak kanitlar

QEMU icin once debug girdisiyle baslat:

```bash
sudo /home/smurat/Masaüstü/ro-Installer/scripts/qemu-boot-iso.sh \
  --gui \
  --video virtio \
  --boot-entry debug
```

Ekran yine gelmezse safe graphics:

```bash
sudo /home/smurat/Masaüstü/ro-Installer/scripts/qemu-boot-iso.sh \
  --gui \
  --video virtio \
  --boot-entry basic
```

Sonra en yeni logu kontrol et:

```bash
ls -td /home/smurat/Masaüstü/ro-Installer/outputs/qemu-iso-test/* | head -1
tail -300 /home/smurat/Masaüstü/ro-Installer/outputs/qemu-iso-test/YYYYMMDD-HHMMSS/serial.log
```

Gercek bilgisayarda GRUB ekraninda `e` ile kernel satirindan `quiet rhgb`
kaldirilip su argumanlar eklenebilir:

```text
plymouth.enable=0 systemd.log_level=info
```

Safe graphics denemesi icin:

```text
nomodeset plymouth.enable=0 systemd.log_level=info
```

## Kernel tarafinda gerekli ayarlar

Mevcut Ro kernel RPM'inde tespit edilen kritik eksik:

```text
# CONFIG_USER_NS is not set
```

Fedora 43/systemd ortaminda bazi servisler `PrivateUsers` kullandigi icin bu
ayar kapaliyken `upower` ve `irqbalance` gibi servisler `217/USER` ile dusebilir.
Kernel config tarafinda su ayar acik olmali:

```text
CONFIG_USER_NS=y
```

QEMU ve gercek donanim icin grafik temel ayarlari:

```text
CONFIG_DRM=y
CONFIG_DRM_FBDEV_EMULATION=y
CONFIG_DRM_SIMPLEDRM=y
CONFIG_DRM_VIRTIO_GPU=y
CONFIG_DRM_VIRTIO_GPU_KMS=y
CONFIG_DRM_CIRRUS_QEMU=m
CONFIG_DRM_VMWGFX=m
CONFIG_DRM_QXL=m
CONFIG_DRM_BOCHS=m
CONFIG_DRM_I915=m
CONFIG_DRM_XE=m
CONFIG_DRM_AMDGPU=m
CONFIG_DRM_RADEON=m
CONFIG_DRM_NOUVEAU=m
CONFIG_FRAMEBUFFER_CONSOLE=y
CONFIG_FB_EFI=y
```

`QXL` ve `BOCHS` zorunlu degil ama sanal makine fallback yuzeyini genisletir.
`virtio_gpu` QEMU icin ana tercih olmali; `vmware/vmwgfx` QEMU altinda sorunlu
olabilir.

## Repo tarafinda uygulanan ISO politikasi

`scripts/02-build-iso.sh` live root icine sunlari yazar:

- SDDM live autologin icin varsa Plasma Wayland oturumu, yoksa X11 fallback.
- Troubleshooting girdilerinde `ro.live.session=x11` secildiginde SDDM
  autologin X11 oturumuna zorlanir; `ro.live.software_render=1` secildiginde
  yalnizca live ortam icin Qt/KWin yazilim render ortam degiskenleri yazilir.
- Default target olarak `graphical.target`.
- Serial loglu debug/text/safe graphics/X11/software render/nouveau GSP kapali
  ve nouveau kapali GRUB girdileri.
- Normal boot ve Fedora kaynak basic graphics girdileri `nouveau`, `i915` ve
  `xe` driverlarini blacklist etmez. Bu driverlar ro-kernel-stable uzerinde
  Fedora varsayilan grafik politikasina birakilir.
- Safe graphics girdisi yalnizca genel fallback olarak `nomodeset` ekler; bu
  girdi kullanici bilerek sectiginde KMS'i devre disi birakir.
- `nouveau.config=NvGspRm=0` ve `nouveau` blacklist secenekleri normal boot'a
  yazilmaz; sadece troubleshooting menusu icindeki acik adli tanı girdilerinde
  bulunur. `i915` ve `xe` icin hicbir GRUB girdisinde blacklist veya
  `modeset=0` kullanilmaz.
- Gercek USB/optik boot sirasinda `/dev/root` bulunamamasini azaltmak icin
  live kernel satirlarinda `rd.live.dir=LiveOS`, `rd.live.squashimg=squashfs.img`
  ve `rd.retry=180`.
- Live initrd Fedora live imajina daha yakin uretilir:
  `--add 'dmsquash-live livenet pollcdrom'` ve `--no-hostonly-cmdline`.
- ISO kokune `ro-live-kernel-config-check.txt` ve
  `ro-live-firmware-check.txt` manifestleri yazilir. Audit bu dosyalardan
  `CONFIG_DRM_I915`, `CONFIG_DRM_XE`, `CONFIG_DRM_NOUVEAU`,
  `CONFIG_DRM_SIMPLEDRM`, `CONFIG_VMD`, `CONFIG_TYPEC`,
  `CONFIG_I2C_HID_ACPI`, `CONFIG_MMC` ve i915/xe/NVIDIA GSP firmware
  varligini kontrol eder.
- 2026-05-06 itibariyla `scripts/02-build-iso.sh` live boot icin
  ro-kernel-stable kurar, live kernel/initrd dosyalarini bu kernelden uretir
  ve Fedora stock kernel paketlerini live root'tan temizler. `--live-kernel`
  ve `--ro-kernel-dir` geriye donuk uyumluluk icin kabul edilip yok sayilir.
  Gelismis kurulumda ro-kernel-stable, ro-kernel-experimental veya ikisi
  birlikte secilebilir; basit kurulum yalnizca ro-kernel-stable kullanir.

Yeni ISO uretildikten sonra release kontrolu:

```bash
/home/smurat/Masaüstü/ro-Installer/scripts/03-audit-iso.sh \
  /home/smurat/Masaüstü/ro-Installer/iso-realese/Ro-ASD-betaN.iso
```

Bu script UEFI ESP, GRUB live parametreleri, safe graphics ayirimi, X11 ve
software render tanı girdileri, nouveau GSP/blacklist girdilerinin sinirlarini
ve initrd live modullerini kontrol eder. `FAIL` varken ISO sunuma cikmamalidir.

Installer, kurulu sisteme kopyalama sonrasi bu live-only dosyalari
`ChrootConfigStage` icinde temizler.

Ayrintili guncel kararlar icin `docs/grafik-driver-politikasi.md` dosyasina
bak.

## 2026-05-03 gercek donanim bulgulari

`Ro-ASD-beta1.iso` icin gizli UEFI FAT bolumu ve gorunen ISO agaci
incelendi; iki tarafta da `EFI/BOOT/grubx64.efi` mevcut. Bu nedenle
`Failed to open \EFI\BOOT\grubx64.efi` mesaji bir paketleme eksiginden cok
firmware/USB yazma yolu veya shim'in fallback arama davranisi gibi erken UEFI
asamasina isaret ediyor.

Asil boot blokaji `Warning: /dev/root does not exist` tarafinda gorundu.
Karsilastirma:

- Fedora kaynak initrd: `dmsquash-live livenet pollcdrom`
- Eski Ro initrd: sadece `dmsquash-live`

Bu fark gercek USB/optik medyada CDLABEL cihazi gec algilandiginda veya
yeniden yoklama gerektirdiginde dracut'un live kok dosya sistemini bulamamasina
yol acabilir. Yeni ISO mutlaka bu degisikliklerden sonra yeniden uretilmeli.

Ro kernel config tarafinda hala takip edilmesi gereken modern laptop riskleri:

- `CONFIG_VMD` kapali: Intel VMD/RAID modunda NVMe diskler gorunmeyebilir.
- `CONFIG_TYPEC` kapali: USB-C/Type-C platform destegi kisitli.
- `CONFIG_I2C_HID_ACPI` kapali: bazi laptop touchpad/touchscreen aygitlari
  calismayabilir.
- `CONFIG_MMC` kapali: SD/eMMC aygitlari gorunmez.

Bu riskler live kokun bulunamamasinin ana nedeni degil, ama Ro kernel'in
sonraki surumunde acilmasi gereken uyumluluk maddeleridir.
