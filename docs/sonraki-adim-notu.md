# Sonraki Adim Notu

Git temizligi ve GitHub senkronizasyonu bittikten sonra teknik siralama:

1. Repo GPG ve live sudo/polkit sertlestirmesi.
   - `gpgcheck=0` ve `repo_gpgcheck=0` stable blocker olarak kalacak.
   - Live ISO icindeki `NOPASSWD: ALL` daraltilacak.
2. LUKS stage uygulamasi.
   - `InstallProfile` encryption semasi hazir, ama `enabled=true` profiller stage destegi tamamlanana kadar bilincli olarak reddediliyor.
   - Ilk hedef: gelismis kurulumda opsiyonel LUKS2 root.
3. QEMU stable matrisi.
   - Full disk + reboot.
   - Free-space + reboot.
   - Alongside + reboot.
   - LUKS full disk + reboot.
