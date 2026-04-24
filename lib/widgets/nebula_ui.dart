import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

class NebulaPanel extends StatelessWidget {
  const NebulaPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(28),
    this.width,
    this.height,
    this.alignment,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double? width;
  final double? height;
  final AlignmentGeometry? alignment;

  @override
  Widget build(BuildContext context) {
    final visuals = context.installerVisuals;

    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(visuals.panelRadius),
        child: BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: visuals.panelBlur,
            sigmaY: visuals.panelBlur,
          ),
          child: Container(
            width: width,
            height: height,
            alignment: alignment,
            padding: padding,
            decoration: BoxDecoration(
              color: visuals.panelColor,
              borderRadius: BorderRadius.circular(visuals.panelRadius),
              border: Border.all(color: visuals.panelBorder),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.35),
                  blurRadius: 40,
                  offset: const Offset(0, 18),
                ),
                BoxShadow(
                  color: Theme.of(
                    context,
                  ).colorScheme.primary.withValues(alpha: 0.08),
                  blurRadius: 36,
                  spreadRadius: -18,
                ),
              ],
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

class NebulaSectionLabel extends StatelessWidget {
  const NebulaSectionLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: Theme.of(context).textTheme.labelMedium?.copyWith(
        color: Theme.of(context).colorScheme.primary,
        letterSpacing: 1.8,
      ),
    );
  }
}

class NebulaScreenIntro extends StatelessWidget {
  const NebulaScreenIntro({
    super.key,
    required this.title,
    required this.description,
    this.badge,
    this.maxWidth = 760,
  });

  final String title;
  final String description;
  final String? badge;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final visuals = context.installerVisuals;

    return Column(
      children: [
        if (badge != null) ...[
          NebulaStatusChip(
            label: badge!,
            color: theme.colorScheme.primary,
            icon: Icons.auto_awesome_rounded,
          ),
          const SizedBox(height: 16),
        ],
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: Column(
            children: [
              Text(
                title,
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineLarge,
              ),
              const SizedBox(height: 12),
              Text(
                description,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: visuals.mutedForeground,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class NebulaStatusChip extends StatelessWidget {
  const NebulaStatusChip({
    super.key,
    required this.label,
    required this.color,
    this.icon,
  });

  final String label;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: color.withValues(alpha: 0.14),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 8),
          ],
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: color,
              letterSpacing: 1.1,
            ),
          ),
        ],
      ),
    );
  }
}

class NebulaPrimaryButton extends StatefulWidget {
  const NebulaPrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.padding = const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final EdgeInsetsGeometry padding;

  @override
  State<NebulaPrimaryButton> createState() => _NebulaPrimaryButtonState();
}

class _NebulaPrimaryButtonState extends State<NebulaPrimaryButton> {
  bool _hovered = false;
  bool _pressed = false;
  Offset _hoverOffset = const Offset(0.5, 0.5);

  @override
  Widget build(BuildContext context) {
    final visuals = context.installerVisuals;
    final motion = context.installerMotion;
    final enabled = widget.onPressed != null;
    final magneticOffset = enabled && _hovered
        ? Offset((_hoverOffset.dx - 0.5) * 10, (_hoverOffset.dy - 0.5) * 8)
        : Offset.zero;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onHover: (event) => setState(() {
        _hoverOffset = Offset(
          (event.localPosition.dx / 220).clamp(0.0, 1.0),
          (event.localPosition.dy / 56).clamp(0.0, 1.0),
        );
      }),
      onExit: (_) => setState(() {
        _hovered = false;
        _pressed = false;
        _hoverOffset = const Offset(0.5, 0.5);
      }),
      child: AnimatedScale(
        scale: enabled
            ? _pressed
                  ? 0.985
                  : _hovered
                  ? 1.05
                  : 1.0
            : 1.0,
        duration: motion.fast,
        curve: motion.emphasisCurve,
        child: Transform.translate(
          offset: magneticOffset,
          child: AnimatedContainer(
            duration: motion.medium,
            curve: motion.enterCurve,
            decoration: BoxDecoration(
              gradient: enabled ? visuals.primaryGradient : null,
              color: enabled
                  ? null
                  : Theme.of(context).colorScheme.outlineVariant,
              borderRadius: BorderRadius.circular(999),
              boxShadow: enabled
                  ? [
                      BoxShadow(
                        color: Theme.of(context).colorScheme.primary.withValues(
                          alpha: _pressed
                              ? 0.46
                              : _hovered
                              ? 0.38
                              : 0.24,
                        ),
                        blurRadius: _pressed
                            ? 34
                            : _hovered
                            ? 28
                            : 18,
                        spreadRadius: _hovered ? 1 : 0,
                      ),
                    ]
                  : const [],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: AnimatedOpacity(
                      duration: motion.fast,
                      opacity: enabled && (_hovered || _pressed) ? 1 : 0,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: RadialGradient(
                            center: Alignment(
                              (_hoverOffset.dx * 2) - 1,
                              (_hoverOffset.dy * 2) - 1,
                            ),
                            radius: 1.05,
                            colors: [
                              Colors.white.withValues(
                                alpha: _pressed ? 0.24 : 0.16,
                              ),
                              Colors.transparent,
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(999),
                      onTap: widget.onPressed,
                      onTapDown: enabled
                          ? (_) => setState(() => _pressed = true)
                          : null,
                      onTapUp: enabled
                          ? (_) => setState(() => _pressed = false)
                          : null,
                      onTapCancel: enabled
                          ? () => setState(() => _pressed = false)
                          : null,
                      child: Padding(
                        padding: widget.padding,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              widget.label,
                              style: Theme.of(context).textTheme.labelLarge
                                  ?.copyWith(color: Colors.white),
                            ),
                            if (widget.icon != null) ...[
                              const SizedBox(width: 10),
                              Icon(widget.icon, color: Colors.white, size: 18),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class NebulaSecondaryButton extends StatefulWidget {
  const NebulaSecondaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.padding = const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final EdgeInsetsGeometry padding;

  @override
  State<NebulaSecondaryButton> createState() => _NebulaSecondaryButtonState();
}

class _NebulaSecondaryButtonState extends State<NebulaSecondaryButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = widget.onPressed != null;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedScale(
        scale: enabled && _hovered ? 1.02 : 1.0,
        duration: context.installerMotion.fast,
        curve: context.installerMotion.emphasisCurve,
        child: OutlinedButton(
          onPressed: widget.onPressed,
          style: OutlinedButton.styleFrom(
            backgroundColor: _hovered
                ? scheme.surface.withValues(alpha: 0.16)
                : Colors.transparent,
            padding: widget.padding,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.icon != null) ...[
                Icon(
                  widget.icon,
                  size: 18,
                  color: scheme.onSurface.withValues(alpha: 0.76),
                ),
                const SizedBox(width: 10),
              ],
              Text(
                widget.label,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: scheme.onSurface.withValues(alpha: 0.82),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

@immutable
class NebulaDropdownItem<T> {
  const NebulaDropdownItem({
    required this.value,
    required this.label,
    this.icon,
  });

  final T value;
  final String label;
  final IconData? icon;
}

class NebulaDropdown<T> extends StatefulWidget {
  const NebulaDropdown({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.leadingIcon,
    this.dense = false,
    this.maxMenuHeight = 320,
  });

  final T value;
  final List<NebulaDropdownItem<T>> items;
  final ValueChanged<T> onChanged;
  final IconData? leadingIcon;
  final bool dense;
  final double maxMenuHeight;

  @override
  State<NebulaDropdown<T>> createState() => _NebulaDropdownState<T>();
}

class _NebulaDropdownState<T> extends State<NebulaDropdown<T>>
    with SingleTickerProviderStateMixin {
  final LayerLink _layerLink = LayerLink();
  final GlobalKey _targetKey = GlobalKey();

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 760),
    reverseDuration: const Duration(milliseconds: 260),
  );

  OverlayEntry? _overlayEntry;
  bool _expanded = false;
  bool _hovered = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _controller.duration = context.installerMotion.cinematic;
    _controller.reverseDuration = context.installerMotion.medium;
  }

  @override
  void dispose() {
    _overlayEntry?.remove();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _closeMenu() async {
    if (!_expanded) {
      return;
    }

    setState(() => _expanded = false);
    await _controller.reverse();
    _overlayEntry?.remove();
    _overlayEntry = null;
  }

  void _openMenu() {
    final overlay = Overlay.of(context);
    final targetContext = _targetKey.currentContext;
    final box = targetContext?.findRenderObject() as RenderBox?;
    if (box == null) {
      return;
    }

    final size = box.size;

    _overlayEntry = OverlayEntry(
      builder: (context) {
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: _closeMenu,
              ),
            ),
            CompositedTransformFollower(
              link: _layerLink,
              showWhenUnlinked: false,
              offset: Offset(0, size.height + 10),
              child: Material(
                color: Colors.transparent,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minWidth: size.width,
                    maxWidth: math.max(size.width, 280),
                    maxHeight: widget.maxMenuHeight,
                  ),
                  child: _NebulaDropdownMenu<T>(
                    animation: _controller,
                    items: widget.items,
                    value: widget.value,
                    dense: widget.dense,
                    onSelected: (value) {
                      widget.onChanged(value);
                      _closeMenu();
                    },
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );

    overlay.insert(_overlayEntry!);
    setState(() => _expanded = true);
    _controller.forward(from: 0);
  }

  void _toggleMenu() {
    if (_expanded) {
      _closeMenu();
      return;
    }
    _openMenu();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final visuals = context.installerVisuals;
    final motion = context.installerMotion;
    final selectedItem = widget.items.firstWhere(
      (item) => item.value == widget.value,
      orElse: () => widget.items.first,
    );

    return CompositedTransformTarget(
      link: _layerLink,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: AnimatedScale(
          scale: _expanded ? 1.01 : 1.0,
          duration: motion.fast,
          curve: motion.emphasisCurve,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              key: _targetKey,
              borderRadius: BorderRadius.circular(widget.dense ? 18 : 20),
              onTap: _toggleMenu,
              child: AnimatedContainer(
                duration: motion.medium,
                curve: motion.enterCurve,
                padding: EdgeInsets.symmetric(
                  horizontal: widget.dense ? 14 : 18,
                  vertical: widget.dense ? 12 : 16,
                ),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface.withValues(
                    alpha: theme.brightness == Brightness.dark ? 0.42 : 0.74,
                  ),
                  borderRadius: BorderRadius.circular(widget.dense ? 18 : 20),
                  border: Border.all(
                    color: _expanded
                        ? theme.colorScheme.primary.withValues(alpha: 0.82)
                        : theme.colorScheme.outlineVariant.withValues(
                            alpha: _hovered ? 0.88 : 0.7,
                          ),
                  ),
                  boxShadow: _expanded
                      ? [
                          BoxShadow(
                            color: theme.colorScheme.primary.withValues(
                              alpha: 0.18,
                            ),
                            blurRadius: 26,
                            spreadRadius: -10,
                          ),
                        ]
                      : const [],
                ),
                child: Row(
                  children: [
                    if (widget.leadingIcon != null) ...[
                      Icon(
                        widget.leadingIcon,
                        size: widget.dense ? 16 : 18,
                        color: theme.colorScheme.primary,
                      ),
                      SizedBox(width: widget.dense ? 10 : 12),
                    ],
                    Expanded(
                      child: Text(
                        selectedItem.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    AnimatedRotation(
                      turns: _expanded ? 0.5 : 0,
                      duration: motion.medium,
                      curve: motion.enterCurve,
                      child: Icon(
                        Icons.expand_more_rounded,
                        color: visuals.mutedForeground,
                        size: widget.dense ? 20 : 24,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NebulaDropdownMenu<T> extends StatelessWidget {
  const _NebulaDropdownMenu({
    required this.animation,
    required this.items,
    required this.value,
    required this.onSelected,
    required this.dense,
  });

  final Animation<double> animation;
  final List<NebulaDropdownItem<T>> items;
  final T value;
  final ValueChanged<T> onSelected;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final motion = context.installerMotion;
    final unfold = CurvedAnimation(
      parent: animation,
      curve: motion.enterCurve,
      reverseCurve: motion.exitCurve,
    );
    final staggerUnit =
        motion.stagger.inMicroseconds / motion.cinematic.inMicroseconds;

    return FadeTransition(
      opacity: unfold,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: Offset(0, -motion.dropdownLift / 180),
          end: Offset.zero,
        ).animate(unfold),
        child: SizeTransition(
          sizeFactor: unfold,
          axisAlignment: -1,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.96, end: 1.0).animate(unfold),
            alignment: Alignment.topCenter,
            child: NebulaPanel(
              padding: EdgeInsets.all(dense ? 10 : 12),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(22),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final entry in items.asMap().entries)
                        _NebulaDropdownMenuItem<T>(
                          item: entry.value,
                          selected: entry.value.value == value,
                          dense: dense,
                          animation: CurvedAnimation(
                            parent: animation,
                            curve: Interval(
                              (entry.key * staggerUnit * 0.75).clamp(0.0, 0.76),
                              ((entry.key * staggerUnit * 0.75) + 0.32).clamp(
                                0.18,
                                1.0,
                              ),
                              curve: motion.enterCurve,
                            ),
                          ),
                          onTap: () => onSelected(entry.value.value),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NebulaDropdownMenuItem<T> extends StatelessWidget {
  const _NebulaDropdownMenuItem({
    required this.item,
    required this.selected,
    required this.animation,
    required this.onTap,
    required this.dense,
  });

  final NebulaDropdownItem<T> item;
  final bool selected;
  final Animation<double> animation;
  final VoidCallback onTap;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final offset = Tween<Offset>(
      begin: const Offset(0, -0.12),
      end: Offset.zero,
    ).animate(animation);
    final scale = Tween<double>(begin: 0.97, end: 1.0).animate(animation);

    return FadeTransition(
      opacity: animation,
      child: SlideTransition(
        position: offset,
        child: ScaleTransition(
          scale: scale,
          alignment: Alignment.topCenter,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(18),
                onTap: onTap,
                child: AnimatedContainer(
                  duration: context.installerMotion.medium,
                  curve: context.installerMotion.enterCurve,
                  padding: EdgeInsets.symmetric(
                    horizontal: dense ? 12 : 14,
                    vertical: dense ? 10 : 12,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(18),
                    color: selected
                        ? theme.colorScheme.primary.withValues(alpha: 0.12)
                        : Colors.transparent,
                    border: Border.all(
                      color: selected
                          ? theme.colorScheme.primary.withValues(alpha: 0.26)
                          : theme.colorScheme.outlineVariant.withValues(
                              alpha: 0.18,
                            ),
                    ),
                  ),
                  child: Row(
                    children: [
                      if (item.icon != null) ...[
                        Icon(
                          item.icon,
                          size: dense ? 16 : 18,
                          color: selected
                              ? theme.colorScheme.primary
                              : theme.colorScheme.tertiary,
                        ),
                        SizedBox(width: dense ? 10 : 12),
                      ],
                      Expanded(
                        child: Text(
                          item.label,
                          style:
                              (dense
                                      ? theme.textTheme.bodySmall
                                      : theme.textTheme.bodyMedium)
                                  ?.copyWith(
                                    color: theme.colorScheme.onSurface,
                                  ),
                        ),
                      ),
                      if (selected)
                        Icon(
                          Icons.check_rounded,
                          size: dense ? 16 : 18,
                          color: theme.colorScheme.primary,
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
