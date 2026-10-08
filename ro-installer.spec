Name:           ro-installer
Version:        %{?app_version}%{!?app_version:2.4.4}
Release:        %{?app_release}%{!?app_release:1}%{?dist}
Summary:        Ro-ASD Installer
License:        MIT
URL:            https://github.com/Project-Ro-ASD/ro-Installer
Source0:        %{name}-%{version}.tar.gz
BuildArch:      x86_64

# Lazy expansion resolves buildsubdir after autosetup. Keep the appended Dart
# AOT snapshot intact without disabling ELF processing for the Flutter bundle.
%define __strip %{_builddir}/%{buildsubdir}/scripts/strip-preserve-dart.sh

# The Flutter SDK is supplied by the build wrapper or CI rather than being
# taken from the Fedora buildroot repositories.
BuildRequires:  clang
BuildRequires:  cmake
BuildRequires:  ninja-build
BuildRequires:  gtk3-devel
BuildRequires:  pkgconfig(gtk+-3.0)
BuildRequires:  python3
BuildRequires:  ripgrep

Requires:       gtk3
Requires:       libX11
Requires:       polkit
Requires:       python3
Requires:       util-linux
Requires:       btrfs-progs
Requires:       dosfstools
Requires:       gdisk
Requires:       %{_sbindir}/sgdisk
Requires:       parted
Requires:       %{_sbindir}/ntfsresize
Requires:       rsync
Requires:       NetworkManager
Requires:       %{_bindir}/udevadm
Requires:       dracut
Requires:       efibootmgr
Requires:       grub2-common
Requires:       grub2-efi-x64
Requires:       shim-x64

%description
Ro-Installer is the graphical and profile-driven system installer for Ro-ASD,
a Fedora KDE based Linux distribution. It provides staged disk preparation,
partitioning, formatting, prepared-filesystem deployment, target finalization,
bootloader setup, and technical post-install validation.

%prep
%autosetup -n %{name}-%{version}

%build
export CFLAGS="${CFLAGS:-} -Wno-error=unused-command-line-argument -Wno-unused-command-line-argument"
export CXXFLAGS="${CXXFLAGS:-} -Wno-error=unused-command-line-argument -Wno-unused-command-line-argument"
flutter pub get
flutter build linux --release
dart compile exe bin/privileged_backend.dart -o ro-installer-backend

%check
bash scripts/check-stable.sh

%install
install -d %{buildroot}%{_libdir}/ro-installer
cp -a build/linux/x64/release/bundle/. %{buildroot}%{_libdir}/ro-installer/

install -d %{buildroot}%{_bindir}
ln -s ../%{_lib}/ro-installer/ro_installer %{buildroot}%{_bindir}/ro-installer
ln -s ../%{_lib}/ro-installer/ro_installer %{buildroot}%{_bindir}/ro_installer

install -Dm644 linux/ro-installer.desktop \
    %{buildroot}%{_datadir}/applications/ro-installer.desktop

install -Dm755 linux/ro-installer-launcher.sh \
    %{buildroot}%{_libexecdir}/ro-installer-launcher.sh

install -Dm755 ro-installer-backend \
    %{buildroot}%{_libexecdir}/ro-installer-backend

install -Dm755 linux/ro-installer-helper \
    %{buildroot}%{_libexecdir}/ro-installer-helper

install -Dm644 linux/org.roasd.installer.helper.policy \
    %{buildroot}%{_datadir}/polkit-1/actions/org.roasd.installer.helper.policy

%files
%license LICENSE
%doc README.md
%{_libdir}/ro-installer/
%{_bindir}/ro-installer
%{_bindir}/ro_installer
%{_datadir}/applications/ro-installer.desktop
%{_libexecdir}/ro-installer-launcher.sh
%attr(0755,root,root) %{_libexecdir}/ro-installer-backend
%attr(0755,root,root) %{_libexecdir}/ro-installer-helper
%attr(0644,root,root) %{_datadir}/polkit-1/actions/org.roasd.installer.helper.policy

%changelog
* Tue Oct 06 2026 Ro-ASD Team <contact@roasd.org> - 2.4.4-1
- Fix release-job wiring for build-side RPM identity and digest outputs.

* Mon Oct 05 2026 Ro-ASD Team <contact@roasd.org> - 2.4.3-1
- Harden immutable GitHub Release state handling before publication.

* Mon Oct 05 2026 Ro-ASD Team <contact@roasd.org> - 2.4.2-1
- Harden SRPM release classification and test the manifest contract in CI.

* Mon Oct 05 2026 Ro-ASD Team <contact@roasd.org> - 2.4.1-1
- Fix immutable release SRPM classification check.

* Mon Apr 27 2026 Ro-ASD Team <contact@roasd.org> - 2.4.0-1
- RPM paketleme dosyasi eklendi.
- gdisk ve sgdisk bagimliliklari zorunlu hale getirildi.
- ntfsresize ve udevadm runtime bagimliliklari paket seviyesinde netlestirildi.
