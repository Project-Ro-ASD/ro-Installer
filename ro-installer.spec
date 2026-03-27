Name:           ro-installer
Version:        1.0.0
Release:        1%{?dist}
Summary:        Ro-ASD Linux Installer using Flutter
License:        GPLv3
URL:            https://github.com/Project-Ro-ASD
Source0:        %{name}-%{version}.tar.gz


# --- BUILD ZAMANI GEREKSİNİMLERİ (FLUTTER / COMPILER) ---
BuildRequires:  git
BuildRequires:  curl
BuildRequires:  tar
BuildRequires:  xz
BuildRequires:  unzip
BuildRequires:  gcc-c++
BuildRequires:  cmake
BuildRequires:  ninja-build
BuildRequires:  pkgconfig(gtk3)
BuildRequires:  pkgconfig(glib-2.0)
BuildRequires:  pkgconfig(gio-2.0)
BuildRequires:  clang

# --- UYGULAMA ÇALIŞTIRMA (RUNTIME) GEREKSİNİMLERİ ---
Requires:       bash
Requires:       gdisk
Requires:       btrfs-progs
Requires:       e2fsprogs
Requires:       rsync
Requires:       refind
Requires:       NetworkManager

%description
Fedora tabanlı sistemler için özel olarak hazırlanmış, 
Dart ve Flutter ile yazılmış grafik arayüzlü Live İşletim Sistemi Kurucusu.
Bu paket direkt COPR üzerinde GitHub kaynak kodu alınarak derlenmiştir.

%prep
# COPR SCM automatically manages the directory name during snapshot.
%autosetup -p1 -n %{name}-%{version}


%build
# DİKKAT: COPR'ın bu adımı yapabilmesi için Proje -> Ayarlar -> "Enable network in build environment" 
# seçeneğinin AÇIK olması ZORUNLUDUR! Aksi halde Flutter ve paketleri inemez.

echo ">>> Flutter SDK İndiriliyor (Linux 3.24.3 Stable) <<<"
curl -sL https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.24.3-stable.tar.xz -o flutter.tar.xz
mkdir -p /tmp/flutter_sdk
tar xf flutter.tar.xz -C /tmp/flutter_sdk --strip-components=1

# Flutter'ı çevresel değişkenlere (PATH) al
export PATH="/tmp/flutter_sdk/bin:$PATH"

echo ">>> Flutter yapılandırılıyor (Analytics kapalı) <<<"
flutter config --no-analytics
flutter precache --linux

echo ">>> Pub Dependency Get <<<"
flutter pub get

echo ">>> Kodu Linux Tarafında Derlemeye Başlıyoruz (Release Build) <<<"
flutter build linux --release

%install
# Kurulum klasörlerini oluştur
mkdir -p %{buildroot}/opt/ro-installer
mkdir -p %{buildroot}/usr/bin
mkdir -p %{buildroot}/usr/share/applications/

# Derlenen bundle klasörünü opt dizinine aktar
cp -a build/linux/x64/release/bundle/* %{buildroot}/opt/ro-installer/

# İzinlerin doğruluğunu sağla
chmod +x %{buildroot}/opt/ro-installer/ro_installer

# Terminal global komut symlink
ln -s /opt/ro-installer/ro_installer %{buildroot}/usr/bin/ro-installer

# .desktop ikon kısayolu menü için
cat << EOF > %{buildroot}/usr/share/applications/ro-installer.desktop
[Desktop Entry]
Name=Install ro-ASD Linux
Comment=Live System Installer
Exec=pkexec /usr/bin/ro-installer
Icon=ro-installer
Terminal=false
Type=Application
Categories=System;Settings;
StartupNotify=true
EOF

%files
/opt/ro-installer/
/usr/bin/ro-installer
/usr/share/applications/ro-installer.desktop

%changelog
* Fri Mar 27 2026 smurat - 1.0.0-1
- COPR Otomatik Derleme Süreci Entegre Edildi.
