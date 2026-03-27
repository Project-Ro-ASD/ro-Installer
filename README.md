<div align="center">
  <img src="https://upload.wikimedia.org/wikipedia/commons/thumb/1/17/Penguin_icon.svg/200px-Penguin_icon.svg.png" width="80" alt="Ro-ASD Logo">
  <h1>Ro-Installer</h1>
  <p><b>The Official System Installer for Ro-ASD Operating System</b></p>
  
  [![Flutter](https://img.shields.io/badge/Flutter-02569B?style=flat-square&logo=flutter&logoColor=white)](https://flutter.dev)
  [![Platform](https://img.shields.io/badge/Platform-Linux-yellow?style=flat-square&logo=linux)](#)
  [![License](https://img.shields.io/badge/License-MIT-blue.svg?style=flat-square)](#)
</div>

<br>

*For the Turkish documentation, please scroll down. / Türkçe dokümantasyon için aşağı kaydırın.*

---

## 🇬🇧 English Documentation

### What is Ro-Installer?
**Ro-Installer** is the official, fast, and feature-rich graphical installation wizard built from the ground up specifically for the **Ro-ASD Operating System**. Developed entirely in Flutter, this installer bridges the gap between complex Linux backend commands and a seamless, user-friendly frontend experience.

Unlike traditional installers (like Calamares or Anaconda), Ro-Installer does not rely on heavy Python backends or complex Qt dependencies. Instead, it directly communicates with core Linux binaries (`sgdisk`, `mkfs.*`, `nmcli`, `rsync`, and `chroot`) asynchronously, providing real-time feedback with zero overhead.

### How it Works
The architecture of Ro-Installer is built on two primary layers:
1. **The UI Layer (Flutter):** Provides a reactive, state-driven (Provider) graphical interface supporting theming (Dark/Light mode) and dynamic routing based on user choices.
2. **The System Backend Layer (Dart FFI & Process):** Operates under `root` privileges. It parses hardware components like disks (`lsblk`) and networks (`nmcli`) securely. 

When the user initiates the installation, the `InstallService`:
- Translates the UI configuration into low-level shell commands.
- Configures partition tables (`sgdisk` / Manual or Auto).
- Formats volumes (optimized tightly for **BTRFS**, but supports `ext4`, `xfs`, and `fat32` for EFI).
- Mirrors the Live environment cleanly into the host disk using `rsync` with massive speed improvements.
- Handles user accounts, passwords (`useradd`, `chsh`), and installs the bootloader (`rEFInd`).

### How It Was Developed
Ro-Installer was developed with **Simplicity and Safety** in mind. 
- **Advanced Disk Validator:** During manual partitioning, if users miss crucial requirements (e.g., omitting the `/root` or `/boot/efi` directories, or having insufficient capacity), the system blocks the installation with clear, detailed explanations.
- **Smart Routing:** Depending on user expertise ("Standard" vs "Advanced" mode), the UI automatically hides/shows complex options like Kernel Selection (Stable vs. Experimental).
- **In-App Network Scanning:** Instead of relying on the host OS desktop environment, Ro-Installer manages network availability directly to download the latest Experimental Kernel features.

### Building & Running
You need Flutter SDK for Linux and root privileges.
```bash
# Clone the repository
git clone https://github.com/your-repo/ro-Installer.git
cd ro-Installer

# Resolve dependencies
flutter pub get

# Run on debug mode
flutter run -d linux

# Build the release binary
flutter build linux --release
```
*(To write directly to the host disks and utilize network services securely in production, run the compiled binary strictly with `sudo` or Polkit).*

<br>
<hr>
<br>

## 🇹🇷 Türkçe Dokümantasyon

### Ro-Installer Nedir?
**Ro-Installer**, doğrudan **Ro-ASD İşletim Sistemi** için sıfırdan inşa edilmiş resmi, hızlı ve bol özellikli grafiksel kurulum sihirbazıdır. Tamamen Flutter çerçevesinde geliştirilen bu yükleyici, karmaşık Linux çekirdek komutları ile kusursuz bir kullanıcı arayüzü (UI) arasındaki güçlü köprüyü oluşturur.

Geleneksel yükleyicilerin (Calamares veya Anaconda gibi) aksine, Ro-Installer hantal Python altyapılarına veya ağır Qt kütüphanelerine dayanmaz. Bunun yerine doğrudan temel Linux araçlarıyla (`sgdisk`, `mkfs.*`, `nmcli`, `rsync` ve `chroot`) asenkronize şekilde haberleşir; bu sayede performanstan hiçbir taviz vermeden anlık olarak geri bildirim (progress bar/log) yansıtır.

### Sistem Nasıl Çalışır?
Ro-Installer mimarisi iki ana katman üzerine kuruludur:
1. **Arayüz Katmanı (Flutter):** State Management (Provider) tarafından tetiklenen tepkisel bir deneyim sunar. Dark/Light mod temalarını ve kullanıcının adımlarına göre dinamik yapıyı oluşturur.
2. **Sistem ve Arka Plan Katmanı (Dart FFI & İşlemler):** `root` yetkileri altında çalışır. Diskleri (`lsblk`) ve Ağ donanımını (`nmcli`) güvenli bir şekilde tarar.

Kullanıcı "Kurulumu Başlat" butonuna tıkladığında `InstallService` devreye girer:
- Arayüzdeki planları en alt seviye BASH komutlarına çevirir.
- Disk yapılarını ve bölümleri inşa eder (Otomatik veya Manuel Atama).
- Diskleri biçimlendirir (**BTRFS** optimizasyonlu; `ext4`, `xfs`, EFI için `fat32` desteklenir).
- Çalışan Canlı (Live OS) ortamınızı sisteminize inanılmaz bir hızda klonlamak için `rsync` teknolojisini kullanır.
- Kullanıcı hesaplarını şifreler (`useradd`, `chroot`), zaman dilimini yazar ve sistem başlatıcıyı (`rEFInd` Bootloader) yapılandırır.

### Nasıl Geliştirildi?
Yazılım, kurulum esnasında **Güvenlik ve Sadelik** felsefesi temel alınarak geliştirildi.
- **İleri Düzey Disk Denetleyicisi (Validator):** Manuel disk bölümlemelerinde sistem yetenekleri en uç noktaya taşınmıştır. Kullanıcı yanlışlıkla EFI partisyonunu sildiğinde, kök dizine az boyut verdiğinde veya SWAP alanını unuttuğunda; yükleyici derhal devreye girer, işlemi iptal eder ve problemi anlatan net yönergeler sunar. Ayrıca mevcut Windows disklerinin veri kaybını önlemek adına sıkı uyarılara ve "Küçültme (Resize)" özelliklerine sahiptir.
- **Akıllı Yönlendirme:** Kullanıcı türüne göre ("Standart" veya "Gelişmiş" kurulum) arayüz şekil değiştirir. Normal kullanıcılara Kararlı (Stable) kernel atanıp kernel ekranı gizlenirken; profesyonel geliştiricilere kendi Kernel testlerini yapabilmeleri için imkân tanınır.

### Derleme ve Çalıştırma
Sistemi koddan derlemek için Linux Flutter SDK'sına ihtiyacınız vardır.
```bash
# Depoyu klonlayın
git clone https://github.com/your-repo/ro-Installer.git
cd ro-Installer

# Gereksinimleri indirin
flutter pub get

# Uygulamayı Linux üzerinde test edin
flutter run -d linux

# Derlenmiş Nihai (Release) Sürümü Çıkartın
flutter build linux --release
```
*(Yükleyicinin sistem disklerine kalıcı müdahale edebilmesi ve ağ profillerine ulaşabilmesi için, uygulamanın mutlaka `sudo` yetkileriyle yani root olarak başlatılması gerekmektedir).*
