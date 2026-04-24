import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/installer_state.dart';
import '../theme/app_theme.dart';
import 'nebula_ui.dart';

class InstallerLayout extends StatefulWidget {
  const InstallerLayout({super.key, required this.child});

  final Widget child;

  @override
  State<InstallerLayout> createState() => _InstallerLayoutState();
}

class _InstallerLayoutState extends State<InstallerLayout> {
  final ValueNotifier<Offset> _pointer = ValueNotifier(const Offset(0.5, 0.5));
  int _lastStepIndex = 0;
  int _transitionDirection = 1;

  void _handlePointer(PointerHoverEvent event) {
    final size = MediaQuery.sizeOf(context);
    if (size.width <= 0 || size.height <= 0) {
      return;
    }

    _pointer.value = Offset(
      (event.localPosition.dx / size.width).clamp(0.0, 1.0),
      (event.localPosition.dy / size.height).clamp(0.0, 1.0),
    );
  }

  @override
  void dispose() {
    _pointer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = Provider.of<InstallerState>(context);
    final visuals = context.installerVisuals;

    if (_lastStepIndex != state.currentStep) {
      _transitionDirection = state.currentStep >= _lastStepIndex ? 1 : -1;
      _lastStepIndex = state.currentStep;
    }
    final contentMaxWidth = state.steps[state.currentStep] == 'Disk'
        ? 1400.0
        : 1260.0;

    return MouseRegion(
      onHover: _handlePointer,
      onExit: (_) => _pointer.value = const Offset(0.5, 0.5),
      child: Scaffold(
        body: Container(
          decoration: BoxDecoration(color: visuals.backgroundBase),
          child: Stack(
            children: [
              ValueListenableBuilder<Offset>(
                valueListenable: _pointer,
                builder: (context, pointer, child) {
                  return _NebulaBackground(pointer: pointer);
                },
              ),
              SafeArea(
                child: Padding(
                  padding: visuals.screenPadding,
                  child: Column(
                    children: [
                      _NebulaTopBar(subtitle: state.t('app_subtitle')),
                      const SizedBox(height: 24),
                      _PhaseStepper(
                        currentStep: state.currentStep,
                        currentStepLabel: state.steps[state.currentStep],
                        phaseLabels: [
                          state.t('phase_initialization'),
                          state.t('phase_configuration'),
                          state.t('phase_storage'),
                          state.t('phase_installation'),
                          state.t('phase_finalization'),
                        ],
                      ),
                      const SizedBox(height: 28),
                      Expanded(
                        child: Align(
                          alignment: Alignment.topCenter,
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: contentMaxWidth,
                            ),
                            child: AnimatedSwitcher(
                              duration: context.installerMotion.slow,
                              switchInCurve: context.installerMotion.enterCurve,
                              switchOutCurve: context.installerMotion.exitCurve,
                              transitionBuilder: (child, animation) {
                                return _NebulaDissolveTransition(
                                  animation: animation,
                                  direction: _transitionDirection,
                                  child: child,
                                );
                              },
                              child: KeyedSubtree(
                                key: ValueKey(state.steps[state.currentStep]),
                                child: widget.child,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 18),
                      const _NebulaFooter(),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NebulaDissolveTransition extends StatelessWidget {
  const _NebulaDissolveTransition({
    required this.animation,
    required this.direction,
    required this.child,
  });

  final Animation<double> animation;
  final int direction;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final motion = context.installerMotion;
    final theme = Theme.of(context);
    final curved = CurvedAnimation(
      parent: animation,
      curve: motion.enterCurve,
      reverseCurve: motion.exitCurve,
    );

    return AnimatedBuilder(
      animation: curved,
      child: child,
      builder: (context, child) {
        final value = curved.value.clamp(0.0, 1.0);
        final phase = 1 - value;
        final isAssembling = animation.status != AnimationStatus.reverse;
        final slideX = phase * motion.particleTravel * direction;
        final slideY = phase * 14;
        final blur = phase * 20;
        final scale = isAssembling
            ? 0.972 + (0.028 * value)
            : 1 - (0.02 * phase);

        return ClipRect(
          child: Stack(
            fit: StackFit.expand,
            children: [
              Opacity(
                opacity: value,
                child: Transform.translate(
                  offset: Offset(slideX, slideY),
                  child: Transform.scale(
                    scale: scale,
                    alignment: Alignment.topCenter,
                    child: ImageFiltered(
                      imageFilter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
                      child: child,
                    ),
                  ),
                ),
              ),
              IgnorePointer(
                child: CustomPaint(
                  painter: _NebulaDissolvePainter(
                    progress: phase,
                    direction: direction.toDouble(),
                    assembling: isAssembling,
                    primary: theme.colorScheme.primary,
                    secondary: theme.colorScheme.tertiary,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _NebulaDissolvePainter extends CustomPainter {
  const _NebulaDissolvePainter({
    required this.progress,
    required this.direction,
    required this.assembling,
    required this.primary,
    required this.secondary,
  });

  final double progress;
  final double direction;
  final bool assembling;
  final Color primary;
  final Color secondary;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) {
      return;
    }

    final haze = Paint()
      ..shader = LinearGradient(
        colors: [
          primary.withValues(alpha: 0.02 * progress),
          secondary.withValues(alpha: 0.05 * progress),
          Colors.transparent,
        ],
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
      ).createShader(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, haze);

    const count = 24;
    for (var index = 0; index < count; index++) {
      final lane = _noise(index, 0.23);
      final widthSeed = _noise(index, 0.61);
      final orbit = _noise(index, 1.27);
      final reveal = ((progress - (index * 0.018)) / 0.82).clamp(0.0, 1.0);

      if (reveal <= 0) {
        continue;
      }

      final travel = size.width * (0.08 + (widthSeed * 0.14));
      final baseX = size.width * (0.16 + (_noise(index, 1.73) * 0.68));
      final fromX = assembling ? baseX + (direction * travel) : baseX;
      final toX = assembling ? baseX : baseX + (direction * travel);
      final currentX = lerpDouble(fromX, toX, reveal)!;
      final currentY =
          (size.height * (0.08 + (lane * 0.84))) +
          (math.sin((orbit * math.pi * 2) + (reveal * math.pi)) *
              (6 + (widthSeed * 12)));
      final color = Color.lerp(
        primary,
        secondary,
        widthSeed,
      )!.withValues(alpha: (assembling ? (1 - reveal) : reveal) * 0.44);
      final trail = 12 + (widthSeed * 20);

      final streakPaint = Paint()
        ..color = color
        ..strokeWidth = 1.2 + (orbit * 1.6)
        ..strokeCap = StrokeCap.round
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
      canvas.drawLine(
        Offset(currentX - (trail * direction), currentY),
        Offset(currentX, currentY),
        streakPaint,
      );

      final particlePaint = Paint()
        ..color = color.withValues(alpha: color.a + 0.12)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
      canvas.drawCircle(
        Offset(currentX, currentY),
        1.6 + (lane * 2.6),
        particlePaint,
      );
    }
  }

  double _noise(int index, double offset) {
    return (math.sin((index + 1) * 12.9898 + (offset * 78.233)) + 1) / 2;
  }

  @override
  bool shouldRepaint(covariant _NebulaDissolvePainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.direction != direction ||
        oldDelegate.assembling != assembling ||
        oldDelegate.primary != primary ||
        oldDelegate.secondary != secondary;
  }
}

class _NebulaBackground extends StatefulWidget {
  const _NebulaBackground({required this.pointer});

  final Offset pointer;

  @override
  State<_NebulaBackground> createState() => _NebulaBackgroundState();
}

class _NebulaBackgroundState extends State<_NebulaBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 26),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final visuals = context.installerVisuals;
    final scheme = Theme.of(context).colorScheme;

    return Positioned.fill(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = constraints.biggest;

          return AnimatedBuilder(
            animation: _controller,
            builder: (context, child) {
              final tick = _controller.value * math.pi * 2;
              final pointerX = (widget.pointer.dx - 0.5) * 1.7;
              final pointerY = (widget.pointer.dy - 0.5) * 1.7;

              return Stack(
                fit: StackFit.expand,
                children: [
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          visuals.backgroundBase,
                          visuals.backgroundBase.withValues(alpha: 0.98),
                          visuals.backgroundBase.withValues(alpha: 0.96),
                        ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                    ),
                  ),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: Alignment(pointerX * 0.35, pointerY * 0.35),
                        radius: 1.25,
                        colors: [
                          Colors.white.withValues(alpha: 0.04),
                          Colors.transparent,
                        ],
                      ),
                    ),
                  ),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          visuals.backgroundAccentStart.withValues(alpha: 0.08),
                          Colors.transparent,
                          visuals.backgroundAccentEnd.withValues(alpha: 0.08),
                        ],
                        begin: Alignment(-0.75 + pointerX * 0.18, -1.0),
                        end: Alignment(0.8 + pointerX * 0.18, 1.0),
                      ),
                    ),
                  ),
                  _FloatingOrb(
                    size: size,
                    center: const Offset(0.12, 0.10),
                    orbSize: 560,
                    swayX: 30,
                    swayY: 22,
                    pullX: 48,
                    pullY: 34,
                    phase: 0.3,
                    tick: tick,
                    pointer: widget.pointer,
                    color: visuals.backgroundAccentStart.withValues(
                      alpha: 0.54,
                    ),
                  ),
                  _FloatingOrb(
                    size: size,
                    center: const Offset(0.88, 0.82),
                    orbSize: 640,
                    swayX: 34,
                    swayY: 28,
                    pullX: 56,
                    pullY: 44,
                    phase: 1.7,
                    tick: tick,
                    pointer: widget.pointer,
                    color: visuals.backgroundAccentEnd.withValues(alpha: 0.48),
                  ),
                  _FloatingOrb(
                    size: size,
                    center: const Offset(0.76, 0.22),
                    orbSize: 260,
                    swayX: 22,
                    swayY: 18,
                    pullX: 28,
                    pullY: 20,
                    phase: 3.1,
                    tick: tick,
                    pointer: widget.pointer,
                    color: scheme.primary.withValues(alpha: 0.12),
                  ),
                  _FloatingOrb(
                    size: size,
                    center: const Offset(0.28, 0.76),
                    orbSize: 280,
                    swayX: 20,
                    swayY: 26,
                    pullX: 24,
                    pullY: 18,
                    phase: 4.4,
                    tick: tick,
                    pointer: widget.pointer,
                    color: scheme.tertiary.withValues(alpha: 0.1),
                  ),
                  Positioned.fill(
                    child: IgnorePointer(
                      child: Opacity(
                        opacity: 0.55,
                        child: CustomPaint(
                          painter: _NebulaRibbonPainter(
                            colorA: scheme.primary.withValues(alpha: 0.06),
                            colorB: visuals.backgroundAccentEnd.withValues(
                              alpha: 0.06,
                            ),
                            progress: _controller.value,
                            pointer: widget.pointer,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

class _FloatingOrb extends StatelessWidget {
  const _FloatingOrb({
    required this.size,
    required this.center,
    required this.orbSize,
    required this.swayX,
    required this.swayY,
    required this.pullX,
    required this.pullY,
    required this.phase,
    required this.tick,
    required this.pointer,
    required this.color,
  });

  final Size size;
  final Offset center;
  final double orbSize;
  final double swayX;
  final double swayY;
  final double pullX;
  final double pullY;
  final double phase;
  final double tick;
  final Offset pointer;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final x =
        (size.width * center.dx) -
        (orbSize / 2) +
        (math.sin(tick + phase) * swayX) +
        ((pointer.dx - 0.5) * pullX);
    final y =
        (size.height * center.dy) -
        (orbSize / 2) +
        (math.cos((tick * 0.82) + phase) * swayY) +
        ((pointer.dy - 0.5) * pullY);
    final scale = 0.96 + (math.sin((tick * 0.9) + phase) * 0.04);

    return Positioned(
      left: x,
      top: y,
      child: Transform.scale(
        scale: scale,
        child: _GlowOrb(color: color, size: orbSize),
      ),
    );
  }
}

class _NebulaRibbonPainter extends CustomPainter {
  const _NebulaRibbonPainter({
    required this.colorA,
    required this.colorB,
    required this.progress,
    required this.pointer,
  });

  final Color colorA;
  final Color colorB;
  final double progress;
  final Offset pointer;

  @override
  void paint(Canvas canvas, Size size) {
    final pathA = Path();
    final yBaseA = size.height * (0.24 + (pointer.dy - 0.5) * 0.05);
    pathA.moveTo(-40, yBaseA);
    pathA.cubicTo(
      size.width * 0.2,
      yBaseA - 90,
      size.width * 0.46,
      yBaseA + 95,
      size.width + 40,
      yBaseA - 16 + math.sin(progress * math.pi * 2) * 18,
    );

    final paintA = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 120
      ..shader = LinearGradient(
        colors: [Colors.transparent, colorA, Colors.transparent],
      ).createShader(Offset.zero & size)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 60);

    final pathB = Path();
    final yBaseB = size.height * (0.72 + (pointer.dy - 0.5) * 0.06);
    pathB.moveTo(-40, yBaseB);
    pathB.cubicTo(
      size.width * 0.18,
      yBaseB + 80,
      size.width * 0.55,
      yBaseB - 120,
      size.width + 40,
      yBaseB + 20 + math.cos(progress * math.pi * 2) * 16,
    );

    final paintB = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 100
      ..shader = LinearGradient(
        colors: [Colors.transparent, colorB, Colors.transparent],
      ).createShader(Offset.zero & size)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 54);

    canvas.drawPath(pathA, paintA);
    canvas.drawPath(pathB, paintB);
  }

  @override
  bool shouldRepaint(covariant _NebulaRibbonPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.pointer != pointer ||
        oldDelegate.colorA != colorA ||
        oldDelegate.colorB != colorB;
  }
}

class _GlowOrb extends StatelessWidget {
  const _GlowOrb({required this.color, required this.size});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color,
          boxShadow: [
            BoxShadow(
              color: color,
              blurRadius: size / 2.8,
              spreadRadius: size / 18,
            ),
          ],
        ),
      ),
    );
  }
}

class _NebulaTopBar extends StatelessWidget {
  const _NebulaTopBar({required this.subtitle});

  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final visuals = context.installerVisuals;
    final onSurface = scheme.onSurface;

    return NebulaPanel(
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
      child: Row(
        children: [
          Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.asset(
                  'assets/branding/roasd-logo.png',
                  width: 42,
                  height: 42,
                  fit: BoxFit.cover,
                ),
              ),
              const SizedBox(width: 14),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Ro-Installer',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: onSurface,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: visuals.mutedForeground,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: scheme.outlineVariant.withValues(alpha: 0.7),
              ),
              color: scheme.surface.withValues(alpha: 0.18),
            ),
            child: Text(
              'v3.0.0',
              style: Theme.of(
                context,
              ).textTheme.labelLarge?.copyWith(color: scheme.primary),
            ),
          ),
        ],
      ),
    );
  }
}

class _PhaseStepper extends StatefulWidget {
  const _PhaseStepper({
    required this.currentStep,
    required this.currentStepLabel,
    required this.phaseLabels,
  });

  final int currentStep;
  final String currentStepLabel;
  final List<String> phaseLabels;

  static const List<_PhaseData> _phases = [
    _PhaseData(Icons.power_settings_new_rounded),
    _PhaseData(Icons.tune_rounded),
    _PhaseData(Icons.storage_rounded),
    _PhaseData(Icons.rocket_launch_rounded),
    _PhaseData(Icons.task_alt_rounded),
  ];

  @override
  State<_PhaseStepper> createState() => _PhaseStepperState();
}

class _PhaseStepperState extends State<_PhaseStepper>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 3),
  )..repeat(reverse: true);

  int _phaseIndex() {
    switch (widget.currentStepLabel) {
      case 'Welcome':
        return 0;
      case 'Theme':
      case 'Location':
      case 'Network':
      case 'Account':
      case 'Type':
        return 1;
      case 'Disk':
      case 'Partitions':
      case 'Kernel':
        return 2;
      case 'Install':
        return 3;
      default:
        return widget.currentStep > 0 ? 1 : 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final visuals = context.installerVisuals;
    final activePhase = _phaseIndex();

    return LayoutBuilder(
      builder: (context, constraints) {
        final showLabels = constraints.maxWidth > 1080;
        final connectorMargin = showLabels ? 12.0 : 8.0;

        return AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            final pulse = 0.6 + (_controller.value * 0.4);

            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(_PhaseStepper._phases.length * 2 - 1, (
                  index,
                ) {
                  if (index.isOdd) {
                    final connectorIndex = index ~/ 2;
                    final filled = connectorIndex < activePhase;
                    final activeLink = connectorIndex == activePhase;

                    return Expanded(
                      child: Container(
                        margin: EdgeInsets.symmetric(
                          horizontal: connectorMargin,
                        ),
                        height: 6,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(999),
                          color: scheme.outlineVariant.withValues(alpha: 0.22),
                        ),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: FractionallySizedBox(
                            widthFactor: filled
                                ? 1
                                : activeLink
                                ? (0.52 + (pulse * 0.18))
                                : 0,
                            child: AnimatedContainer(
                              duration: context.installerMotion.medium,
                              curve: context.installerMotion.enterCurve,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(999),
                                gradient: filled || activeLink
                                    ? visuals.progressGradient
                                    : null,
                                boxShadow: filled || activeLink
                                    ? [
                                        BoxShadow(
                                          color: scheme.primary.withValues(
                                            alpha: activeLink
                                                ? 0.24 * pulse
                                                : 0.14,
                                          ),
                                          blurRadius: 18,
                                          spreadRadius: -8,
                                        ),
                                      ]
                                    : const [],
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  }

                  final phase = _PhaseStepper._phases[index ~/ 2];
                  final phaseIndex = index ~/ 2;
                  final isActive = phaseIndex == activePhase;
                  final isDone = phaseIndex < activePhase;
                  final scale = isActive ? (1 + (pulse * 0.04)) : 1.0;

                  return Transform.scale(
                    scale: scale,
                    child: AnimatedContainer(
                      duration: context.installerMotion.medium,
                      curve: context.installerMotion.enterCurve,
                      padding: EdgeInsets.symmetric(
                        horizontal: showLabels ? 14 : 10,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: isActive
                            ? scheme.surface.withValues(alpha: 0.18)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(999),
                        boxShadow: isActive
                            ? [
                                BoxShadow(
                                  color: scheme.primary.withValues(
                                    alpha: 0.16 + (pulse * 0.16),
                                  ),
                                  blurRadius: 22 + (pulse * 12),
                                  spreadRadius: -8,
                                ),
                              ]
                            : const [],
                      ),
                      child: Row(
                        children: [
                          Icon(
                            isDone
                                ? Icons.check_circle_rounded
                                : isActive
                                ? Icons.radio_button_checked_rounded
                                : phase.icon,
                            size: 18,
                            color: isActive
                                ? scheme.primary
                                : isDone
                                ? scheme.tertiary
                                : visuals.mutedForeground.withValues(
                                    alpha: 0.82,
                                  ),
                          ),
                          if (showLabels) ...[
                            const SizedBox(width: 8),
                            Text(
                              widget.phaseLabels[phaseIndex].toUpperCase(),
                              style: Theme.of(context).textTheme.labelSmall
                                  ?.copyWith(
                                    color: isActive
                                        ? scheme.onSurface
                                        : isDone
                                        ? scheme.tertiary
                                        : visuals.mutedForeground,
                                    letterSpacing: 1.1,
                                  ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  );
                }),
              ),
            );
          },
        );
      },
    );
  }
}

class _PhaseData {
  const _PhaseData(this.icon);

  final IconData icon;
}

class _NebulaFooter extends StatelessWidget {
  const _NebulaFooter();

  @override
  Widget build(BuildContext context) {
    final visuals = context.installerVisuals;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          Text(
            'Ro-Installer v3.0.0',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: visuals.footerForeground,
              letterSpacing: 1.4,
            ),
          ),
          const Spacer(),
          Text(
            'Ro-ASD',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: visuals.footerForeground,
              letterSpacing: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}
