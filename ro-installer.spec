Name:           ro-installer
Version:        3.0.0
Release:        1%{?dist}
Summary:        Official graphical installer for Ro-ASD
License:        MIT
URL:            https://github.com/Project-Ro-ASD/ro-Installer
Source0:        %{name}-%{version}.tar.gz
%global flutter_version 3.41.7
%global flutter_channel stable
%global flutter_archive flutter_linux_%{flutter_version}-%{flutter_channel}.tar.xz
%global flutter_url https://storage.googleapis.com/flutter_infra_release/releases/%{flutter_channel}/linux/%{flutter_archive}
%global flutter_sha256 f344d5057db52abc2a63cd3a7c7370957b7685d1fca5e5fbe2ce4dfe74657a79

BuildRequires:  clang
BuildRequires:  cmake
BuildRequires:  curl
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
export FLUTTER_ROOT="$PWD/.flutter-sdk"
export PUB_CACHE="$PWD/.pub-cache"
export CI=true
export FLUTTER_SUPPRESS_ANALYTICS=true
export PATH="$FLUTTER_ROOT/bin:$PATH"

rm -rf "$FLUTTER_ROOT" "$PUB_CACHE"
curl -L --retry 5 --fail --output "%{flutter_archive}" "%{flutter_url}"
echo "%{flutter_sha256}  %{flutter_archive}" | sha256sum -c -
tar -xf "%{flutter_archive}"
mv flutter "$FLUTTER_ROOT"

flutter config --no-analytics --enable-linux-desktop
flutter precache --linux
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
* Fri Apr 24 2026 Ro-ASD Team <contact@roasd.org> - 3.0.0-1
- Prepare the v3.0.0 public release
- Ship the refreshed multilingual installer experience
- Align packaging with current Fedora and COPR workflow
