# Git Yukleme Notu

Bu repo icin GitHub'a yuklenmesi gereken ana gruplar:

- Flutter kaynak kodu: `lib/`
- Linux paket/runner dosyalari: `linux/`
- Uygulama assetleri ve ceviriler: `assets/images/`, `assets/i18n/`
- Testler ve fixture'lar: `test/`
- Build/release scriptleri: `scripts/`
- Paketleme ve proje dosyalari: `pubspec.yaml`, `pubspec.lock`, `ro-installer.spec`, `COPR.md`, `README.md`, `analysis_options.yaml`
- Proje hafiza ve teknik plan dokumanlari: `docs/` ve kok dizindeki plan/durum/test notlari

GitHub'a commit edilmemesi gereken yerel dosyalar:

- ISO/RPM/build artifactleri: `*.iso`, `*.rpm`, `iso-realese/`, `rpm-outputs/`, `outputs/`, `build/`
- Editor ve arac durumlari: `.idea/`, `.dart_tool/`, `.codex`, `.agents`, `__pycache__/`
- Ham gercek sistem loglari: `gerçeksistemdenloglar/*.txt`
- Generated tasarim export klasoru: `stitch_velvet_nebula_installer_redesign/`

Remote'da olup yerelde silinmis gorunen dosyalar ayrica karar gerektirir:

- `LICENSE`
- `.copr/Makefile`
- `assets/branding/roasd-logo.png`

Bu dosyalar silinecekse ayri commit ile silinmeli; normal kaynak kod yukleme commit'ine yanlislikla dahil edilmemeli.
