# Grafik Driver Politikasi

2026-05-04 itibariyla Ro-ASD ISO grafik politikasi Fedora varsayilanina yakin
tutulur.

## Normal boot

- `nouveau`, `i915` ve `xe` blacklist edilmez.
- `nouveau.modeset=0`, `i915.modeset=0`, `xe.modeset=0` yazilmaz.
- Normal GRUB girdisine `nomodeset` eklenmez.
- Plasma live oturumunda Wayland varsa once Wayland kullanilir; X11 yalnizca
  Wayland session dosyasi yoksa fallback olur.
- Qt/KWin icin global software-render veya DRM override yazilmaz.

Bu karar NVIDIA kartlarda da gecerlidir. Acik kaynak `nouveau` once Fedora'nin
sectigi sekilde calisir. Kapali kaynak NVIDIA surucusunu isteyen kullanici
kurulu sistemde `ro-control` ile kurar.

## Safe graphics

- Safe graphics sadece bilerek secilen kurtarma yoludur.
- Bu girdide yalnizca genel fallback olarak `nomodeset` eklenir.
- Vendor-specific blacklist yoktur; `nouveau`, `i915`, `xe` icin ayri kapatma
  yapilmaz.

## Intel+NVIDIA tanı girdileri

Normal boot politikasini bozmadan troubleshooting menusu su ek yollari sunar:

- `Start Ro-ASD Live with X11 session`: SDDM live autologin oturumunu
  `ro.live.session=x11` ile X11'e alir.
- `Start Ro-ASD Live with X11 software rendering`: X11'e ek olarak yalnizca
  live ortamda `ro.live.software_render=1` ile Qt/KWin yazilim render yolunu
  dener.
- `Start Ro-ASD Live with nouveau GSP disabled`: `nouveau.config=NvGspRm=0`
  ile Turing/Ampere sinifinda GSP yolunu devre disi birakarak nouveau'yu
  yuklu tutan tanı girisidir.
- `Start Ro-ASD Live with nouveau disabled`: yalnizca tanı/kurtarma icin
  `rd.driver.blacklist=nouveau modprobe.blacklist=nouveau` ekler.

Bu girdiler `i915` ve `xe` icin blacklist veya `modeset=0` kullanmaz. Kurulu
sisteme geciste live-only SDDM/graphics override dosyalari `ChrootConfigStage`
tarafindan temizlenir.

## Release audit

`scripts/03-audit-iso.sh` normal/safe/tanı GRUB ayrimini kontrol eder. Ayrica
ISO kokundeki live manifestlerden Intel/NVIDIA icin kritik kernel config
seceneklerinin `y` veya `m` olmasini ve i915/xe/NVIDIA GSP firmware
dosyalarinin bulunmasini bekler.

## Ro uygulamalari

`ro-assist` ve `ro-control` ISO icin beklenen uygulamalardir. ISO build bu
uygulamalari ayri ayri kurar ve `rpm -q` ile dogrular. Paketlerden biri eksik
kalirsa build artik iptal edilir. Kurulu sistemde ilk kullanici oturumunda
`ro-assist` ilk-giris karsilama uygulamasi olarak baslatilir; live oturumdaki
`liveuser` icin bu autostart devreye girmez.

## 1024x768 notu

Installer UI tarafinda dusuk cozunurluk ve olcekleme icin responsive density
duzeltmeleri yapildi. ISO'nun 1024x768'e dusmesi ise genelde kernel driver,
KWin/Qt override veya sanal GPU fallback kaynaklidir. Bu yuzden ISO tarafinda
driver blacklist ve global render override'lari kaldirildi; yeni ISO testinde
cozunurluk tekrar fiziksel makine ve QEMU ekran kartlariyla dogrulanmalidir.
