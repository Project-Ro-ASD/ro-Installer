# Ro Kernel Black Screen Diagnostics

Bu dosyadaki komutlari once Ro installer ile kurulmus sistemde, acilabilen custom kernel uzerinde calistirin.

Oncelik sirası:

1. Custom Ro kernel ile GRUB'da `nomodeset plymouth.enable=0` ekleyerek acin ve `A-CUSTOM-NOMODESET` bolumunu calistirin.
2. Ayni makinede Fedora stock kernel ile normal acin ve `B-STOCK-FEDORA-KERNEL` bolumunu calistirin.
3. Mumkunse ayni custom kernelin sorunsuz calistigi official Fedora kurulumunda `C-OFFICIAL-FEDORA-REFERENCE` bolumunu calistirin.

Komutlar ciktilari `/tmp/ro-kernel-debug-*.txt` dosyalarina yazar.

## A-CUSTOM-NOMODESET

Custom Ro kernel ile, GRUB'da su parametrelerle acin:

```text
nomodeset plymouth.enable=0
```

Sonra terminalde calistirin:

```bash
sudo bash -c '
OUT=/tmp/ro-kernel-debug-custom-nomodeset.txt
{
echo "===== DATE ====="
date

echo
echo "===== UNAME ====="
uname -a

echo
echo "===== /proc/cmdline ====="
cat /proc/cmdline

echo
echo "===== /etc/kernel/cmdline ====="
cat /etc/kernel/cmdline 2>&1

echo
echo "===== BLS ENTRIES ====="
ls -la /boot/loader/entries 2>&1
for f in /boot/loader/entries/*.conf; do
  echo
  echo "----- $f -----"
  sed -n "1,160p" "$f" 2>&1
done

echo
echo "===== FSTAB ====="
cat /etc/fstab 2>&1

echo
echo "===== FINDMNT ROOT ====="
findmnt -no SOURCE,FSTYPE,OPTIONS / 2>&1

echo
echo "===== CMDLINE.D ====="
find /etc/cmdline.d -maxdepth 2 -type f -print -exec sed -n "1,120p" {} \; 2>&1

echo
echo "===== DRACUT CONFIG ====="
find /etc/dracut.conf /etc/dracut.conf.d /usr/lib/dracut/dracut.conf.d -maxdepth 2 -type f -print -exec sed -n "1,160p" {} \; 2>&1

echo
echo "===== DRACUT/CMDLINE LIVE OR DRIVER HINTS ====="
grep -RInE "rd.live|root=live|CDLABEL|hostonly|cmdline|omit|add_drivers|force_drivers|nouveau|i915|xe|amdgpu|simpledrm" /etc/dracut.conf /etc/dracut.conf.d /usr/lib/dracut/dracut.conf.d /etc/cmdline.d 2>/dev/null || true

echo
echo "===== MODPROBE AND MODULES-LOAD ====="
find /etc/modprobe.d /usr/lib/modprobe.d /etc/modules-load.d /usr/lib/modules-load.d -type f -print -exec grep -HnE "nouveau|i915|xe|amdgpu|simpledrm|blacklist|options|modeset|firmware" {} \; 2>&1

echo
echo "===== DNF KERNEL POLICY ====="
cat /etc/dnf/dnf.conf 2>&1
find /etc/dnf/protected.d -maxdepth 1 -type f -print -exec sed -n "1,120p" {} \; 2>&1

echo
echo "===== INSTALLED KERNEL PACKAGES ====="
rpm -qa | sort | grep -E "^(kernel|ro-kernel|akmod|kmod|dracut|systemd|linux-firmware|mesa|libdrm|xorg-x11-drv|plymouth|btrfs-progs)" 2>&1

echo
echo "===== LOADED GRAPHICS MODULES ====="
lsmod | grep -E "nouveau|i915|xe|amdgpu|radeon|drm|simpledrm" 2>&1 || true

echo
echo "===== PCI VGA ====="
lspci -nnk | grep -A4 -Ei "VGA|3D|Display" 2>&1

echo
echo "===== KERNEL LOG GRAPHICS ====="
journalctl -b -k --no-pager | grep -Ei "drm|kms|nouveau|i915|xe|amdgpu|radeon|simpledrm|fb|framebuffer|firmware|gpu|vga|vesa|efi" 2>&1 || true

echo
echo "===== CURRENT BOOT ERRORS ====="
journalctl -b -p warning..alert --no-pager 2>&1
} | tee "$OUT"
echo "Saved to $OUT"
'
```

## B-STOCK-FEDORA-KERNEL

Ayni Ro-installer kurulumunda Fedora stock kernel ile normal acin.

Sonra calistirin:

```bash
sudo bash -c '
OUT=/tmp/ro-kernel-debug-stock-fedora-kernel.txt
{
echo "===== DATE ====="
date

echo
echo "===== UNAME ====="
uname -a

echo
echo "===== /proc/cmdline ====="
cat /proc/cmdline

echo
echo "===== /etc/kernel/cmdline ====="
cat /etc/kernel/cmdline 2>&1

echo
echo "===== BLS ENTRIES ====="
ls -la /boot/loader/entries 2>&1
for f in /boot/loader/entries/*.conf; do
  echo
  echo "----- $f -----"
  sed -n "1,160p" "$f" 2>&1
done

echo
echo "===== FSTAB ====="
cat /etc/fstab 2>&1

echo
echo "===== FINDMNT ROOT ====="
findmnt -no SOURCE,FSTYPE,OPTIONS / 2>&1

echo
echo "===== CMDLINE.D ====="
find /etc/cmdline.d -maxdepth 2 -type f -print -exec sed -n "1,120p" {} \; 2>&1

echo
echo "===== DRACUT CONFIG ====="
find /etc/dracut.conf /etc/dracut.conf.d /usr/lib/dracut/dracut.conf.d -maxdepth 2 -type f -print -exec sed -n "1,160p" {} \; 2>&1

echo
echo "===== MODPROBE AND MODULES-LOAD ====="
find /etc/modprobe.d /usr/lib/modprobe.d /etc/modules-load.d /usr/lib/modules-load.d -type f -print -exec grep -HnE "nouveau|i915|xe|amdgpu|simpledrm|blacklist|options|modeset|firmware" {} \; 2>&1

echo
echo "===== DNF KERNEL POLICY ====="
cat /etc/dnf/dnf.conf 2>&1
find /etc/dnf/protected.d -maxdepth 1 -type f -print -exec sed -n "1,120p" {} \; 2>&1

echo
echo "===== INSTALLED KERNEL PACKAGES ====="
rpm -qa | sort | grep -E "^(kernel|ro-kernel|akmod|kmod|dracut|systemd|linux-firmware|mesa|libdrm|xorg-x11-drv|plymouth|btrfs-progs)" 2>&1

echo
echo "===== LOADED GRAPHICS MODULES ====="
lsmod | grep -E "nouveau|i915|xe|amdgpu|radeon|drm|simpledrm" 2>&1 || true

echo
echo "===== PCI VGA ====="
lspci -nnk | grep -A4 -Ei "VGA|3D|Display" 2>&1

echo
echo "===== KERNEL LOG GRAPHICS ====="
journalctl -b -k --no-pager | grep -Ei "drm|kms|nouveau|i915|xe|amdgpu|radeon|simpledrm|fb|framebuffer|firmware|gpu|vga|vesa|efi" 2>&1 || true

echo
echo "===== CURRENT BOOT ERRORS ====="
journalctl -b -p warning..alert --no-pager 2>&1
} | tee "$OUT"
echo "Saved to $OUT"
'
```

## C-OFFICIAL-FEDORA-REFERENCE

Ayni custom kernelin sorunsuz calistigi official Fedora kurulumunda calistirin.

```bash
sudo bash -c '
OUT=/tmp/ro-kernel-debug-official-fedora-custom-kernel.txt
{
echo "===== DATE ====="
date

echo
echo "===== UNAME ====="
uname -a

echo
echo "===== /proc/cmdline ====="
cat /proc/cmdline

echo
echo "===== /etc/kernel/cmdline ====="
cat /etc/kernel/cmdline 2>&1

echo
echo "===== BLS ENTRIES ====="
ls -la /boot/loader/entries 2>&1
for f in /boot/loader/entries/*.conf; do
  echo
  echo "----- $f -----"
  sed -n "1,160p" "$f" 2>&1
done

echo
echo "===== FSTAB ====="
cat /etc/fstab 2>&1

echo
echo "===== FINDMNT ROOT ====="
findmnt -no SOURCE,FSTYPE,OPTIONS / 2>&1

echo
echo "===== CMDLINE.D ====="
find /etc/cmdline.d -maxdepth 2 -type f -print -exec sed -n "1,120p" {} \; 2>&1

echo
echo "===== DRACUT CONFIG ====="
find /etc/dracut.conf /etc/dracut.conf.d /usr/lib/dracut/dracut.conf.d -maxdepth 2 -type f -print -exec sed -n "1,160p" {} \; 2>&1

echo
echo "===== MODPROBE AND MODULES-LOAD ====="
find /etc/modprobe.d /usr/lib/modprobe.d /etc/modules-load.d /usr/lib/modules-load.d -type f -print -exec grep -HnE "nouveau|i915|xe|amdgpu|simpledrm|blacklist|options|modeset|firmware" {} \; 2>&1

echo
echo "===== INSTALLED KERNEL PACKAGES ====="
rpm -qa | sort | grep -E "^(kernel|ro-kernel|akmod|kmod|dracut|systemd|linux-firmware|mesa|libdrm|xorg-x11-drv|plymouth|btrfs-progs)" 2>&1

echo
echo "===== LOADED GRAPHICS MODULES ====="
lsmod | grep -E "nouveau|i915|xe|amdgpu|radeon|drm|simpledrm" 2>&1 || true

echo
echo "===== PCI VGA ====="
lspci -nnk | grep -A4 -Ei "VGA|3D|Display" 2>&1

echo
echo "===== KERNEL LOG GRAPHICS ====="
journalctl -b -k --no-pager | grep -Ei "drm|kms|nouveau|i915|xe|amdgpu|radeon|simpledrm|fb|framebuffer|firmware|gpu|vga|vesa|efi" 2>&1 || true

echo
echo "===== CURRENT BOOT ERRORS ====="
journalctl -b -p warning..alert --no-pager 2>&1
} | tee "$OUT"
echo "Saved to $OUT"
'
```
