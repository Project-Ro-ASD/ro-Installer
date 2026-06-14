#!/bin/bash
# =============================================================
# Ro-ASD İşletim Sistemi Yükleyici — Başlatıcı Script
# =============================================================
# Bu script uygulamayı pkexec aracılığıyla root yetkisiyle
# başlatır. .desktop dosyasının Exec= satırı bu scripti çağırır.
# =============================================================

BINARY="/usr/bin/ro-installer"

# Binary var mı kontrol et
if [ ! -f "$BINARY" ]; then
    zenity --error \
        --title="Ro-Installer Bulunamadı" \
        --text="Ro-ASD Yükleyici bulunamadı.\n\nBeklenen konum: $BINARY\n\nRPM paketi düzgün kurulmamış olabilir." \
        2>/dev/null || \
    notify-send "Ro-Installer Bulunamadı" "$BINARY yolu bulunamadı." 2>/dev/null
    exit 1
fi

# Zaten root isek doğrudan başlat (Live ISO otomatik root oturumlarında)
if [ "$(id -u)" -eq 0 ]; then
    exec "$BINARY" "$@"
fi

# Root değilsek — pkexec ile yükselt
# Not: pkexec ortam değişkenlerini DISPLAY ve XAUTHORITY dahil korur
exec pkexec --disable-internal-agent "$BINARY" "$@"
