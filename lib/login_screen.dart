import 'package:flutter/material.dart';
import 'app_theme.dart';
import 'chat_backend.dart';
import 'widgets.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.backend, required this.palette});
  final ChatBackend backend;
  final AppPalette palette;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _form = GlobalKey<FormState>();
  final _server = TextEditingController(text: 'https://matrix.org');
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  bool _visible = false;
  String? _error;

  @override
  void dispose() {
    _server.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (!_form.currentState!.validate() || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.backend.login(
        homeserver: _server.text.trim(),
        username: _username.text.trim(),
        password: _password.text,
      );
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Couldn’t sign in. Check your server, credentials and connection.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    return Scaffold(
      body: GlowBackdrop(
        palette: p,
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(28, 32, 28, 32),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: Form(
                  key: _form,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: BrandMark(palette: p, size: 68),
                      ),
                      const SizedBox(height: 32),
                      Eyebrow('The conversation, reimagined', palette: p),
                      const SizedBox(height: 12),
                      Text(
                        'Matrix,\nbut make it\nmove.',
                        style: TextStyle(
                          fontSize: 49,
                          height: 1.04,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -2.5,
                          color: p.foreground,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'MatriXpress puts your conversations first — '
                        'with a little extra electricity.',
                        style: TextStyle(
                          color: p.muted,
                          fontSize: 16,
                          height: 1.45,
                        ),
                      ),
                      const SizedBox(height: 34),
                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: p.surface,
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(color: p.stroke),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              'SIGN IN TO MATRIX',
                              style: TextStyle(
                                color: p.secondary,
                                fontWeight: FontWeight.w800,
                                fontSize: 11,
                                letterSpacing: 1.8,
                              ),
                            ),
                            const SizedBox(height: 20),
                            TextFormField(
                              controller: _server,
                              keyboardType: TextInputType.url,
                              textInputAction: TextInputAction.next,
                              autocorrect: false,
                              decoration: const InputDecoration(
                                labelText: 'Homeserver URL',
                                prefixIcon: Icon(Icons.dns_outlined),
                              ),
                              validator: (value) {
                                final uri = Uri.tryParse(value?.trim() ?? '');
                                return uri?.scheme == 'https' &&
                                        uri!.host.isNotEmpty &&
                                        uri.userInfo.isEmpty &&
                                        uri.query.isEmpty &&
                                        uri.fragment.isEmpty
                                    ? null
                                    : 'Enter an HTTPS homeserver URL';
                              },
                            ),
                            const SizedBox(height: 12),
                            TextFormField(
                              controller: _username,
                              textInputAction: TextInputAction.next,
                              autocorrect: false,
                              decoration: const InputDecoration(
                                labelText: 'Matrix ID or username',
                                prefixIcon: Icon(Icons.alternate_email),
                              ),
                              validator: (v) => v == null || v.trim().isEmpty
                                  ? 'Enter your username'
                                  : null,
                            ),
                            const SizedBox(height: 12),
                            TextFormField(
                              controller: _password,
                              obscureText: !_visible,
                              textInputAction: TextInputAction.done,
                              onFieldSubmitted: (_) => _login(),
                              decoration: InputDecoration(
                                labelText: 'Password',
                                prefixIcon: const Icon(Icons.lock_outline),
                                suffixIcon: IconButton(
                                  tooltip: _visible
                                      ? 'Hide password'
                                      : 'Show password',
                                  onPressed: () =>
                                      setState(() => _visible = !_visible),
                                  icon: Icon(
                                    _visible
                                        ? Icons.visibility_off_outlined
                                        : Icons.visibility_outlined,
                                  ),
                                ),
                              ),
                              validator: (v) => v == null || v.isEmpty
                                  ? 'Enter your password'
                                  : null,
                            ),
                            if (_error != null) ...[
                              const SizedBox(height: 14),
                              Text(
                                _error!,
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.error,
                                ),
                              ),
                            ],
                            const SizedBox(height: 22),
                            AccentButton(
                              palette: p,
                              label: _busy ? 'Connecting…' : 'Enter the matrix',
                              icon: Icons.arrow_forward_rounded,
                              onPressed: _busy ? null : _login,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        'Password sign-in only in this build. '
                        'Your account must already exist on the homeserver.',
                        style: TextStyle(
                          color: p.muted,
                          fontSize: 12,
                          height: 1.4,
                        ),
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
