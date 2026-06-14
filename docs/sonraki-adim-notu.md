# Sonraki Adim Notu

Git temizligi ve GitHub senkronizasyonu sonrasi teknik siralama:

1. Tamamlandi: Repo GPG ve live sudo/polkit sertlestirmesi.
   - Ro GitHub repo dosyalari `gpgcheck=1`, `repo_gpgcheck=1` ve `RPM-GPG-KEY-ro-asd` ile yaziliyor.
   - COPR depolarinda RPM imzasi (`gpgcheck=1`) zorunlu; COPR metadata imzasi yayinlamadigi icin `repo_gpgcheck=0` pratik istisna olarak kaliyor.
   - Live ISO icindeki `NOPASSWD: ALL` kaldirildi; otomatik baslatma dar polkit kuralindan `pkexec` launcher'a gidiyor.
   - Kurulu sistem dogrulamasi, live polkit/sudoers/installer kalintisi sizarsa kurulumu basarisiz sayiyor.
   - Dis blocker: 2026-06-15 kontrolunde `RPM-GPG-KEY-ro-asd`, `x86_64/repodata/repomd.xml.asc` ve `noarch/repodata/repomd.xml.asc` GitHub Pages uzerinde 404 donuyor. Bu dosyalar Ro-Repo tarafinda yayinlanmadan yeni guvenli repo ayari bilincli olarak build/install akisini durdurur.
2. Siradaki is: LUKS stage uygulamasi.
   - `InstallProfile` encryption semasi hazir, ama `enabled=true` profiller stage destegi tamamlanana kadar bilincli olarak reddediliyor.
   - Ilk hedef: gelismis kurulumda opsiyonel LUKS2 root.
3. QEMU stable matrisi.
   - Full disk + reboot.
   - Free-space + reboot.
   - Alongside + reboot.
   - LUKS full disk + reboot.
