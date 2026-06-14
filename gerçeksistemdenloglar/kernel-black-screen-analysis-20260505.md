# 2026-05-05 Ro Kernel Siyah Ekran Analizi

## Kısa Sonuç

Bu log setinde ana kırılma `initramfs`, Btrfs root switch, Plymouth veya SDDM değil.

Sistemin sadece `nomodeset` ile açılması ve Fedora stock kernelin aynı Ro-installed sistemde aynı RTX 3090 kartta `nouveau` ile açılması, sorunu güçlü şekilde custom Ro kernelin `nouveau`/DRM/KMS yoluna taşıyor.

Bu loglara göre birincil suçlu adayı:

```text
ro-kernel-stable 6.19.13-103 + nouveau/GSP/KMS + NVIDIA GA102 RTX 3090
```

Installer tarafında ise bu loglarda ana boot kırılmasını açıklayan bir kanıt yok. Yine de installer tarafında doğrulama ve temizlik eksiği olarak ele alınması gereken noktalar var.

## En Önemli Kanıtlar

### 1. Custom Ro kernel sadece nomodeset ile açılmış

Dosya:

```text
gerçeksistemdenloglar/ro-kernel-debug-custom-nomodeset.txt
```

Kanıt:

```text
UNAME:
Linux ro-asd 6.19.13-103.fc43.ro_stable.x86_64

/proc/cmdline:
... rootflags=subvol=@ nomodeset plymouth.enable=0

kernel log:
Booted with the nomodeset parameter. Only the system framebuffer will be available
```

Yorum:

`nomodeset`, GPU'nun gerçek kernel mode-setting yolunu devre dışı bırakır. Bu yüzden sistemin düşük çözünürlükte açılması beklenen davranış. Bu, root filesystem ve systemd kullanıcı alanının aslında açılabildiğini gösteriyor.

### 2. Aynı Ro-installed sistemde Fedora stock kernel nouveau ile çalışıyor

Dosya:

```text
gerçeksistemdenloglar/ro-kernel-debug-stock-fedora-kernel.txt
```

Kanıt:

```text
UNAME:
Linux ro-asd 6.19.14-200.fc43.x86_64

PCI:
09:00.0 VGA compatible controller: NVIDIA GA102 [GeForce RTX 3090]
Kernel driver in use: nouveau

kernel log:
nouveau 0000:09:00.0: gsp: RM version: 570.144
[drm] Initialized nouveau 1.4.1 for 0000:09:00.0 on minor 0
```

Yorum:

Aynı kullanıcı alanı, aynı firmware paketi, aynı Mesa/libdrm seti ve aynı Ro-installed sistem üzerinde Fedora stock kernel `nouveau` ile çalışıyor. Bu çok güçlü bir karşılaştırma noktasıdır.

### 3. Paket seti custom ve stock bootta aynı

Custom Ro kernel ve Fedora stock kernel loglarında şu paketler aynı sistemde aynı sürümlerde:

```text
linux-firmware-20260410-1.fc43
libdrm-2.4.131-1.fc43
mesa-25.3.6-3.fc43
dracut-107-8.fc43
systemd-258.7-1.fc43
```

Yorum:

Bu yüzden problem "Ro installer eksik firmware kurmuş" gibi görünmüyor. Aynı firmware ile stock kernel RTX 3090 üzerinde GSP RM yükleyip nouveau'yu başlatıyor.

### 4. Official Fedora referans logu aynı donanım değil

Dosya:

```text
gerçeksistemdenloglar/ro-kernel-debug-official-fedora-custom-kernel.txt
```

Kanıt:

```text
PCI:
01:00.0 VGA compatible controller: NVIDIA AD107M [GeForce RTX 4060 Max-Q / Mobile]

kernel log:
nouveau 0000:01:00.0: gsp: Failed to load required firmware for device.
nouveau 0000:01:00.0: gsp ctor failed: -2
nouveau 0000:01:00.0: probe with driver nouveau failed with error -2
```

Yorum:

Bu log, RTX 3090 problem makinesiyle aynı donanım değil. Üstelik burada nouveau başarıyla bağlanmamış; probe firmware eksikliğiyle düşmüş. Bu sistemin "açılması", custom kernelin nouveau KMS yolunun sağlam olduğunu kanıtlamıyor. Aksine burada gerçek NVIDIA KMS devreye girmeden simpledrm/fallback ile devam edilmiş olabilir.

## Bulunan Sıkıntılar

### Sıkıntı 1: Custom kernelin nouveau/KMS yolu RTX 3090'da şüpheli

Etkilenen sistem:

```text
NVIDIA GA102 [GeForce RTX 3090] [10de:2204]
ro-kernel-stable 6.19.13-103.fc43.ro_stable.x86_64
```

Belirti:

```text
nomodeset olmadan Plymouth sonrası siyah ekran
Ctrl+Alt+F3 yok
nomodeset ile sistem açılıyor
```

Yorum:

Bu, kernelin GPU'ya mode-setting yaptırdığı anda ekranın veya DRM state'in bozulduğunu düşündürüyor. Fedora stock kernel aynı kartta nouveau ile çalıştığı için fark büyük ihtimalle:

- Ro kernel config farkı
- Fedora kernel patch setinden eksik parça
- Nouveau/GSP davranışı
- Ro kernel 6.19.13 ile Fedora kernel 6.19.14 arasındaki upstream fark
- Kernel paketinin module metadata/initramfs üretim farkı

### Sıkıntı 2: Custom BLS girdisine ekstra nouveau parametreleri yazılmış

Ro-installed sistemde custom kernel BLS girdisinde şu fazladan parametreler var:

```text
nouveau.config=NvGspRm=1 nouveau.noaccel=1
```

Bu parametreler repo içinde installer tarafından yazılmıyor. Kaynağı şu an belirsiz:

- manuel `grubby` denemesi olabilir
- COPR kernel paketinin scriptlet'i olabilir
- daha önceki testlerden kalmış olabilir

Bu parametreler temizlenmeden yapılan test "stock Fedora ayarlarıyla custom kernel" testi değildir.

Önce temiz test yapılmalı.

### Sıkıntı 3: Official Fedora karşılaştırması aynı makine olmadığı için kesin kanıt değil

Official Fedora logundaki GPU:

```text
NVIDIA AD107M RTX 4060 Mobile
```

Ro-installed problem makinesindeki GPU:

```text
NVIDIA GA102 RTX 3090
```

Bu yüzden "custom kernel official Fedora'da çalışıyor" iddiası bu log setiyle problem makinesine doğrudan taşınamaz. Aynı kernelin aynı RTX 3090 makinede official Fedora kurulumunda denenmesi daha güçlü kanıt olur.

### Sıkıntı 4: Official Fedora referansında nouveau aslında başarılı çalışmamış

Official Fedora custom kernel logunda:

```text
gsp: Failed to load required firmware for device
probe with driver nouveau failed with error -2
```

Bu önemli. Sistem açılmış olabilir ama nouveau KMS başarıyla çalışmamış. Yani bu referans "custom kernel nouveau ile sorunsuz" demiyor.

### Sıkıntı 5: Installer doğrulaması KMS açısından zayıf

Installer şu an şunları doğruluyor:

- `/etc/kernel/cmdline` var mı
- Btrfs için `rootflags=subvol=@` var mı
- live ISO parametreleri BLS içine sızmış mı

Ama şu alanları doğrulamıyor:

- BLS içinde beklenmeyen GPU argümanları var mı
- `nouveau.config`, `nouveau.noaccel`, `nomodeset` gibi parametreler custom kernel girdisine sızmış mı
- `/etc/modprobe.d` içinde ekran kartı için beklenmeyen blacklist var mı
- custom kernel initramfs içinde firmware/nouveau modülleri beklenen şekilde var mı
- installed sistemde live-only grafik workaround kalıntısı kalmış mı

Bu ana suçlu olmayabilir ama installer kalite açığıdır.

### Sıkıntı 6: Kernel protected policy yanlış kanalı koruyor

Ro-installed sistemde `/etc/dnf/protected.d/ro-kernel.conf` içinde şunlar var:

```text
ro-kernel-experimental-core
ro-kernel-experimental-modules
ro-kernel-experimental-devel
```

Ama sistemde kurulu paket:

```text
ro-kernel-stable-core
ro-kernel-stable-modules
ro-kernel-stable-devel
```

Bu siyah ekranın sebebi değil, ama kernel paket politikası açısından tutarsızlık. Stable kernel kuruluyorsa stable paket adları da protected dosyasına yazılmalı.

## Temiz İzolasyon Planı

### Aşama 1: Custom kernel BLS parametrelerini temizle

Ro-installed sistemde Fedora stock kernel veya custom kernel `nomodeset` ile açıldıktan sonra:

```bash
sudo grubby --update-kernel=/boot/vmlinuz-6.19.13-103.fc43.ro_stable.x86_64 --remove-args='nouveau.config=NvGspRm=1 nouveau.noaccel=1 nomodeset plymouth.enable=0'
sudo grubby --info=/boot/vmlinuz-6.19.13-103.fc43.ro_stable.x86_64
```

Sonra custom kernel normal boot denenmeli.

Beklenen yorum:

- Açılırsa: sorun büyük ihtimalle ekstra nouveau argümanları.
- Siyah ekranda kalırsa: sorun custom kernelin nouveau/KMS yolunda.

### Aşama 2: Failed boot journal alın

Custom kernel normal boot ile siyah ekranda kaldıktan sonra reset atıp stock kernel ile açın:

```bash
sudo journalctl --list-boots
sudo journalctl -b -1 -k --no-pager | grep -Ei 'nouveau|drm|kms|gsp|firmware|fb|framebuffer|simpledrm|nvidia|gpu|vga|panic|oops|hung|timeout|failed' | tee /tmp/ro-kernel-failed-boot-kmsg.txt
sudo journalctl -b -1 -p warning..alert --no-pager | tee /tmp/ro-kernel-failed-boot-warnings.txt
```

Bu iki dosya en kritik kanıt olacak.

### Aşama 3: Nouveau'yu özel olarak devre dışı bırak

Custom kernelde `nomodeset` yerine sadece nouveau blacklist test edilmeli:

```text
rd.driver.blacklist=nouveau modprobe.blacklist=nouveau
```

Yorum:

- Böyle açılırsa: sorun neredeyse kesin nouveau.
- Böyle de açılmazsa: genel DRM/simpledrm/framebuffer tarafına bakılır.

### Aşama 4: GSP davranışını değiştirerek test et

Custom kernelde temiz argümanlarla bir de şu denenmeli:

```text
nouveau.config=NvGspRm=0
```

Yorum:

- Açılırsa: problem Ro kernel + nouveau GSP yolunda.
- Açılmazsa: genel nouveau modeset veya DRM config/patch farkı.

### Aşama 5: Kernel config farkını çıkar

Aynı Ro-installed sistemde:

```bash
sudo bash -c '
OUT=/tmp/ro-kernel-config-diff.txt
{
echo "===== CUSTOM CONFIG ====="
grep -E "CONFIG_DRM|CONFIG_NOUVEAU|CONFIG_FB_|CONFIG_FRAMEBUFFER|CONFIG_FW_LOADER|CONFIG_FIRMWARE|CONFIG_PCI|CONFIG_IOMMU|CONFIG_ACPI|CONFIG_DRM_PANIC|CONFIG_DRM_CLIENT|CONFIG_DRM_KMS" /boot/config-6.19.13-103.fc43.ro_stable.x86_64 2>&1

echo
echo "===== FEDORA STOCK CONFIG ====="
grep -E "CONFIG_DRM|CONFIG_NOUVEAU|CONFIG_FB_|CONFIG_FRAMEBUFFER|CONFIG_FW_LOADER|CONFIG_FIRMWARE|CONFIG_PCI|CONFIG_IOMMU|CONFIG_ACPI|CONFIG_DRM_PANIC|CONFIG_DRM_CLIENT|CONFIG_DRM_KMS" /boot/config-6.19.14-200.fc43.x86_64 2>&1

echo
echo "===== DIFF ====="
diff -u /boot/config-6.19.14-200.fc43.x86_64 /boot/config-6.19.13-103.fc43.ro_stable.x86_64 | grep -E "^[+-](CONFIG_DRM|CONFIG_NOUVEAU|CONFIG_FB_|CONFIG_FRAMEBUFFER|CONFIG_FW_LOADER|CONFIG_FIRMWARE|CONFIG_PCI|CONFIG_IOMMU|CONFIG_ACPI|CONFIG_DRM_PANIC|CONFIG_DRM_CLIENT|CONFIG_DRM_KMS)" || true
} | tee "$OUT"
echo "Saved to $OUT"
'
```

### Aşama 6: Kernel package scriptlet ve parametre kaynağını bul

```bash
sudo bash -c '
OUT=/tmp/ro-kernel-param-origin.txt
{
echo "===== SEARCH PARAMS ====="
grep -RInE "NvGspRm|nouveau.noaccel|nouveau.config|nomodeset" /etc /boot /usr/lib/kernel /usr/lib/kernel/install.d 2>/dev/null || true

echo
echo "===== RPM SCRIPTS ====="
rpm -q --scripts ro-kernel-stable-core ro-kernel-stable-modules ro-kernel-stable-devel 2>&1

echo
echo "===== GRUBBY CUSTOM ====="
grubby --info=/boot/vmlinuz-6.19.13-103.fc43.ro_stable.x86_64 2>&1
} | tee "$OUT"
echo "Saved to $OUT"
'
```

## Düzeltme Planı

### Kernel/COPR tarafı

1. Ro kernel config'i Fedora stock kernel config'ine DRM/Nouveau/FW_LOADER/framebuffer tarafında yaklaştır.
2. Özellikle RTX 30/40 serisi için nouveau GSP davranışını Fedora kernel ile karşılaştır.
3. Ro kernel 6.19.13 yerine Fedora'nın çalışan 6.19.14-200 tabanına veya aynı patch seviyesine rebase etmeyi dene.
4. `modules.order`, `modules.builtin`, `modules.builtin.modinfo` gibi metadata dosyalarının kernel RPM içinde doğru üretildiğini doğrula.
5. COPR paket scriptlet'leri BLS içine vendor-specific argüman yazıyorsa kaldır.
6. NVIDIA nouveau KMS test matrisi oluştur:
   - GA102 RTX 3090
   - AD107/RTX 4060
   - Intel iGPU
   - AMDGPU
   - QEMU virtio

### Installer tarafı

1. Post-install validation'a BLS GPU argümanı kontrolü ekle:
   - `nomodeset`
   - `nouveau.noaccel`
   - `nouveau.config`
   - `nouveau.modeset=0`
   - `modprobe.blacklist=nouveau`
   - `rd.driver.blacklist=nouveau`
2. Bu argümanlar sadece explicit safe graphics/debug entry içinde kabul edilmeli, normal kurulu sistem kernel girdisinde olmamalı.
3. Stable kernel kuruluyorsa `/etc/dnf/protected.d/ro-kernel.conf` stable paket adlarını da içermeli:
   - `ro-kernel-stable-core`
   - `ro-kernel-stable-modules`
   - `ro-kernel-stable-devel`
   - varsa `ro-kernel-stable-headers`
4. Install artifact collector'a şu çıktılar eklenmeli:
   - `/boot/loader/entries/*.conf`
   - `/boot/config-*`
   - `modinfo -p nouveau`
   - `lsinitrd /boot/initramfs-*.img | grep -Ei 'nouveau|firmware|gsp|nvidia'`
5. Installer custom kernel kursa bile Fedora stock kernel varsayılan kalmalı. Bu davranış şu an doğru yönde.

## Şu Anki Karar

Bu loglarla "asıl suçlu installer" demek doğru değil.

En kuvvetli teknik sonuç:

```text
Problemli makinede custom Ro kernel, NVIDIA GA102 RTX 3090 üzerinde nouveau KMS/GSP yolunda kırılıyor.
```

Installer tarafında bulunanlar ana sebep değil; daha çok koruma/doğrulama eksikleri.
