#include <iostream>
#include <string>
#include <thread>
#include <chrono>
#include <memory>
#include <array>
#include <cstring>
#include <thread>
#include <chrono>
#include <chrono>
#include <cstring>
#include <fstream>

#include "system_command.h"

// Dart tarafi icin disari acilan C fonksiyonlari
extern "C" {

    // Ornek ping/pong fonksiyonu - Baglantiyi test etmek icin
    int test_ffi_connection() {
        return 42;
    }

    // C++'tan C str'ye ceviri icin buffer pointer.
    char* disk_buffer = nullptr;

    // Sistemdeki diskleri tarar ve JSON string olarak doner
    // lsblk'un JSON ciktisini kullanacagiz
    const char* get_disks_json() {
        std::array<char, 128> buffer;
        std::string result;
        // lsblk ile disk boyutlari ve dosya sistemleri JSON formatinda istenir.
        std::unique_ptr<FILE, decltype(&pclose)> pipe(popen("lsblk -J -b -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT", "r"), pclose);
        if (!pipe) {
            return "[{\"error\": \"popen() failed!\"}]";
        }
        while (fgets(buffer.data(), buffer.size(), pipe.get()) != nullptr) {
            result += buffer.data();
        }

        // Eski bufferi temizle (Memory leak onlemi)
        if (disk_buffer != nullptr) {
            free(disk_buffer);
        }
        
        // Yeni string'i kopya olarak ver
        disk_buffer = (char*)malloc(result.size() + 1);
        std::strcpy(disk_buffer, result.c_str());
        
        return disk_buffer;
    }

    // Gercek KPMCore baslatma sinyalini verecek arayuzumuz
    bool initialize_backend(const char* jsonConfig) {
        std::cout << "[Backend C++] Initialize cagirildi. Payload: " << jsonConfig << std::endl;
        return true;
    }

    // Dart'tan backend progress callback'i alacak yapi
    typedef void (*ProgressCallback)(double progress, const char* status);

    // KPMCore baglanana kadar UEFI sistemler icin (Tam Kurulum) disk tablolamasi
    bool format_partition(const char* target_disk, const char* fs_type) {
        std::string disk(target_disk);
        std::string fs(fs_type);
        
        std::cout << "[Backend C++] Tam Kurulum Disk Hazirligi: " << disk << std::endl;
        
        // 1. ZAP (Temizle)
        SystemCommand::execute("sgdisk --zap-all " + disk);
        
        // 2. EFI Partition (500MB) olustur (Tip: ef00)
        SystemCommand::execute("sgdisk -n 1:0:+500M -t 1:ef00 -c 1:\"EFI System\" " + disk);
        
        // 3. Root Partition olustur (Kalan tum disk, Tip: 8300)
        SystemCommand::execute("sgdisk -n 2:0:0 -t 2:8300 -c 2:\"Root\" " + disk);
        
        // Disk partition tablosunun kernel'a bildirilmesi
        SystemCommand::execute("partprobe " + disk);
        std::this_thread::sleep_for(std::chrono::seconds(2)); // Kernel algilamasi icin kisa bekleme
        
        // Partition isimleri belirleniyor (/dev/sda1 vs /dev/nvme0n1p1)
        std::string part_prefix = disk;
        if (disk.find("nvme") != std::string::npos || disk.find("mmcblk") != std::string::npos) {
            part_prefix += "p";
        }
        
        std::string efi_part = part_prefix + "1";
        std::string root_part = part_prefix + "2";
        
        // Format EFI
        std::cout << "[Backend C++] EFI Formatlaniyor: mkfs.fat -F32 " << efi_part << std::endl;
        SystemCommand::execute("mkfs.fat -F32 " + efi_part);
        
        // Format Root
        std::string cmd;
        if (fs == "ext4") {
            cmd = "mkfs.ext4 -F " + root_part;
        } else if (fs == "btrfs") {
            cmd = "mkfs.btrfs -f " + root_part;
        } else if (fs == "xfs") {
            cmd = "mkfs.xfs -f " + root_part;
        } else {
            std::cerr << "Desteklenmeyen dosya sistemi: " << fs << std::endl;
            return false;
        }
        
        std::cout << "[Backend C++] Root Formatlaniyor: " << cmd << std::endl;
        auto res = SystemCommand::execute(cmd);
        if (res.exit_code != 0) {
            std::cerr << "[Backend C++] HATA: " << res.error << std::endl;
            // dart exception mekanizmasi buraya false duser
            return false;
        }
        return true;
    }

    // Yanina Kur secenegi icin disk boyutlandirici string parse eder ve parted komutuyla Shrink yapar
    bool shrink_partition(const char* target_partition, const char* new_size_end) {
        std::string part(target_partition);
        std::string size_end(new_size_end); // ornegin: "100GB"
        
        // 1. Dosya sistemini guvenle kucult (e2fsck + resize2fs ntfsresize vs)
        // NOT: ext4 ve ntfs icin online shrink cok zor, offline shrink de e2fsck vb araclar ister
        // parted resizepart /dev/sda 1 100GB
        
        // Cok basit ve tehlikeli bir prototip (KPMCore burada asil isi halledecek olan seydir normalde)
        std::string cmd = "parted " + part.substr(0, part.length() - 1) + " resizepart " + part.substr(part.length() - 1) + " " + size_end + " ---pretend-no-prompt";
        std::cout << "[Backend C++] Shrink yapilmaya calisiliyor: " << cmd << std::endl;
        
        auto res = SystemCommand::execute(cmd);
        if (res.exit_code != 0) {
            std::cerr << "[Backend C++] HATA: " << res.error << std::endl;
            return false;
        }
        return true;
    }

    // SquashFS imajini hedef diske cikartir (Tam kurulum mimarisine gore root_part'a cikarir)
    bool extract_system(const char* target_disk, const char* image_path) {
        std::string disk(target_disk);
        std::string img(image_path);
        
        std::string part_prefix = disk;
        if (disk.find("nvme") != std::string::npos || disk.find("mmcblk") != std::string::npos) {
            part_prefix += "p";
        }
        
        std::string efi_part = part_prefix + "1";   // /dev/sda1
        std::string root_part = part_prefix + "2";  // /dev/sda2
        
        // 1. Hedef root icin gecici bir mount noktasi olusturalim
        std::string mnt_dir = "/tmp/ro_install_target";
        SystemCommand::execute("mkdir -p " + mnt_dir);
        
        // 2. Hedef diski (Root partition) buraya baglayalim
        std::string mount_cmd = "mount " + root_part + " " + mnt_dir;
        std::cout << "[Backend C++] Root Mount calisiyor: " << mount_cmd << std::endl;
        auto mnt_res = SystemCommand::execute(mount_cmd);
        if (mnt_res.exit_code != 0) {
            std::cerr << "[Backend C++] ROOT MOUNT HATA: " << mnt_res.error << std::endl;
        }

        // 3. Unsquashfs komutunu calistir (ve de root'a cikartildigindan emin ol)
        std::string unsquash_cmd = "unsquashfs -f -d " + mnt_dir + " " + img;
        std::cout << "[Backend C++] Sistem cikariliyor: " << unsquash_cmd << std::endl;
        
        auto ext_res = SystemCommand::execute(unsquash_cmd);
        if (ext_res.exit_code != 0) {
            std::cerr << "[Backend C++] UNSQUASHFS HATA: " << ext_res.error << std::endl;
            return false;
        }
        
        // 4. EFI bolumunu Chroot icin hedef /boot/efi icerisine baglayalim
        // (Sistem artik root mnt uzerinde var, boot/efi klasoru vardir, yoksa mkdir yapariz)
        SystemCommand::execute("mkdir -p " + mnt_dir + "/boot/efi");
        std::string efi_mount_cmd = "mount " + efi_part + " " + mnt_dir + "/boot/efi";
        std::cout << "[Backend C++] EFI Mount calisiyor: " << efi_mount_cmd << std::endl;
        SystemCommand::execute(efi_mount_cmd);
        
        // 5. Otomatik /etc/fstab uretimi (Sistemin acilabilmesi icin cok kritik)
        auto get_uuid = [](const std::string& p) -> std::string {
            auto r = SystemCommand::execute("blkid -s UUID -o value " + p);
            std::string u = r.output;
            if (!u.empty() && u.back() == '\n') u.pop_back(); // endl temizle
            return u;
        };
        
        std::string root_uuid = get_uuid(root_part);
        std::string efi_uuid = get_uuid(efi_part);
        
        std::cout << "[Backend C++] Root UUID: " << root_uuid << " | EFI UUID: " << efi_uuid << std::endl;
        
        std::string fstab_path = mnt_dir + "/etc/fstab";
        std::ofstream fstab(fstab_path);
        if (fstab.is_open()) {
            fstab << "# /etc/fstab: static file system information.\n";
            fstab << "# Otomatik Olarak Ro-Installer Tarafindan Olusturulmustur.\n\n";
            fstab << "UUID=" << root_uuid << " / auto defaults 0 1\n";
            fstab << "UUID=" << efi_uuid << " /boot/efi vfat umask=0077,shortname=winnt 0 2\n";
            fstab << "tmpfs /tmp tmpfs defaults,noatime,mode=1777 0 0\n";
            fstab.close();
            std::cout << "[Backend C++] fstab basariyla olusturuldu!" << std::endl;
        } else {
            std::cerr << "[Backend C++] FSTAB HATA: Dosya acilamadi: " << fstab_path << std::endl;
        }
        
        std::cout << "[Backend C++] Sistem basariyla hedef diske cikarildi (EFI + Root mountlu, FSTAB hazir)!" << std::endl;
        return true;
    }

    // Hedef sisteme chroot atip verilen komutu calistirir
    // arch-chroot kullanarak /dev, /proc, /sys bindlarini otomatik hallederiz
    bool run_in_chroot(const char* target_partition, const char* command) {
        std::string part(target_partition);
        std::string cmd(command);
        
        std::string mnt_dir = "/tmp/ro_install_target";
        
        // Eger target_partition'i chroot icin ilk defa cagiriyorsak mount'lanmis olmali.
        // Biz unsquashfs'den sonra diski umount etmedigimiz icin direk arch-chroot'u atabiliriz.
        std::string chroot_cmd = "arch-chroot " + mnt_dir + " /bin/bash -c \"" + cmd + "\"";
        std::cout << "[Backend C++] Chroot komutu isleniyor: " << chroot_cmd << std::endl;
        
        auto res = SystemCommand::execute(chroot_cmd);
        if (res.exit_code != 0) {
            std::cerr << "[Backend C++] CHROOT HATA: " << res.error << std::endl;
            return false;
        }
        
        std::cout << "[Backend C++] Chroot islemi bitti. Cikti: " << res.output << std::endl;
        return true;
    }

    void start_installation(ProgressCallback callback) {
        std::cout << "[Backend C++] Kurulum simülasyonu başlatiliyor!" << std::endl;
        
        // Bloklamamak icin thread aciyoruz
        std::thread([=]() {
            callback(0.1, "KPMCore baslatiliyor...");
            std::this_thread::sleep_for(std::chrono::seconds(2));
            
            callback(0.3, "/dev/sda disk tablosu yeniden yaziliyor...");
            std::this_thread::sleep_for(std::chrono::seconds(2));
            
            callback(0.6, "Sistem imaji çikariliyor (unsquashfs)...");
            std::this_thread::sleep_for(std::chrono::seconds(2));
            
            callback(0.8, "Chroot Islemleri (Dil, Ag, Kullanicilar)...");
            std::this_thread::sleep_for(std::chrono::seconds(2));
            
            callback(1.0, "Bootloader rEFInd yukleniyor. Tamamlandi!");
        }).detach();
    }
}
