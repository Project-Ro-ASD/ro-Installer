import 'dart:ffi' as ffi;
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

// C++ callback types
typedef ProgressCallbackC = ffi.Void Function(ffi.Double, ffi.Pointer<Utf8>);
// ignore: unused_element
typedef StartInstallationC = ffi.Void Function(ffi.Pointer<ffi.NativeFunction<ProgressCallbackC>>);
// ignore: unused_element
typedef StartInstallationDart = void Function(ffi.Pointer<ffi.NativeFunction<ProgressCallbackC>>);

// Test ping
typedef TestConnectionC = ffi.Int32 Function();
typedef TestConnectionDart = int Function();

// Get Disks
typedef GetDisksJsonC = ffi.Pointer<Utf8> Function();
typedef GetDisksJsonDart = ffi.Pointer<Utf8> Function();

// Format
typedef FormatPartitionC = ffi.Bool Function(ffi.Pointer<Utf8>, ffi.Pointer<Utf8>);
typedef FormatPartitionDart = bool Function(ffi.Pointer<Utf8>, ffi.Pointer<Utf8>);

// Shrink
typedef ShrinkPartitionC = ffi.Bool Function(ffi.Pointer<Utf8>, ffi.Pointer<Utf8>);
typedef ShrinkPartitionDart = bool Function(ffi.Pointer<Utf8>, ffi.Pointer<Utf8>);

// Extract
typedef ExtractSystemC = ffi.Bool Function(ffi.Pointer<Utf8>, ffi.Pointer<Utf8>);
typedef ExtractSystemDart = bool Function(ffi.Pointer<Utf8>, ffi.Pointer<Utf8>);

// Init
typedef InitializeBackendC = ffi.Bool Function(ffi.Pointer<Utf8>);
typedef InitializeBackendDart = bool Function(ffi.Pointer<Utf8>);

// Chroot
typedef RunInChrootC = ffi.Bool Function(ffi.Pointer<Utf8>, ffi.Pointer<Utf8>);
typedef RunInChrootDart = bool Function(ffi.Pointer<Utf8>, ffi.Pointer<Utf8>);

class BackendBindings {
  static final BackendBindings _instance = BackendBindings._internal();
  factory BackendBindings() => _instance;

  static bool isMockEnabled = true; // Simülasyona zorlar
  
  late ffi.DynamicLibrary nativeLib;
  late TestConnectionDart _testConnection;
  late GetDisksJsonDart _getDisksJson;
  late InitializeBackendDart _initializeBackend;
  late StartInstallationDart _startInstallation;
  late FormatPartitionDart _formatPartition;
  late ShrinkPartitionDart _shrinkPartition;
  late ExtractSystemDart _extractSystem;
  late RunInChrootDart _runInChroot;

  BackendBindings._internal() {
    _loadLibrary();
  }

  void _loadLibrary() {
    if (Platform.isLinux) {
      try {
        nativeLib = ffi.DynamicLibrary.open('libro_backend.so');
      } catch (e) {
        debugPrint("[FFI ERROR] libro_backend.so cannot be loaded. Check build folders.");
        nativeLib = ffi.DynamicLibrary.process();
      }
    } else {
      nativeLib = ffi.DynamicLibrary.process();
    }

    try {
      _testConnection = nativeLib.lookupFunction<TestConnectionC, TestConnectionDart>('test_ffi_connection');
      _getDisksJson = nativeLib.lookupFunction<GetDisksJsonC, GetDisksJsonDart>('get_disks_json');
      _initializeBackend = nativeLib.lookupFunction<InitializeBackendC, InitializeBackendDart>('initialize_backend');
      // progress callback thread dart ffi izolation sorunu sebebiyle gorsel simulasyona devam edecek
      _startInstallation = nativeLib.lookupFunction<StartInstallationC, StartInstallationDart>('start_installation');

      _formatPartition = nativeLib.lookupFunction<FormatPartitionC, FormatPartitionDart>('format_partition');
      _shrinkPartition = nativeLib.lookupFunction<ShrinkPartitionC, ShrinkPartitionDart>('shrink_partition');
      _extractSystem = nativeLib.lookupFunction<ExtractSystemC, ExtractSystemDart>('extract_system');
      _runInChroot = nativeLib.lookupFunction<RunInChrootC, RunInChrootDart>('run_in_chroot');
    } catch(e) {
       debugPrint("[FFI ERROR] Function bindings failed: $e. Using mocks.");
    }
  }

  int testConnection() {
    try {
      return _testConnection();
    } catch (e) {
      return 0;
    }
  }

  Future<String> getDisks() async {
    if (isMockEnabled) {
       return '[{"name": "/dev/sda", "size": "500GB", "fs": "ext4", "free": "120GB"}, {"name": "/dev/nvme0n1", "size": "1TB", "fs": "btrfs", "free": "300GB"}]';
    }
    debugPrint("[FFI] Gercek get_disks() cagirildi.");
    try {
      final pointer = _getDisksJson();
      return pointer.toDartString();
    } catch (e) {
      return '[{"name": "/dev/sda", "size": "500GB", "fs": "ext4", "free": "120GB"}, {"name": "/dev/nvme0n1", "size": "1TB", "fs": "btrfs", "free": "300GB"}]'; // Fallback
    }
  }

  Future<bool> setFormatConfig(String configJson) async {
    if (isMockEnabled) return true;
    debugPrint("[FFI] Gercek initialize_backend() cagirildi: $configJson");
    try {
      final pointer = configJson.toNativeUtf8();
      final result = _initializeBackend(pointer);
      calloc.free(pointer);
      return result;
    } catch (e) {
      return true; // Fallback
    }
  }

  Future<bool> shrinkPartition(String disk, String sizeEnd) async {
      if (isMockEnabled) return true;
      try {
// ... (rest remains same but within check)
          final diskPtr = disk.toNativeUtf8();
          final sizePtr = sizeEnd.toNativeUtf8();
          final r = _shrinkPartition(diskPtr, sizePtr);
          calloc.free(diskPtr); calloc.free(sizePtr);
          return r;
      } catch (e) {
          return false;
      }
  }

  Future<bool> formatPartition(String partition, String fsType) async {
       if (isMockEnabled) return true;
       try {
          final partPtr = partition.toNativeUtf8();
          final fsPtr = fsType.toNativeUtf8();
          final r = _formatPartition(partPtr, fsPtr);
          calloc.free(partPtr); calloc.free(fsPtr);
          return r;
      } catch (e) {
          return false;
      }
  }

  Future<bool> runInChroot(String partition, String cmd) async {
       if (isMockEnabled) return true;
       try {
          final partPtr = partition.toNativeUtf8();
          final cmdPtr = cmd.toNativeUtf8();
          final r = _runInChroot(partPtr, cmdPtr);
          calloc.free(partPtr); calloc.free(cmdPtr);
          return r;
      } catch (e) {
          return false;
      }
  }

  Future<bool> extractSystem(String partition, String imagePath) async {
       if (isMockEnabled) return true;
       try {
          final partPtr = partition.toNativeUtf8();
          final imgPtr = imagePath.toNativeUtf8();
          final r = _extractSystem(partPtr, imgPtr);
          calloc.free(partPtr); calloc.free(imgPtr);
          return r;
      } catch (e) {
          return false;
      }
  }

  Future<void> startInstallation(Function(double progress, String status) onProgress) async {
    debugPrint("[FFI] gercek startInstallation() cagirildi. C++ Thread Dart isolatine async is basamadi icin mock donduruluyor.");
    
    final steps = [
      "Disk formatlanıyor (KPMCore)...",
      "Dosyalar kopyalanıyor (unsquashfs)...",
      "Kullanıcı oluşturuluyor...",
      "Bootloader (rEFInd) yapılandırılıyor...",
      "Kurulum tamamlandı."
    ];

    for (int i = 0; i < steps.length; i++) {
      await Future.delayed(const Duration(seconds: 2));
      onProgress((i + 1) / steps.length, steps[i]);
    }
  }
}
