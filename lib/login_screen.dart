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

/// Element X ChooseAccountProvider: matrix.org or another provider.
enum AccountProviderChoice { matrixOrg, other }

const matrixOrgHomeserver = 'https://matrix.org';

class _LoginScreenState extends State<LoginScreen> {
  final _form = GlobalKey<FormState>();
  final _server = TextEditingController(text: matrixOrgHomeserver);
  final _serverFocus = FocusNode();
  AccountProviderChoice _choice = AccountProviderChoice.matrixOrg;
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

  void _chooseProvider(AccountProviderChoice choice) {
    if (_busy || choice == _choice) return;
    setState(() {
      _generation++;
      _choice = choice;
      _provider = null;
      _error = null;
      if (choice == AccountProviderChoice.matrixOrg) {
        _server.text = matrixOrgHomeserver;
      } else if (_isMatrixOrg(_server.text)) {
        _server.clear();
      }
    });
    if (choice == AccountProviderChoice.other) _serverFocus.requestFocus();
  }

  static bool _isMatrixOrg(String value) {
    final host = Uri.tryParse(
      value.contains('://') ? value.trim() : 'https://${value.trim()}',
    )?.host;
    return host == 'matrix.org' || host == 'matrix-client.matrix.org';
  }

  /// Host the user is about to sign in to, for the confirmation line.
  String? get _providerHost {
    final value = _server.text.trim();
    if (value.isEmpty) return null;
    if (_choice == AccountProviderChoice.matrixOrg) return 'matrix.org';
    try {
      return MatrixAuthService.providerUri(value).host;
    } on FormatException {
      return null;
    }
  }

  /// A full Matrix ID on another server cannot sign in to matrix.org.
  String? _providerMismatch() {
    if (_choice != AccountProviderChoice.matrixOrg) return null;
    final user = _username.text.trim();
    if (!user.startsWith('@')) return null;
    final colon = user.indexOf(':');
    if (colon < 0) return null;
    final domain = user.substring(colon + 1).toLowerCase();
    if (domain == 'matrix.org') return null;
    return 'This Matrix ID belongs to $domain. Choose Other and enter that '
        'provider to sign in there.';
  }

  @override
  void dispose() {
    _serverFocus.dispose();
    _server.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (!_form.currentState!.validate() || _busy) return;
    final mismatch = _providerMismatch();
    if (mismatch != null) {
      setState(() => _error = mismatch);
      return;
    }
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
                      Eyebrow('Matrix messaging, in depth', palette: p),
                      const SizedBox(height: 12),
                      Text(
                        'Every angle\nof the\nconversation.',
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
                        'Parallax keeps your conversations close — '
                        'encrypted, quick and warm.',
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
                            const SizedBox(height: 16),
                            Text(
                              'Account provider',
                              style: TextStyle(
                                color: p.muted,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 8),
                            _ProviderTile(
                              palette: p,
                              icon: Icons.public_rounded,
                              title: 'matrix.org',
                              subtitle:
                                  'Matrix.org is a large, free server on the '
                                  'public Matrix network for secure, '
                                  'decentralised communication, run by the '
                                  'Matrix.org Foundation.',
                              selected:
                                  _choice == AccountProviderChoice.matrixOrg,
                              onTap: _busy
                                  ? null
                                  : () => _chooseProvider(
                                      AccountProviderChoice.matrixOrg,
                                    ),
                            ),
                            const SizedBox(height: 8),
                            _ProviderTile(
                              palette: p,
                              icon: Icons.dns_outlined,
                              title: 'Other',
                              subtitle:
                                  'Use a different account provider, such as '
                                  'your own private server or a work account.',
                              selected: _choice == AccountProviderChoice.other,
                              onTap: _busy
                                  ? null
                                  : () => _chooseProvider(
                                      AccountProviderChoice.other,
                                    ),
                            ),
                            const SizedBox(height: 18),
                            if (_providerHost case final host?) ...[
                              Text(
                                'You’re about to sign in to $host',
                                style: TextStyle(
                                  color: p.foreground,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 12),
                            ],
                            TextFormField(
                              controller: _server,
                              focusNode: _serverFocus,
                              enabled: !_busy,
                              readOnly:
                                  _choice == AccountProviderChoice.matrixOrg,
                              onChanged: (_) => setState(() {
                                _generation++;
                                _provider = null;
                                _error = null;
                              }),
                              keyboardType: TextInputType.url,
                              textInputAction: TextInputAction.next,
                              autocorrect: false,
                              decoration: InputDecoration(
                                labelText:
                                    _choice == AccountProviderChoice.matrixOrg
                                    ? 'Homeserver'
                                    : features
                                    ? 'Homeserver URL or Matrix ID'
                                    : 'Homeserver URL',
                                helperText:
                                    _choice == AccountProviderChoice.other
                                    ? 'If your account is provided by your '
                                          'company or a community, enter its '
                                          'address (example: companyname.com).'
                                    : null,
                                helperMaxLines: 3,
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

class _ProviderTile extends StatelessWidget {
  const _ProviderTile({
    required this.palette,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });
  final AppPalette palette;
  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = palette;
    return Semantics(
      button: true,
      selected: selected,
      inMutuallyExclusiveGroup: true,
      child: Material(
        color: selected ? p.raised : Colors.transparent,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: selected ? p.accent : p.stroke,
                width: selected ? 2 : 1,
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, color: selected ? p.accent : p.muted),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          color: p.foreground,
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        style: TextStyle(
                          color: p.muted,
                          fontSize: 12,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  selected
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_unchecked_rounded,
                  color: selected ? p.accent : p.muted,
                  size: 20,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
