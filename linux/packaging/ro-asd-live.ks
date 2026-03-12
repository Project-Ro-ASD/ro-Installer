# ro-asd-live-kde.ks
# Fedora 43 KDE tabanli Ro-ASD Live ISO sablonu

# Network ayari
network --bootproto=dhcp --device=link --activate

# Repository Ayarlari (Fedora Base ve Local RPM)
url --mirrorlist=https://mirrors.fedoraproject.org/mirrorlist?repo=fedora-43&arch=x86_64
repo --name=fedora --mirrorlist=https://mirrors.fedoraproject.org/mirrorlist?repo=fedora-43&arch=x86_64
repo --name=updates --mirrorlist=https://mirrors.fedoraproject.org/mirrorlist?repo=updates-released-f43&arch=x86_64
repo --name=local_ro_asd --baseurl=file:///var/tmp/ro-asd-repo/

# Root sifresi kilitli
rootpw --lock

# Anaconda'nin patlamamasi icin gecici user yaratimi (Asagida silecegiz)
user --name=roasd --groups=wheel --password=roasd --plaintext

clearpart --all
part / --size 12288 --fstype ext4

xconfig --startxonboot

%packages
# Sistemin bel kemigi ve donanim suruculeri
@core
kernel
kernel-modules
kernel-modules-extra
@hardware-support

# Masaustu ve araclar
-man-db
dracut-live
@^kde-desktop-environment
sddm
sddm-kcm
kwalletmanager5
polkit-kde

# Ozel RPM'ler ve yardimci toollar
ro_installer_beta
gdisk
parted
btrfs-progs
xfsprogs
e2fsprogs
squashfs-tools
arch-install-scripts
git
refind
efibootmgr
%end

%post
# Gecici sifreyi silip NOPASSWD veriyoruz
passwd -d roasd
echo "roasd ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/roasd
chmod 0440 /etc/sudoers.d/roasd

# SDDM Autologin
mkdir -p /etc/sddm.conf.d
cat > /etc/sddm.conf.d/autologin.conf << EOF
[Autologin]
User=roasd
Session=plasma
EOF

# Masaustu Kisayolu
mkdir -p /home/roasd/Desktop
cp /usr/share/applications/ro-installer.desktop /home/roasd/Desktop/
chmod +x /home/roasd/Desktop/ro-installer.desktop

# Yetkileri roasd kullanicisina kitliyoruz
chown -R roasd:roasd /home/roasd
%end