Name:           ro-installer
Version:        1.2.7
Release:        1%{?dist}
Summary:        Official graphical installer for Ro-ASD
License:        MIT
URL:            https://github.com/Project-Ro-ASD/ro-Installer
Source0:        %{name}-%{version}.tar.gz

BuildRequires:  clang
BuildRequires:  cmake
BuildRequires:  flutter
BuildRequires:  gtk3-devel
BuildRequires:  ninja-build
BuildRequires:  pkg-config

Requires:       btrfs-progs
Requires:       dosfstools
Requires:       dracut
Requires:       e2fsprogs
Requires:       efibootmgr
Requires:       gdisk
Requires:       grub2-common
Requires:       grub2-efi-x64
Requires:       gtk3
Requires:       libX11
Requires:       NetworkManager
Requires:       parted
Requires:       polkit
Requires:       rsync
Requires:       shim-x64
Requires:       util-linux
Requires:       xfsprogs

%description
Ro-Installer is the official graphical installer for the Ro-ASD operating
system. It provides a Flutter-based Linux desktop interface on top of the
native Fedora installation toolchain.

%prep
%autosetup -n %{name}-%{version}

%build
flutter pub get
flutter build linux --release

%install
install -d %{buildroot}/usr/lib/ro-installer
cp -a build/linux/x64/release/bundle/. %{buildroot}/usr/lib/ro-installer/

install -d %{buildroot}/usr/bin
ln -sf /usr/lib/ro-installer/ro-installer %{buildroot}/usr/bin/ro-installer

install -Dm644 linux/ro-installer.desktop \
  %{buildroot}/usr/share/applications/ro-installer.desktop

install -Dm644 linux/org.roasd.installer.policy \
  %{buildroot}/usr/share/polkit-1/actions/org.roasd.installer.policy

install -Dm755 linux/ro-installer-launcher.sh \
  %{buildroot}/usr/lib/ro-installer/launcher.sh

install -Dm644 LICENSE %{buildroot}%{_licensedir}/%{name}/LICENSE

%files
%license %{_licensedir}/%{name}/LICENSE
/usr/bin/ro-installer
/usr/lib/ro-installer/
/usr/share/applications/ro-installer.desktop
/usr/share/polkit-1/actions/org.roasd.installer.policy

%post
systemctl reload polkit 2>/dev/null || true

%changelog
* Mon Apr 21 2026 Ro-ASD Team <contact@roasd.org> - 1.2.7-1
- Prepare SCM + make-srpm workflow for COPR builds
- Package Fedora-compatible UEFI boot flow and runtime dependencies
