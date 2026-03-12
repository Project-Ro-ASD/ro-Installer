import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state/installer_state.dart';

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
    final theme = Theme.of(context);
    final state = Provider.of<InstallerState>(context);
    final isDark = state.themeMode == 'dark';
    final textColor = isDark ? Colors.white : Colors.black87;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 20, bottom: 20),
          child: Column(
            children: [
              Text(
                state.t('acc_title'),
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: textColor,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                state.t('acc_desc'),
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: textColor.withOpacity(0.6),
                ),
              ),
            ],
          ),
        ),

        Expanded(
          child: Center(
            child: Container(
              width: 500,
              padding: const EdgeInsets.all(30),
              decoration: BoxDecoration(
                color: theme.cardColor.withOpacity(isDark ? 0.3 : 0.6),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white.withOpacity(0.1)),
              ),
              child: Form(
                key: _formKey,
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      _buildTextField(
                        controller: _nameController,
                        label: "Full Name",
                        icon: Icons.badge,
                        isDark: isDark,
                        validator: (value) => 
                            value == null || value.isEmpty ? "Please enter your full name" : null,
                      ),
                      const SizedBox(height: 16),
                      _buildTextField(
                        controller: _usernameController,
                        label: "Username",
                        icon: Icons.person,
                        isDark: isDark,
                        validator: (value) => 
                            value == null || value.isEmpty ? "Please enter a username" : null,
                      ),
                      const SizedBox(height: 16),
                      _buildTextField(
                        controller: _passwordController,
                        label: "Password",
                        icon: Icons.lock,
                        isDark: isDark,
                        isPassword: true,
                        validator: (value) => 
                            value == null || value.length < 4 ? "Password must be at least 4 characters" : null,
                      ),
                      const SizedBox(height: 16),
                      _buildTextField(
                        controller: _confirmPasswordController,
                        label: "Confirm Password",
                        icon: Icons.lock_reset,
                        isDark: isDark,
                        isPassword: true,
                        validator: (value) => 
                            value != _passwordController.text ? "Passwords do not match" : null,
                      ),
                      const SizedBox(height: 24),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Icon(Icons.admin_panel_settings, color: theme.colorScheme.primary),
                                    const SizedBox(width: 10),
                                    Text(state.t('admin'), style: TextStyle(color: textColor, fontWeight: FontWeight.bold)),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Padding(
                                  padding: const EdgeInsets.only(left: 34),
                                  child: Text(
                                    state.t('admin_sub'),
                                    style: TextStyle(color: textColor.withOpacity(0.5), fontSize: 11),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Switch(
                            value: _isAdmin,
                            onChanged: (val) => setState(() => _isAdmin = val),
                            activeColor: theme.colorScheme.primary,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),

        Padding(
          padding: const EdgeInsets.only(top: 20),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              TextButton.icon(
                onPressed: () => state.previousStep(),
                icon: const Icon(Icons.arrow_back),
                label: Text(state.t('prev')),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                  foregroundColor: textColor.withOpacity(0.7),
                ),
              ),
              ElevatedButton.icon(
                onPressed: _submit,
                icon: const Icon(Icons.arrow_forward),
                label: Text(state.t('next')),
                style: theme.elevatedButtonTheme.style?.copyWith(
                  padding: const WidgetStatePropertyAll(
                    EdgeInsets.symmetric(horizontal: 32, vertical: 20),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    required bool isDark,
    bool isPassword = false,
    String? Function(String?)? validator,
  }) {
    return TextFormField(
      controller: controller,
      obscureText: isPassword,
      style: TextStyle(color: isDark ? Colors.white : Colors.black87),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: (isDark ? Colors.white : Colors.black87).withOpacity(0.5)),
        prefixIcon: Icon(icon, color: Colors.grey.withOpacity(0.8)),
        filled: true,
        fillColor: isDark ? const Color(0xFF151520) : Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: Colors.grey.withOpacity(0.2)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: Colors.grey.withOpacity(0.2)),
        ),
      ),
      validator: validator,
    );
  }
}
