import 'dart:convert';
import 'dart:io';

class DiskService {
  DiskService._();
  static final DiskService instance = DiskService._();

  Future<List<Map<String, dynamic>>> getDisks() async {
    List<Map<String, dynamic>> diskList = [];
    
    // Güvenli Sanal Test Diski (Talebin üzerine eklenmiştir)
    diskList.add({
      'name': '/dev/RoASD_Safe_Disk',
      'model': 'Virtual Safe Test Drive',
      'size': 120 * 1024 * 1024 * 1024, // 120 GB in bytes
      'type': 'disk',
      'isLive': false,
      'isSafe': true,
    });

    try {
      final result = await Process.run('lsblk', ['-J', '-b', '-o', 'NAME,MODEL,SIZE,TYPE,RM,MOUNTPOINTS']);
      if (result.exitCode == 0) {
        final Map<String, dynamic> parsed = jsonDecode(result.stdout.toString());
        if (parsed.containsKey('blockdevices')) {
          final devices = parsed['blockdevices'] as List<dynamic>;
          
          for (var d in devices) {
            // Sadece type == 'disk' leri al. zram veya rom ları hariç tut.
            if (d['type'] != 'disk') continue;
            final name = d['name'].toString();
            if (name.startsWith('zram') || name.startsWith('loop') || name.startsWith('sr')) continue;

            bool isLive = false;
            if (d['rm'] == true) {
              // Removable olanları Live OS olabilme ihtimaline karşı işaretle
              isLive = true; 
            }

            // Cihazın alt bölümlerinde (partition) / veya /boot monte mi? 
            bool hasCriticalMount = false;
            if (d.containsKey('children')) {
               for (var child in (d['children'] as List<dynamic>)) {
                  if (child.containsKey('mountpoints') && child['mountpoints'] != null) {
                     for (var mp in (child['mountpoints'] as List<dynamic>)) {
                        if (mp == '/' || mp == '/boot' || mp.toString().contains('/run/initramfs') || mp.toString().contains('/live')) {
                           hasCriticalMount = true;
                           isLive = true;
                        }
                     }
                  }
               }
            }
            
            diskList.add({
              'name': '/dev/$name',
              'model': d['model'] ?? 'Unknown Drive',
              'size': d['size'] ?? 0,
              'type': d['type'] ?? 'disk',
              'isLive': isLive || hasCriticalMount,
              'isSafe': false,
            });
          }
        }
      }
    } catch (e) {
      // Eğer komut çökeryse (örneğin windows ortamında), listede en azından Safe Disk kalacak.
    }

    return diskList;
  }
}
