/// Standard full-disk layout. Ro-Compose owns the prepared system's ZRAM policy.
class StandardStorageLayout {
  const StandardStorageLayout._();

  static const int espBytes = 512 * 1024 * 1024;

  // Temporary safety floor inherited from the previous root-space guard.
  // Prepared-root size is not yet exposed reliably. This is NOT the final
  // Ro-ASD product minimum; replace it with measured deployment requirements.
  static const int temporaryMinimumRootBytes = 40 * 1024 * 1024 * 1024;
  static const int minimumDiskBytes =
      espBytes + temporaryMinimumRootBytes + 2 * 1024 * 1024;

  static const Map<String, String> subvolumes = {
    'root': '/',
    'home': '/home',
    'var_log': '/var/log',
    'var_cache': '/var/cache',
    'var_tmp': '/var/tmp',
  };

  static String mountOptions(String subvolume) =>
      'compress=zstd:1,subvol=$subvolume';
}
