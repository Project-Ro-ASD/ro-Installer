import 'package:flutter/material.dart';
import '../widgets/glass_container.dart';

class UserScreen extends StatefulWidget {
  final VoidCallback onToggleTheme;
  final VoidCallback onBack;
  final Function(String userConfigJson) onNext;

  const UserScreen({
    super.key,
    required this.onToggleTheme,
    required this.onBack,
    required this.onNext,
  });

  @override
  State<UserScreen> createState() => _UserScreenState();
}

class _UserScreenState extends State<UserScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();

  @override
  void dispose() {
    _nameController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _submit() {
    if (_formKey.currentState!.validate()) {
      // Şifreler vs backend'e aktarılmak üzere JSON formatlanıyor:
      final String configJson = '{"fullname": "${_nameController.text}", "username": "${_usernameController.text}", "password": "${_passwordController.text}"}';
      widget.onNext(configJson);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: isDark
                ? [const Color(0xFF1E1E2F), const Color(0xFF121212)]
                : [const Color(0xFFE8E8FA), const Color(0xFFFFFFFF)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Stack(
          children: [
            // Arka Plana Bulanık Daireler
            Positioned(
              top: -100,
              left: -100,
              child: Container(
                width: 400,
                height: 400,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: theme.colorScheme.primary.withOpacity(0.3),
                ),
              ),
            ),
            Positioned(
              bottom: -150,
              right: -50,
              child: Container(
                width: 500,
                height: 500,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: theme.colorScheme.secondary.withOpacity(0.2),
                ),
              ),
            ),

            Center(
              child: GlassContainer(
                width: 700,
                height: 600,
                padding: const EdgeInsets.all(40),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            "Kullanıcı Bilgileri",
                            style: theme.textTheme.headlineLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: theme.colorScheme.primary,
                            ),
                          ),
                          IconButton(
                            icon: Icon(isDark ? Icons.light_mode : Icons.dark_mode),
                            onPressed: widget.onToggleTheme,
                            tooltip: "Temayı Değiştir",
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Text(
                        "Sistemi kullanacak ana hesabı oluşturun.",
                        style: theme.textTheme.bodyLarge?.copyWith(color: Colors.grey),
                      ),
                      const SizedBox(height: 40),

                      // Form Alanları
                      Expanded(
                        child: SingleChildScrollView(
                          child: Column(
                            children: [
                              TextFormField(
                                controller: _nameController,
                                decoration: const InputDecoration(
                                  labelText: "Ad Soyad",
                                  prefixIcon: Icon(Icons.badge),
                                  border: OutlineInputBorder(),
                                ),
                                validator: (value) =>
                                    value == null || value.isEmpty ? "Lütfen adınızı girin" : null,
                              ),
                              const SizedBox(height: 20),
                              TextFormField(
                                controller: _usernameController,
                                decoration: const InputDecoration(
                                  labelText: "Kullanıcı Adı",
                                  prefixIcon: Icon(Icons.person),
                                  border: OutlineInputBorder(),
                                ),
                                validator: (value) =>
                                    value == null || value.isEmpty ? "Kullanıcı adı gerekli" : null,
                              ),
                              const SizedBox(height: 20),
                              TextFormField(
                                controller: _passwordController,
                                obscureText: true,
                                decoration: const InputDecoration(
                                  labelText: "Parola",
                                  prefixIcon: Icon(Icons.lock),
                                  border: OutlineInputBorder(),
                                ),
                                validator: (value) =>
                                    value == null || value.length < 4 ? "En az 4 karakter girin" : null,
                              ),
                            ],
                          ),
                        ),
                      ),
                      
                      const SizedBox(height: 20),
                      
                      // Alt Butonlar
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          TextButton.icon(
                            onPressed: widget.onBack,
                            icon: const Icon(Icons.arrow_back),
                            label: const Text("Geri Dön"),
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                            ),
                          ),
                          ElevatedButton.icon(
                            onPressed: _submit,
                            icon: const Icon(Icons.arrow_forward),
                            label: const Text("İleri: Kurulum Özeti"),
                            style: theme.elevatedButtonTheme.style?.copyWith(
                              padding: const WidgetStatePropertyAll(
                                EdgeInsets.symmetric(horizontal: 32, vertical: 20),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
