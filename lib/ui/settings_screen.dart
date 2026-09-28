import 'package:flutter/material.dart';

import '../core/app_controller.dart';
import 'widgets.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.app,
    required this.themeMode,
    required this.onThemeChanged,
  });
  final AppController app;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeChanged;
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _server;
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _showPassword = false;
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _server = TextEditingController(text: widget.app.account?.server ?? '');
  }

  @override
  void dispose() {
    _server.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (!_form.currentState!.validate() || _submitting) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await widget.app.login(
        _server.text.trim(),
        _username.text.trim(),
        _password.text,
      );
      _password.clear();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Connected. Your library is ready.')),
        );
      }
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    return ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        const SectionHeading('Settings', subtitle: 'Make yourself at home'),
        Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 740),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Appearance',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final mode in ThemeMode.values)
                        ChoiceChip(
                          avatar: Icon(switch (mode) {
                            ThemeMode.system => Icons.brightness_auto_outlined,
                            ThemeMode.light => Icons.light_mode_outlined,
                            ThemeMode.dark => Icons.dark_mode_outlined,
                          }, size: 18),
                          label: Text(switch (mode) {
                            ThemeMode.system => 'System',
                            ThemeMode.light => 'Light',
                            ThemeMode.dark => 'Dark',
                          }),
                          selected: widget.themeMode == mode,
                          onSelected: (_) => widget.onThemeChanged(mode),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Text size and reduced motion follow your device accessibility settings.',
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Divider(),
                  ),
                  Text(
                    'Server & account',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 16),
                  if (app.isAuthenticated) ...[
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const CircleAvatar(
                        child: Icon(Icons.person_outline_rounded),
                      ),
                      title: Text(app.account?.username ?? 'Signed in'),
                      subtitle: SelectableText(app.account?.server ?? ''),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        OutlinedButton.icon(
                          onPressed: app.busy
                              ? null
                              : () => runUiAction(context, app.refresh),
                          icon: const Icon(Icons.sync_rounded),
                          label: const Text('Sync now'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => runUiAction(context, () async {
                            if (!await confirmAction(
                              context,
                              title: 'Sign out?',
                              message: 'Offline files and listening history stay on this device, but are locked until you sign back into this account. Sign out before connecting to another server.',
                              confirmLabel: 'Sign out',
                            )) {
                              return;
                            }
                            await app.logout();
                          }),
                          icon: const Icon(Icons.logout_rounded),
                          label: const Text('Sign out'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Text(
                      app.isOffline
                          ? 'Offline · Downloaded tracks are still available.'
                          : 'Connected to your personal music server.',
                    ),
                    if (app.pendingEventCount > 0)
                      Text(
                        '${app.pendingEventCount} listening segments waiting to sync.',
                      ),
                  ] else
                    Form(
                      key: _form,
                      child: AutofillGroup(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const Text(
                              'Use your own Yun server. Your library, uploads, and listening history stay with that server.',
                            ),
                            const SizedBox(height: 20),
                            TextFormField(
                              controller: _server,
                              enabled: !_submitting,
                              keyboardType: TextInputType.url,
                              autocorrect: false,
                              decoration: const InputDecoration(
                                labelText: 'Server URL',
                                hintText: 'https://music.example.com',
                                helperText: 'HTTPS required. HTTP is allowed for loopback development.',
                              ),
                              validator: (value) {
                                final uri = Uri.tryParse(value?.trim() ?? '');
                                if (uri == null ||
                                    !uri.hasAuthority ||
                                    uri.host.isEmpty ||
                                    !['https', 'http'].contains(uri.scheme)) {
                                  return 'Enter a complete server URL';
                                }
                                if (uri.scheme == 'http' &&
                                    ![
                                      'localhost',
                                      '127.0.0.1',
                                      '::1',
                                      '[::1]',
                                    ].contains(uri.host)) {
                                  return 'Use HTTPS to protect your credentials';
                                }
                                if (uri.userInfo.isNotEmpty ||
                                    uri.hasQuery ||
                                    uri.hasFragment) {
                                  return 'Do not include credentials, queries, or fragments';
                                }
                                return null;
                              },
                              textInputAction: TextInputAction.next,
                            ),
                            const SizedBox(height: 16),
                            TextFormField(
                              controller: _username,
                              enabled: !_submitting,
                              autocorrect: false,
                              autofillHints: const [AutofillHints.username],
                              decoration: const InputDecoration(
                                labelText: 'Username',
                              ),
                              validator: (value) =>
                                  value == null || value.trim().isEmpty
                                  ? 'Enter your username'
                                  : null,
                              textInputAction: TextInputAction.next,
                            ),
                            const SizedBox(height: 16),
                            TextFormField(
                              controller: _password,
                              enabled: !_submitting,
                              obscureText: !_showPassword,
                              autocorrect: false,
                              enableSuggestions: false,
                              autofillHints: const [AutofillHints.password],
                              decoration: InputDecoration(
                                labelText: 'Password',
                                suffixIcon: IconButton(
                                  tooltip: _showPassword
                                      ? 'Hide password'
                                      : 'Show password',
                                  onPressed: () => setState(
                                    () => _showPassword = !_showPassword,
                                  ),
                                  icon: Icon(
                                    _showPassword
                                        ? Icons.visibility_off_outlined
                                        : Icons.visibility_outlined,
                                  ),
                                ),
                              ),
                              validator: (value) =>
                                  value == null || value.isEmpty
                                  ? 'Enter your password'
                                  : null,
                              onFieldSubmitted: (_) => _login(),
                            ),
                            const SizedBox(height: 20),
                            if (_error != null)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 16),
                                child: Semantics(
                                  liveRegion: true,
                                  child: Text(
                                    _error!,
                                    style: TextStyle(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .error,
                                    ),
                                  ),
                                ),
                              ),
                            if (_submitting)
                              const Padding(
                                padding: EdgeInsets.only(bottom: 16),
                                child: QuietProgress(
                                  label: 'Connecting to server',
                                ),
                              ),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: FilledButton.icon(
                                onPressed: _submitting ? null : _login,
                                icon: const Icon(Icons.login_rounded),
                                label: Text(
                                  _submitting ? 'Connecting…' : 'Connect',
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Divider(),
                  ),
                  Text(
                    'Keyboard shortcuts',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Ctrl / ⌘ + F     Search library\nCtrl / ⌘ + Space     Play / pause\nCtrl / ⌘ + → or ←     Next / previous track\nCtrl / ⌘ + U     Upload files\nTab / Shift + Tab     Move focus',
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Divider(),
                  ),
                  Text('Yun', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  const Text(
                    'A quiet place for your own music. Listening statistics are personal; no third-party tracking service is used.',
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
