# Ro Apps Packaging Notu

Bu not `ro-assist` ve `ro-control` paketlerinin Ro-ASD Fedora 43 KDE ISO
icinde dogrudan `ro-repo` uzerinden kurulabilmesi icin gerekli paketleme
beklentilerini ozetler.

## Hedef Ortam

Ro-ASD ISO su an Fedora 43 KDE tabanlidir. Bu nedenle `ro-assist` ve
`ro-control` paketleri Fedora 43 hedef ortaminda kurulabilir olmalidir.

ISO build sirasinda paketler yerel RPM dosyasindan degil, aktif `ro-repo`
uzerinden kurulacaktir:

```bash
dnf -y --refresh --setopt=install_weak_deps=False install ro-assist
dnf -y --refresh --setopt=install_weak_deps=False install ro-control
rpm -q ro-assist ro-control
command -v ro-assist
command -v ro-control
```

Bu adimlardan biri hata verirse ISO build hata vererek duracaktir.

## Mevcut Sorun

Repo metadata ve eski ISO build loglarinda gorulen sorunlar:

- `ro-assist`, `libQt6Core.so.6(Qt_6.10)` istiyor.
- `ro-control`, `libQt6Qml.so.6(Qt_6.10_PRIVATE_API)` istiyor.
- `ro-control` ana paketi Fedora 44 build etiketiyle gorunuyor.
- `ro-control-common.noarch` ana uygulama degildir; helper, desktop file, ikon,
  policy, doc ve benzeri ortak dosyalari tasir.
- Ana `ro-control` paketi ayrica `/usr/bin/ro-control` binary dosyasini
  saglamalidir.

`Qt_6.10_PRIVATE_API` bagimliligi ozellikle risklidir. Private Qt ABI ayni Qt
minor surumune bagli kalir ve Fedora 43 ISO ortaminda cozulmeyebilir.

## Beklenen Duzeltme

1. `ro-assist` ve `ro-control`, Fedora 43 build ortaminda yeniden build
   edilmelidir.
2. `ro-control` ana paket x86_64 olarak uretilmeli ve `/usr/bin/ro-control`
   saglamalidir.
3. `ro-control-common` noarch kalabilir, fakat ana `ro-control` paketinin
   yerine gecmez.
4. Paketler Qt private ABI'ye baglanmamalidir. Ozellikle
   `Qt_6.10_PRIVATE_API` bagimliligi kaldirilmalidir.
5. Build Fedora 44, Rawhide veya Qt 6.10 ortaminda degil; Fedora 43 mock/COPR
   target ortaminda yapilmalidir.
6. Repo metadata yenilenmelidir:
   - `x86_64` repo ana binary paketleri icermeli.
   - `noarch` repo ortak/veri paketlerini icermeli.

## Kabul Testi

Temiz Fedora 43 KDE veya Fedora 43 chroot/mock ortaminda yalnizca Fedora
depolari ve `ro-repo` aktifken su komutlar hatasiz gecmelidir:

```bash
dnf clean all
dnf --refresh install ro-assist ro-control
rpm -q ro-assist ro-control
command -v ro-assist
command -v ro-control
ldd -r /usr/bin/ro-assist
ldd -r /usr/bin/ro-control
```

Ek olarak RPM bagimliliklari kontrol edilmelidir:

```bash
rpm -qpR ro-assist-*.rpm
rpm -qpR ro-control-*.rpm
```

Bu ciktilarda `Qt_6.10` veya `Qt_6.10_PRIVATE_API` gorunuyorsa paket Fedora 43
ISO icin halen riskli veya uyumsuz kabul edilmelidir.

## Mevcut Build Politikasi

Ro-ASD ISO build artik `ro-theme`, `ro-assist` ve `ro-control` paketlerini
dogrudan `ro-repo` / `ro-repo-noarch` uzerinden kurar. Bu paketlerden biri
kurulamazsa veya `ro-assist` / `ro-control` icin `command -v` ve `ldd -r`
kontrolleri gecmezse ISO build hata vererek durur.

Paketler live ISO'da hazir gelir ve kurulum sonrasi hedef sisteme de kopyalanir.
Kurulum sonrasi dogrulama, Ro repo dosyalarinin, COPR repo dosyalarinin,
`ro-assist`, `ro-control` ve `ro-theme` paketlerinin hedef sistemde kaldigini
kontrol eder. `ro-installer` ise hedef sistemden temizlenmeye devam eder.
