import 'package:flutter/material.dart';
import 'app_theme.dart';
import 'chat_backend.dart';
import 'matrix_auth_service.dart';
import 'messaging_features.dart';
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
  ProviderDiscovery? _provider;
  int _generation = 0;

  @override
  void didUpdateWidget(covariant LoginScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.backend, widget.backend)) {
      _generation++;
      _busy = false;
      _provider = null;
      _error = null;
      _password.clear();
    }
  }

  bool _current(int generation, ChatBackend backend) =>
      mounted &&
      generation == _generation &&
      identical(backend, widget.backend);

  Future<void> _discover() async {
    final backend = widget.backend;
    if (backend is! MessagingFeatures || _busy) return;
    try {
      MatrixAuthService.providerUri(_server.text);
    } on FormatException {
      setState(() => _error = 'Enter a Matrix ID, server name or HTTPS URL.');
      return;
    }
    final generation = ++_generation;
    final input = _server.text.trim();
    setState(() {
      _busy = true;
      _error = null;
      _provider = null;
    });
    try {
      final provider = await (backend as MessagingFeatures).discoverProvider(
        input,
      );
      if (!_current(generation, backend)) return;
      setState(() {
        _provider = provider;
        _server.text = provider.homeserver.toString();
        if (input.startsWith('@') && _username.text.isEmpty) {
          _username.text = input;
        }
      });
    } catch (_) {
      if (_current(generation, backend)) {
        setState(
          () => _error =
              'Couldn’t discover sign-in options. Check the provider and connection.',
        );
      }
    } finally {
      if (_current(generation, backend)) setState(() => _busy = false);
    }
  }

  Future<void> _browserLogin(bool oidc) async {
    final backend = widget.backend;
    final provider = _provider;
    if (backend is! MessagingFeatures || provider == null || _busy) return;
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await (backend as MessagingFeatures).loginWithBrowser(
        provider,
        oidc: oidc,
      );
    } catch (_) {
      if (_current(generation, backend)) {
        setState(
          () => _error = 'Browser sign-in did not complete. You can try again.',
        );
      }
    } finally {
      if (_current(generation, backend)) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _server.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (!_form.currentState!.validate() || _busy) return;
    final backend = widget.backend;
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await backend.login(
        homeserver: backend is MessagingFeatures
            ? MatrixAuthService.providerUri(_server.text).toString()
            : _server.text.trim(),
        username: _username.text.trim(),
        password: _password.text,
      );
    } catch (_) {
      if (_current(generation, backend)) {
        setState(
          () => _error =
              'Couldn’t sign in. Check your server, credentials and connection.',
        );
      }
    } finally {
      if (_current(generation, backend)) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final features = widget.backend is MessagingFeatures;
    final password = _provider?.password ?? true;
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
                              enabled: !_busy,
                              onChanged: (_) => setState(() {
                                _generation++;
                                _provider = null;
                                _error = null;
                              }),
                              keyboardType: TextInputType.url,
                              textInputAction: TextInputAction.next,
                              autocorrect: false,
                              decoration: InputDecoration(
                                labelText: features
                                    ? 'Homeserver URL or Matrix ID'
                                    : 'Homeserver URL',
                                prefixIcon: const Icon(Icons.dns_outlined),
                              ),
                              validator: (value) {
                                if (features) {
                                  try {
                                    MatrixAuthService.providerUri(value ?? '');
                                    return null;
                                  } on FormatException {
                                    return 'Enter a Matrix ID or HTTPS homeserver';
                                  }
                                }
                                final uri = Uri.tryParse(value?.trim() ?? '');
                                return uri?.scheme == 'https' &&
                                        uri!.host.isNotEmpty &&
                                        uri.userInfo.isEmpty &&
                                        !uri.hasQuery &&
                                        !uri.hasFragment
                                    ? null
                                    : 'Enter an HTTPS homeserver URL';
                              },
                            ),
                            if (features) ...[
                              const SizedBox(height: 12),
                              OutlinedButton.icon(
                                onPressed: _busy ? null : _discover,
                                icon: const Icon(Icons.travel_explore),
                                label: const Text('Find sign-in options'),
                              ),
                              if (_provider?.sso == true) ...[
                                const SizedBox(height: 8),
                                OutlinedButton.icon(
                                  onPressed: _busy
                                      ? null
                                      : () => _browserLogin(false),
                                  icon: const Icon(Icons.open_in_browser),
                                  label: const Text('Continue with SSO'),
                                ),
                              ],
                              if (_provider?.oidc == true) ...[
                                const SizedBox(height: 8),
                                OutlinedButton.icon(
                                  onPressed: _busy
                                      ? null
                                      : () => _browserLogin(true),
                                  icon: const Icon(Icons.open_in_browser),
                                  label: const Text(
                                    'Continue with OpenID Connect',
                                  ),
                                ),
                              ],
                              if (_provider != null &&
                                  !_provider!.password &&
                                  !_provider!.sso &&
                                  !_provider!.oidc)
                                const Text(
                                  'No supported sign-in methods were advertised.',
                                ),
                            ],
                            if (password) ...[
                              const SizedBox(height: 12),
                              TextFormField(
                                controller: _username,
                                enabled: !_busy,
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
                                enabled: !_busy,
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
                            ],
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
                            if (password)
                              AccentButton(
                                palette: p,
                                label: _busy
                                    ? 'Connecting…'
                                    : 'Enter the matrix',
                                icon: Icons.arrow_forward_rounded,
                                onPressed: _busy ? null : _login,
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        features
                            ? 'Choose the sign-in methods advertised by your provider. Browser sign-in returns to this app.'
                            : 'Your account must already exist on the homeserver.',
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
