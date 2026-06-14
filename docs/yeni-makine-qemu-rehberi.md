# Yeni Makine QEMU Rehberi

Bu rehber, bilgisayar degistirdikten sonra Ro-Installer deposunu yeni host uzerinde
hazirlamak ve uretilmis Ro-ASD ISO'yu QEMU ile acmak icindir.

## 1. Repo path dosyalarini yenile

Repo dizininde calistir:

```bash
cd /home/roasd/Masaüstü/Ro-ASD/Installer/ro-Installer
scripts/refresh-local-paths.sh
```

Bu komut su dosyalari mevcut makine yoluna gore yeniler:

- `iso-realese/latest-iso-path.txt`
- `rpm-outputs/latest-rpm-path.txt`

## 2. QEMU icin minimum paketler

Fedora:

```bash
sudo dnf install -y qemu-system-x86 qemu-img edk2-ovmf
```

Debian/Ubuntu:

```bash
sudo apt update
sudo apt install -y qemu-system-x86 qemu-utils ovmf
```

Arch:

```bash
sudo pacman -S --needed qemu-full edk2-ovmf
```

KVM hizlandirma izni icin:

```bash
sudo usermod -aG kvm "$USER"
```

Sonra oturumu kapatip ac. Hemen ayni terminalde denemek icin:

```bash
newgrp kvm
```

Kontrol:

```bash
ls -l /dev/kvm
```

## 3. Uretilen ISO'yu QEMU'da ac

Varsayilan kullanim:

```bash
scripts/qemu-boot-iso.sh
```

Varsayilan olarak `virtio` ekran karti ve ilk GRUB girdisi kullanilir. Siyah
ekran tanilamasi icin serial loglu debug girdisini sec:

```bash
scripts/qemu-boot-iso.sh --gui --video virtio --boot-entry debug
```

Ekran yine gelmezse safe graphics girdisini dene:

```bash
scripts/qemu-boot-iso.sh --gui --video virtio --boot-entry basic
```

Bu komutlardan sonra en onemli dosya sunun altindaki `serial.log` dosyasidir:

```bash
outputs/qemu-iso-test/YYYYMMDD-HHMMSS/serial.log
```

Belirli ISO ile:

```bash
scripts/qemu-boot-iso.sh --iso iso-realese/Ro-ASD-beta1.iso
```

Daha fazla kaynakla:

```bash
scripts/qemu-boot-iso.sh --memory 8192 --cpus 6 --disk-size 40G
```

Headless erken-crash kontrolu:

```bash
scripts/qemu-boot-iso.sh --headless --timeout 180 --boot-entry debug
```

Bu modda QEMU 180 saniye boyunca kapanmazsa ISO boot zinciri en azindan erken
asamada patlamamis kabul edilir. Grafik masaustu dogrulamasi icin `--gui` modu
daha anlamlidir.

## 4. ISO/RPM yeniden uretmek icin ek host paketleri

RPM ve ISO build zinciri icin Fedora tarafinda pratik paket seti:

```bash
sudo dnf install -y \
  rpm-build rsync tar awk sed grep gawk glibc-common \
  xorriso squashfs-tools erofs-utils util-linux \
  clang cmake ninja-build gtk3-devel
```

Flutter yoksa resmi stable SDK'yi kur:

```bash
mkdir -p "$HOME/development"
git clone https://github.com/flutter/flutter.git -b stable "$HOME/development/flutter"
echo 'export PATH="$HOME/development/flutter/bin:$PATH"' >> "$HOME/.bashrc"
source "$HOME/.bashrc"
flutter doctor -v
```

Sonra:

```bash
flutter test
flutter analyze
scripts/01-build-rpm.sh --no-chain
scripts/02-build-iso.sh
```

## 5. Sik gorulen hatalar

`OVMF_CODE.fd bulunamadi`:

QEMU UEFI firmware paketi eksik. Fedora icin `sudo dnf install edk2-ovmf`.

`qemu-system-x86_64 bulunamadi`:

QEMU paketi eksik. Fedora icin `sudo dnf install qemu-system-x86`.

`KVM var ama izin yok`:

Kullanici `kvm` grubunda degil. `sudo usermod -aG kvm "$USER"` sonrasi yeniden
oturum ac.

`latest-iso-path.txt eski makine yolunu gosteriyor`:

`scripts/refresh-local-paths.sh` calistir. Yeni QEMU betigi yine de ayni dosya
adini repo altinda bulursa otomatik fallback yapar.

Grafik pencere acilmiyor:

Wayland/X11 oturumu yoksa veya uzak terminaldeysen `--headless --timeout 180`
ile erken boot kontrolu yap. Masaustu gormek icin grafik oturumdan calistir.

Siyah ekran:

Once `--video virtio --boot-entry debug` ile serial log al. `vmwgfx` hatalari
gorulurse `vmware` ekran kartini kullanma. `upower` veya `irqbalance` icin
`Failed to set up user namespacing` gorulurse Ro kernel config tarafinda
`CONFIG_USER_NS=y` ile yeni kernel RPM uretmek gerekir.
