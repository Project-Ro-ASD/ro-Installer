import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/gpt_disk_snapshot.dart';
import '../models/manual_installation_plan.dart';
import '../services/helper_client.dart';
import '../state/installer_state.dart';
import 'nebula_ui.dart';

/// An editor for typed role selections; legacy partition maps are never read.
class ManualPlanEditor extends StatefulWidget {
  const ManualPlanEditor({
    super.key,
    required this.state,
    required this.helper,
    this.enabled = true,
  });
  final InstallerState state;
  final HelperClient helper;
  final bool enabled;
  @override
  State<ManualPlanEditor> createState() => _ManualPlanEditorState();
}

class _ManualPlanEditorState extends State<ManualPlanEditor> {
  GptDiskSnapshot? _snapshot;
  int? _revision;
  bool _loading = false, _invalid = false, _formatEsp = false;
  final _selected = <String, String?>{'esp': null, 'root': null};
  final _start = {
    'esp': TextEditingController(),
    'root': TextEditingController(),
  };
  final _size = {
    'esp': TextEditingController(),
    'root': TextEditingController(),
  };
  InstallerState get state => widget.state;
  bool get _current =>
      _snapshot != null && _revision == state.diskSelectionRevision;
  @override
  void dispose() {
    for (final controller in [..._start.values, ..._size.values]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _scan() async {
    if (_loading || !widget.enabled || state.selectedDisk.isEmpty) return;
    state.clearConfirmation();
    state.notifyListeners();
    final revision = state.diskSelectionRevision, path = state.selectedDisk;
    setState(() {
      _loading = true;
      _snapshot = null;
      _invalid = false;
    });
    try {
      final snapshot = await widget.helper.probeFreeSpace(path);
      if (!mounted ||
          state.diskSelectionRevision != revision ||
          state.partitionMethod != 'manual' ||
          state.selectedDisk != path) {
        return;
      }
      // Even injected clients cannot substitute another disk's inventory.
      if (snapshot.device.path != path) {
        throw const HelperException('DEVICE_CHANGED');
      }
      _snapshot = snapshot;
      _revision = revision;
      _formatEsp = false;
      for (final role in ['esp', 'root']) {
        final options = _options(role);
        _selected[role] = options.isEmpty ? null : options.keys.first;
        _setRange(role);
      }
      _publish();
    } on HelperException catch (error) {
      if (mounted && state.diskSelectionRevision == revision) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${state.t('helper_error')} (${error.code})')),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  int get _sectorsPerMiB => 1048576 ~/ _snapshot!.logicalSectorBytes;
  Map<String, String> _options(String role) {
    final snapshot = _snapshot!;
    final options = <String, String>{};
    final type = role == 'esp'
        ? ManualInstallationPlan.espTypeGuid
        : ManualInstallationPlan.rootTypeGuid;
    final minMiB = role == 'esp' ? 512 : 40960;
    for (final p in snapshot.partitions) {
      if (p.typeGuid != type ||
          p.attributesHex != '0000000000000000' ||
          (p.endSector - p.startSector + 1) * snapshot.logicalSectorBytes <
              minMiB * 1048576) {
        continue;
      }
      final suffix = RegExp(r'[0-9]$').hasMatch(snapshot.device.path)
          ? 'p'
          : '';
      final size =
          ((p.endSector - p.startSector + 1) *
                  snapshot.logicalSectorBytes /
                  1048576)
              .toStringAsFixed(0);
      options['existing:${p.number}'] =
          '${snapshot.device.path}$suffix${p.number} · $size MiB';
    }
    for (var i = 0; i < snapshot.freeExtents.length; i++) {
      final gap = snapshot.freeExtents[i];
      final start = (gap.startSector + _sectorsPerMiB - 1) ~/ _sectorsPerMiB;
      final end = (gap.endSector + 1) ~/ _sectorsPerMiB;
      if (end - start < minMiB) continue;
      options['gap:$i'] = '${state.t('manual_new')} · $start–$end MiB';
    }
    return options;
  }

  void _setRange(String role) {
    final selected = _selected[role];
    if (selected == null || !selected.startsWith('gap:')) return;
    final gap = _snapshot!.freeExtents[int.parse(selected.split(':').last)];
    var start = (gap.startSector + _sectorsPerMiB - 1) ~/ _sectorsPerMiB;
    final end = (gap.endSector + 1) ~/ _sectorsPerMiB;
    if (role == 'root' && _selected['esp'] == selected) {
      final espStart = int.tryParse(_start['esp']!.text),
          espSize = int.tryParse(_size['esp']!.text);
      if (espStart != null && espSize != null) start = espStart + espSize;
    }
    _start[role]!.text = '$start';
    _size[role]!.text = '${role == 'esp' ? 512 : end - start}';
  }

  ManualPartitionChoice _choice(String role) {
    final selected = _selected[role];
    if (selected == null) throw const FormatException('Missing role');
    if (selected.startsWith('existing:')) {
      return ManualPartitionChoice.existing(
        number: int.parse(selected.split(':').last),
        formatOnInstall: role == 'root' || _formatEsp,
      );
    }
    final start = int.parse(_start[role]!.text),
        size = int.parse(_size[role]!.text);
    if (start < 0 ||
        size <= 0 ||
        start > maximumSnapshotBytes ~/ 1048576 ||
        size > maximumSnapshotBytes ~/ 1048576) {
      throw const FormatException('Invalid range');
    }
    return ManualPartitionChoice.create(
      startSector: start * _sectorsPerMiB,
      endSector: (start + size) * _sectorsPerMiB - 1,
    );
  }

  void _publish() {
    if (!_current || !widget.enabled || state.installationActive) return;
    try {
      final plan = ManualInstallationPlan.build(
        snapshot: _snapshot!,
        esp: _choice('esp'),
        root: _choice('root'),
      );
      if (!state.selectManualPlan(plan)) return;
      _invalid = false;
    } on FormatException {
      state.clearConfirmation();
      state.notifyListeners();
      _invalid = true;
    }
    _revision = state.diskSelectionRevision;
    setState(() {});
  }

  Widget _role(String role) {
    final options = _options(role);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),
        Text(role == 'esp' ? 'EFI · /boot/efi · FAT32' : 'Root · / · Btrfs'),
        DropdownButton<String>(
          key: ValueKey('manual-$role'),
          isExpanded: true,
          value: _selected[role],
          hint: Text(state.t('manual_no_target')),
          items: options.entries
              .map(
                (entry) => DropdownMenuItem(
                  value: entry.key,
                  child: Text(entry.value, overflow: TextOverflow.ellipsis),
                ),
              )
              .toList(),
          onChanged: !widget.enabled
              ? null
              : (value) {
                  _selected[role] = value;
                  if (role == 'esp') _formatEsp = false;
                  _setRange(role);
                  _publish();
                },
        ),
        if (_selected[role]?.startsWith('gap:') == true)
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              for (final entry in {
                'start': _start[role]!,
                'size': _size[role]!,
              }.entries)
                SizedBox(
                  width: 155,
                  child: TextField(
                    key: ValueKey('manual-$role-${entry.key}'),
                    enabled: widget.enabled,
                    controller: entry.value,
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(10),
                    ],
                    decoration: InputDecoration(
                      labelText: state.t('manual_${entry.key}'),
                    ),
                    onChanged: (_) => _publish(),
                  ),
                ),
            ],
          ),
        if (role == 'esp' && _selected[role]?.startsWith('existing:') == true)
          Material(
            type: MaterialType.transparency,
            child: CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _formatEsp,
              title: Text(state.t('manual_format_esp')),
              onChanged: !widget.enabled
                  ? null
                  : (value) {
                      _formatEsp = value == true;
                      _publish();
                    },
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const SizedBox(height: 12),
      Text(state.t('manual_root_warning')),
      const SizedBox(height: 12),
      NebulaSecondaryButton(
        label: state.t(
          _loading ? 'disk_free_space_loading' : 'disk_free_space_probe',
        ),
        icon: Icons.search_rounded,
        onPressed: _loading || !widget.enabled ? null : _scan,
      ),
      if (_current) ...[
        _role('esp'),
        _role('root'),
        const SizedBox(height: 8),
        Text(
          state.t(
            _formatEsp || _selected['esp']?.startsWith('gap:') == true
                ? 'manual_esp_warning'
                : 'manual_reuse_warning',
          ),
        ),
        if (_invalid)
          Text(
            state.t('manual_invalid'),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
      ],
    ],
  );
}
