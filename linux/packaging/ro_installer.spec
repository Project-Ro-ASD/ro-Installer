%global debug_package %{nil}

Name:           ro_installer_beta
Version:        1.0.0
Release:        1%{?dist}
Summary:        The Official Ro-ASD OS System Installer

License:        GPLv3
URL:            https://github.com/Project-Ro-ASD/Ro-Installer
Source0:        %{name}-%{version}.tar.gz

BuildRequires:  flutter
BuildRequires:  cmake
BuildRequires:  clang
BuildRequires:  ninja-build
BuildRequires:  pkgconfig(gtk3)

Requires:       polkit
Requires:       gdisk
Requires:       parted
Requires:       btrfs-progs
Requires:       xfsprogs
Requires:       e2fsprogs
Requires:       squashfs-tools
Requires:       refind
Requires:       git
Requires:       arch-install-scripts

%description
A modern and beautifully designed OS Installer for the Ro-ASD ecosystem,
written in Flutter and native C++.

%prep
%autosetup

%build
export PATH="$PATH:$HOME/.local/flutter/bin"
export CFLAGS=""
export CXXFLAGS=""
export LDFLAGS=""
flutter build linux --release

%install
mkdir -p %{buildroot}/usr/bin
mkdir -p %{buildroot}/usr/lib/%{name}
mkdir -p %{buildroot}/usr/share/applications
mkdir -p %{buildroot}/usr/share/polkit-1/actions

# Flutter derlenen bundle dizini
cp -r build/linux/x64/release/bundle/* %{buildroot}/usr/lib/%{name}/

# C++ So ve Diger Libler
chmod +x %{buildroot}/usr/lib/%{name}/%{name}

# İki ayrı calistirilabilir dosya için sembolik bağ
ln -sf /usr/lib/%{name}/%{name} %{buildroot}/usr/bin/%{name}

# Masaustu Simgesi ve PolicyKit Yetkileri
cp linux/packaging/ro-installer.desktop %{buildroot}/usr/share/applications/
cp linux/packaging/com.roasd.installer.policy %{buildroot}/usr/share/polkit-1/actions/

%files
/usr/bin/%{name}
/usr/lib/%{name}/
/usr/share/applications/ro-installer.desktop
/usr/share/polkit-1/actions/com.roasd.installer.policy

%changelog
* Thu Mar 12 2026 Ro-ASD Team <info@ro-asd.org> - 1.0.0-1
- Initial RPM release with C++ Backend & FFI Integration
