import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../state/installer_state.dart';
import '../theme/app_theme.dart';
import '../utils/account_validation.dart';
import '../widgets/nebula_ui.dart';

class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key});

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  bool _isAdmin = true;

  @override
  void initState() {
    super.initState();
    final state = Provider.of<InstallerState>(context, listen: false);
    _nameController.text = state.fullName;
    _usernameController.text = state.username;
    _passwordController.text = state.password;
    _confirmPasswordController.text = state.password;
    _isAdmin = state.isAdministrator;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  void _submit() {
    if (_formKey.currentState!.validate()) {
      final state = Provider.of<InstallerState>(context, listen: false);
      state.updateAccount(
        _nameController.text,
        _usernameController.text,
        _passwordController.text,
        _isAdmin,
      );
      state.nextStep();
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = Provider.of<InstallerState>(context);
    final theme = Theme.of(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 1080;

        final profilePanel = NebulaPanel(
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                NebulaSectionLabel(state.t('acc_identity_section')),
                const SizedBox(height: 22),
                if (compact) ...[
                  _AccountField(
                    controller: _nameController,
                    label: state.t('acc_name_label'),
                    icon: Icons.badge_rounded,
                    validator: (value) => value == null || value.isEmpty
                        ? state.t('acc_err_name_required')
                        : null,
                  ),
                  const SizedBox(height: 16),
                  _AccountField(
                    controller: _usernameController,
                    label: state.t('acc_username_label'),
                    icon: Icons.person_rounded,
                    helperText: state.t('acc_username_rule'),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(
                        RegExp(r'[A-Za-z0-9_-]'),
                      ),
                    ],
                    validator: (value) {
                      final username = normalizeLinuxUsername(value ?? '');
                      if (username.isEmpty) {
                        return state.t('acc_err_username_required');
                      }
                      if (!isValidLinuxUsername(username)) {
                        return state.t('acc_err_username_invalid');
                      }
                      return null;
                    },
                  ),
                ] else
                  Row(
                    children: [
                      Expanded(
                        child: _AccountField(
                          controller: _nameController,
                          label: state.t('acc_name_label'),
                          icon: Icons.badge_rounded,
                          validator: (value) => value == null || value.isEmpty
                              ? state.t('acc_err_name_required')
                              : null,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: _AccountField(
                          controller: _usernameController,
                          label: state.t('acc_username_label'),
                          icon: Icons.person_rounded,
                          helperText: state.t('acc_username_rule'),
                          inputFormatters: [
                            FilteringTextInputFormatter.allow(
                              RegExp(r'[A-Za-z0-9_-]'),
                            ),
                          ],
                          validator: (value) {
                            final username = normalizeLinuxUsername(
                              value ?? '',
                            );
                            if (username.isEmpty) {
                              return state.t('acc_err_username_required');
                            }
                            if (!isValidLinuxUsername(username)) {
                              return state.t('acc_err_username_invalid');
                            }
                            return null;
                          },
                        ),
                      ),
                    ],
                  ),
                const SizedBox(height: 16),
                if (compact) ...[
                  _AccountField(
                    controller: _passwordController,
                    label: state.t('acc_password_label'),
                    icon: Icons.lock_rounded,
                    obscureText: true,
                    validator: (value) => value == null || value.length < 4
                        ? state.t('acc_err_password_short')
                        : null,
                  ),
                  const SizedBox(height: 16),
                  _AccountField(
                    controller: _confirmPasswordController,
                    label: state.t('acc_confirm_password_label'),
                    icon: Icons.lock_reset_rounded,
                    obscureText: true,
                    validator: (value) => value != _passwordController.text
                        ? state.t('acc_err_password_match')
                        : null,
                  ),
                ] else
                  Row(
                    children: [
                      Expanded(
                        child: _AccountField(
                          controller: _passwordController,
                          label: state.t('acc_password_label'),
                          icon: Icons.lock_rounded,
                          obscureText: true,
                          validator: (value) =>
                              value == null || value.length < 4
                              ? state.t('acc_err_password_short')
                              : null,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: _AccountField(
                          controller: _confirmPasswordController,
                          label: state.t('acc_confirm_password_label'),
                          icon: Icons.lock_reset_rounded,
                          obscureText: true,
                          validator: (value) =>
                              value != _passwordController.text
                              ? state.t('acc_err_password_match')
                              : null,
                        ),
                      ),
                    ],
                  ),
                const SizedBox(height: 22),
                Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surface.withValues(
                      alpha: theme.brightness == Brightness.dark ? 0.24 : 0.62,
                    ),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: theme.colorScheme.outlineVariant.withValues(
                        alpha: 0.4,
                      ),
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  Icons.admin_panel_settings_rounded,
                                  color: theme.colorScheme.primary,
                                  size: 20,
                                ),
                                const SizedBox(width: 10),
                                Text(
                                  state.t('admin'),
                                  style: theme.textTheme.titleMedium,
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text(
                              state.t('admin_sub'),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: context.installerVisuals.mutedForeground,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Switch(
                        value: _isAdmin,
                        onChanged: (value) => setState(() => _isAdmin = value),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );

        final securityPanel = NebulaPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              NebulaSectionLabel(state.t('acc_privileges_section')),
              const SizedBox(height: 22),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  NebulaStatusChip(
                    label: _isAdmin
                        ? state.t('acc_admin_enabled')
                        : state.t('acc_standard_user'),
                    color: _isAdmin
                        ? theme.colorScheme.primary
                        : theme.colorScheme.secondary,
                    icon: _isAdmin
                        ? Icons.verified_user_rounded
                        : Icons.person_outline_rounded,
                  ),
                  NebulaStatusChip(
                    label:
                        normalizeLinuxUsername(_usernameController.text).isEmpty
                        ? state.t('acc_pending_username')
                        : normalizeLinuxUsername(
                            _usernameController.text,
                          ).toUpperCase(),
                    color: theme.colorScheme.tertiary,
                    icon: Icons.person_rounded,
                  ),
                ],
              ),
              const SizedBox(height: 24),
              _AccountSummaryItem(
                icon: Icons.shield_moon_rounded,
                title: state.t('acc_privilege_model'),
                body: _isAdmin
                    ? state.t('acc_privilege_model_admin')
                    : state.t('acc_privilege_model_standard'),
              ),
              const SizedBox(height: 16),
              _AccountSummaryItem(
                icon: Icons.lock_clock_rounded,
                title: state.t('acc_password_policy'),
                body: state.t('acc_password_policy_body'),
              ),
            ],
          ),
        );

        return Column(
          children: [
            const SizedBox(height: 10),
            NebulaScreenIntro(
              badge: state.t('acc_badge'),
              title: state.t('acc_title'),
              description: state.t('acc_desc'),
            ),
            const SizedBox(height: 24),
            Expanded(
              child: compact
                  ? SingleChildScrollView(
                      child: Column(
                        children: [
                          profilePanel,
                          const SizedBox(height: 18),
                          securityPanel,
                        ],
                      ),
                    )
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(flex: 6, child: profilePanel),
                        const SizedBox(width: 22),
                        Expanded(flex: 4, child: securityPanel),
                      ],
                    ),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                NebulaSecondaryButton(
                  label: state.t('prev'),
                  icon: Icons.arrow_back_rounded,
                  onPressed: state.previousStep,
                ),
                const Spacer(),
                NebulaPrimaryButton(
                  label: state.t('next'),
                  icon: Icons.arrow_forward_rounded,
                  onPressed: _submit,
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _AccountField extends StatelessWidget {
  const _AccountField({
    required this.controller,
    required this.label,
    required this.icon,
    required this.validator,
    this.obscureText = false,
    this.helperText,
    this.inputFormatters = const [],
  });

  final TextEditingController controller;
  final String label;
  final IconData icon;
  final String? Function(String?) validator;
  final bool obscureText;
  final String? helperText;
  final List<TextInputFormatter> inputFormatters;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      obscureText: obscureText,
      inputFormatters: inputFormatters,
      validator: validator,
      decoration: InputDecoration(
        labelText: label,
        helperText: helperText,
        prefixIcon: Icon(icon),
      ),
    );
  }
}

class _AccountSummaryItem extends StatelessWidget {
  const _AccountSummaryItem({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(
          alpha: theme.brightness == Brightness.dark ? 0.22 : 0.6,
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: theme.colorScheme.primary, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                Text(
                  body,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: context.installerVisuals.mutedForeground,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
