part of '../mail_home_page.dart';

enum _MailboxSettingsActionKind { edit, reauthorize, remove }

class _MailboxSettingsAction {
  const _MailboxSettingsAction({required this.kind, required this.item});

  final _MailboxSettingsActionKind kind;
  final VaultMailboxItem item;
}

class _MailboxSettingsDialog extends StatelessWidget {
  const _MailboxSettingsDialog({
    required this.items,
    required this.selectedMailboxId,
  });

  final List<VaultMailboxItem> items;
  final String? selectedMailboxId;

  @override
  Widget build(BuildContext context) {
    final sorted = [...items]..sort((a, b) {
      if (a.id == selectedMailboxId) return -1;
      if (b.id == selectedMailboxId) return 1;
      return a.address.compareTo(b.address);
    });
    return AlertDialog(
      title: const Text('Mailboxes'),
      content: _DialogContent(
        width: 560,
        maxHeight: 680,
        child: ListView.separated(
          shrinkWrap: true,
          itemCount: sorted.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, index) {
            final item = sorted[index];
            final label =
                item.displayName.trim().isEmpty
                    ? item.address
                    : item.displayName;
            return ListTile(
              leading: Icon(
                item.kind == VaultItemKind.oauth
                    ? Icons.open_in_browser
                    : Icons.key_outlined,
              ),
              title: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                '${item.address} - ${item.provider}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: PopupMenuButton<_MailboxSettingsActionKind>(
                tooltip: 'Mailbox actions',
                onSelected:
                    (kind) => Navigator.of(
                      context,
                    ).pop(_MailboxSettingsAction(kind: kind, item: item)),
                itemBuilder:
                    (context) => [
                      const PopupMenuItem(
                        value: _MailboxSettingsActionKind.edit,
                        child: ListTile(
                          leading: Icon(Icons.settings_outlined),
                          title: Text('Settings'),
                          dense: true,
                        ),
                      ),
                      if (item.kind == VaultItemKind.oauth)
                        const PopupMenuItem(
                          value: _MailboxSettingsActionKind.reauthorize,
                          child: ListTile(
                            leading: Icon(Icons.refresh),
                            title: Text('Reauthorize OAuth'),
                            dense: true,
                          ),
                        ),
                      const PopupMenuItem(
                        value: _MailboxSettingsActionKind.remove,
                        child: ListTile(
                          leading: Icon(Icons.delete_outline),
                          title: Text('Remove'),
                          dense: true,
                        ),
                      ),
                    ],
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _MailboxEditDialog extends StatefulWidget {
  const _MailboxEditDialog({required this.item});

  final VaultMailboxItem item;

  @override
  State<_MailboxEditDialog> createState() => _MailboxEditDialogState();
}

class _MailboxEditDialogState extends State<_MailboxEditDialog> {
  late final TextEditingController _displayName = TextEditingController(
    text: widget.item.displayName,
  );
  late final TextEditingController _username = TextEditingController(
    text:
        widget.item.username.trim().isEmpty
            ? _defaultUsernameForAddress(widget.item.address)
            : widget.item.username,
  );
  late final TextEditingController _secret = TextEditingController(
    text:
        widget.item.kind == VaultItemKind.oauth &&
                !_providerSupportsOAuth(widget.item.provider)
            ? ''
            : widget.item.secret,
  );
  late final TextEditingController _imapHost = TextEditingController(
    text: widget.item.imapHost,
  );
  late final TextEditingController _imapPort = TextEditingController(
    text: widget.item.imapPort.toString(),
  );
  late final TextEditingController _smtpHost = TextEditingController(
    text: widget.item.smtpHost,
  );
  late final TextEditingController _smtpPort = TextEditingController(
    text: widget.item.smtpPort.toString(),
  );
  late String _provider = widget.item.provider;
  late String _authMode =
      widget.item.kind == VaultItemKind.oauth &&
              _providerSupportsOAuth(widget.item.provider)
          ? 'oauth'
          : 'app_password';
  late bool _useTls = widget.item.useTls;
  String? _error;

  @override
  void dispose() {
    _displayName.dispose();
    _username.dispose();
    _secret.dispose();
    _imapHost.dispose();
    _imapPort.dispose();
    _smtpHost.dispose();
    _smtpPort.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final oauthAvailable = _providerSupportsOAuth(_provider);
    return AlertDialog(
      title: const Text('Mailbox settings'),
      content: _DialogContent(
        width: 460,
        maxHeight: 680,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.alternate_email),
              title: Text(widget.item.address),
              subtitle: Text(widget.item.id),
            ),
            TextField(
              controller: _displayName,
              decoration: const InputDecoration(labelText: 'Display name'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _username,
              decoration: const InputDecoration(
                labelText: 'Username',
                helperText:
                    'Defaults to the mailbox address. Edit only if your provider uses a different login name.',
              ),
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              initialValue: _provider,
              decoration: const InputDecoration(labelText: 'Provider'),
              items: const [
                DropdownMenuItem(
                  value: 'imap',
                  child: Text('Generic IMAP/SMTP'),
                ),
                DropdownMenuItem(value: 'gmail', child: Text('Gmail')),
                DropdownMenuItem(value: 'outlook', child: Text('Outlook')),
                DropdownMenuItem(value: 'icloud', child: Text('iCloud')),
              ],
              onChanged:
                  (value) => setState(() {
                    _provider = value ?? 'imap';
                    if (!_providerSupportsOAuth(_provider) &&
                        _authMode == 'oauth') {
                      _authMode = 'app_password';
                      _secret.clear();
                    }
                  }),
            ),
            const SizedBox(height: 10),
            SegmentedButton<String>(
              segments: [
                const ButtonSegment(
                  value: 'app_password',
                  icon: Icon(Icons.key_outlined),
                  label: Text('Password'),
                ),
                ButtonSegment(
                  value: 'oauth',
                  enabled: oauthAvailable,
                  icon: const Icon(Icons.open_in_browser),
                  label: const Text('OAuth'),
                ),
              ],
              selected: {_authMode},
              onSelectionChanged: (values) {
                final next = values.single;
                if (next == 'oauth' && !oauthAvailable) return;
                setState(() {
                  if (_authMode == 'oauth' && next == 'app_password') {
                    _secret.clear();
                  }
                  _authMode = next;
                });
              },
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _secret,
              obscureText: true,
              enabled: _authMode == 'app_password',
              decoration: InputDecoration(
                labelText:
                    _authMode == 'oauth'
                        ? 'OAuth token is managed by reauthorization'
                        : 'App password or token',
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _imapHost,
                    decoration: const InputDecoration(labelText: 'IMAP host'),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 96,
                  child: TextField(
                    controller: _imapPort,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Port'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _smtpHost,
                    decoration: const InputDecoration(labelText: 'SMTP host'),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 96,
                  child: TextField(
                    controller: _smtpPort,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Port'),
                  ),
                ),
              ],
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Use TLS'),
              value: _useTls,
              onChanged: (value) => setState(() => _useTls = value),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: _save,
          icon: const Icon(Icons.check),
          label: const Text('Save'),
        ),
      ],
    );
  }

  void _save() {
    final imapPort = int.tryParse(_imapPort.text.trim());
    final smtpPort = int.tryParse(_smtpPort.text.trim());
    if (imapPort == null || smtpPort == null) {
      setState(() => _error = 'Ports must be numbers.');
      return;
    }
    if (_authMode == 'app_password' && _secret.text.isEmpty) {
      setState(() => _error = 'Enter the app password or token.');
      return;
    }
    final oauth = _authMode == 'oauth';
    final displayName =
        _displayName.text.trim().isEmpty
            ? widget.item.address
            : _displayName.text.trim();
    final username =
        _username.text.trim().isEmpty
            ? _defaultUsernameForAddress(widget.item.address)
            : _username.text.trim();
    Navigator.of(context).pop(
      VaultMailboxItem(
        id: widget.item.id,
        kind: oauth ? VaultItemKind.oauth : VaultItemKind.imapSmtp,
        address: widget.item.address,
        displayName: displayName,
        provider: _provider,
        username: username,
        secret: oauth ? widget.item.secret : _secret.text,
        refreshToken: oauth ? widget.item.refreshToken : '',
        tokenExpiresAt: oauth ? widget.item.tokenExpiresAt : null,
        tokenScope: oauth ? widget.item.tokenScope : '',
        oauthClientId: oauth ? widget.item.oauthClientId : '',
        oauthClientSecret: oauth ? widget.item.oauthClientSecret : '',
        imapHost: _imapHost.text.trim(),
        imapPort: imapPort,
        smtpHost: _smtpHost.text.trim(),
        smtpPort: smtpPort,
        useTls: _useTls,
      ),
    );
  }
}

class _AddMailboxDialog extends StatefulWidget {
  const _AddMailboxDialog({
    required this.document,
    required this.vaultCrypto,
    required this.oauthClient,
    required this.gmailOAuthClientId,
    required this.gmailOAuthClientSecret,
    required this.gmailAndroidOAuthClientId,
    required this.gmailAndroidOAuthClientSecret,
    required this.gmailAndroidOAuthRedirectUri,
    required this.outlookOAuthClientId,
    required this.outlookOAuthClientSecret,
    required this.outlookAndroidOAuthClientId,
    required this.outlookAndroidOAuthClientSecret,
    required this.outlookAndroidOAuthRedirectUri,
  });

  final VaultDocument document;
  final VaultCrypto vaultCrypto;
  final OAuthLoopbackClient oauthClient;
  final String gmailOAuthClientId;
  final String gmailOAuthClientSecret;
  final String gmailAndroidOAuthClientId;
  final String gmailAndroidOAuthClientSecret;
  final String gmailAndroidOAuthRedirectUri;
  final String outlookOAuthClientId;
  final String outlookOAuthClientSecret;
  final String outlookAndroidOAuthClientId;
  final String outlookAndroidOAuthClientSecret;
  final String outlookAndroidOAuthRedirectUri;

  @override
  State<_AddMailboxDialog> createState() => _AddMailboxDialogState();
}

class _AddMailboxResult {
  const _AddMailboxResult({required this.mailbox, required this.document});

  final MailboxSummary mailbox;
  final VaultDocument document;
}

class _AddMailboxDialogState extends State<_AddMailboxDialog> {
  final _address = TextEditingController();
  final _displayName = TextEditingController();
  final _username = TextEditingController();
  final _secret = TextEditingController();
  final _imapHost = TextEditingController();
  final _imapPort = TextEditingController(text: '993');
  final _smtpHost = TextEditingController();
  final _smtpPort = TextEditingController(text: '587');
  String _provider = 'imap';
  String _authMode = 'app_password';
  bool _useTls = true;
  bool _submitting = false;
  String? _error;
  String? _status;
  MailboxCredential? _pendingCredential;
  String _lastAutoUsername = '';
  bool _syncingUsernameFromAddress = false;
  bool _usernameManuallyEdited = false;

  @override
  void initState() {
    super.initState();
    _address.addListener(_prefillHosts);
    _username.addListener(_handleUsernameChanged);
  }

  @override
  void dispose() {
    _address.removeListener(_prefillHosts);
    _username.removeListener(_handleUsernameChanged);
    _address.dispose();
    _displayName.dispose();
    _username.dispose();
    _secret.dispose();
    _imapHost.dispose();
    _imapPort.dispose();
    _smtpHost.dispose();
    _smtpPort.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final oauthAvailable = _providerSupportsOAuth(_provider);
    return AlertDialog(
      title: const Text('Add mailbox'),
      content: _DialogContent(
        width: 430,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _address,
              decoration: const InputDecoration(labelText: 'Mailbox address'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _displayName,
              decoration: const InputDecoration(labelText: 'Display name'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _username,
              decoration: const InputDecoration(
                labelText: 'Username',
                helperText:
                    'Defaults to the mailbox address. Edit only if your provider uses a different login name.',
              ),
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              initialValue: _provider,
              decoration: const InputDecoration(labelText: 'Provider'),
              items: const [
                DropdownMenuItem(
                  value: 'imap',
                  child: Text('Generic IMAP/SMTP'),
                ),
                DropdownMenuItem(value: 'gmail', child: Text('Gmail')),
                DropdownMenuItem(value: 'outlook', child: Text('Outlook')),
                DropdownMenuItem(value: 'icloud', child: Text('iCloud')),
              ],
              onChanged: (value) {
                setState(() {
                  _provider = value ?? 'imap';
                  _applyProviderPreset();
                  if (!_providerSupportsOAuth(_provider) &&
                      _authMode == 'oauth') {
                    _authMode = 'app_password';
                    _secret.clear();
                  }
                });
              },
            ),
            const SizedBox(height: 10),
            SegmentedButton<String>(
              segments: [
                const ButtonSegment(
                  value: 'app_password',
                  icon: Icon(Icons.key_outlined),
                  label: Text('Password'),
                ),
                ButtonSegment(
                  value: 'oauth',
                  enabled: oauthAvailable,
                  icon: const Icon(Icons.open_in_browser),
                  label: const Text('OAuth'),
                ),
              ],
              selected: {_authMode},
              onSelectionChanged: (values) {
                final next = values.single;
                if (next == 'oauth' && !oauthAvailable) return;
                setState(() {
                  if (_authMode == 'oauth' && next == 'app_password') {
                    _secret.clear();
                  }
                  _authMode = next;
                });
              },
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _secret,
              obscureText: true,
              enabled: _authMode == 'app_password',
              decoration: InputDecoration(
                labelText:
                    _authMode == 'oauth'
                        ? 'OAuth token comes from browser authorization'
                        : 'App password or token',
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _imapHost,
                    decoration: const InputDecoration(labelText: 'IMAP host'),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 96,
                  child: TextField(
                    controller: _imapPort,
                    decoration: const InputDecoration(labelText: 'Port'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _smtpHost,
                    decoration: const InputDecoration(labelText: 'SMTP host'),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 96,
                  child: TextField(
                    controller: _smtpPort,
                    decoration: const InputDecoration(labelText: 'Port'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Use TLS'),
              value: _useTls,
              onChanged: (value) => setState(() => _useTls = value),
            ),
            if (_authMode == 'oauth') ...[
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: Builder(
                  builder: (context) {
                    final clientIdMissing =
                        _oauthClientIdForProvider(_provider).isEmpty;
                    final clientSecretMissing =
                        !io.Platform.isAndroid &&
                        _provider == 'gmail' &&
                        _oauthClientSecretForProvider(_provider).isEmpty;
                    return Text(
                      clientIdMissing
                          ? 'OAuth client id is not configured for this provider.'
                          : clientSecretMissing
                          ? 'Google Desktop OAuth may require the client secret from Google Cloud.'
                          : _usesGoogleAndroidOAuth(_provider)
                          ? 'Android will use Google account authorization.'
                          : 'OAuth will open the provider in your browser.',
                      style: TextStyle(
                        color:
                            clientIdMissing || clientSecretMissing
                                ? Theme.of(context).colorScheme.error
                                : Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                      ),
                    );
                  },
                ),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            if (_status != null) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _status!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: _submitting ? null : _submit,
          icon: Icon(
            _authMode == 'oauth'
                ? Icons.open_in_browser
                : Icons.fact_check_outlined,
          ),
          label: Text(
            _authMode == 'oauth' ? 'Authorize and add' : 'Verify and add',
          ),
        ),
      ],
    );
  }

  Future<void> _submit() async {
    setState(() {
      _submitting = true;
      _error = null;
      _status =
          _authMode == 'oauth' ? 'Waiting for provider authorization...' : null;
    });
    if (_authMode == 'oauth') {
      await _submitOAuth();
      return;
    }
    try {
      final address = _address.text.trim();
      final vaultItemId = widget.vaultCrypto.newVaultItemId(address);
      final credential = _buildCredential(
        accountId: vaultItemId,
        address: address,
      );
      _pendingCredential = credential;
      await const SocketMailTransport().validateCredential(
        credential: credential,
      );
      final document = widget.document.upsertMailbox(
        VaultMailboxItem(
          id: vaultItemId,
          kind: VaultItemKind.imapSmtp,
          address: address,
          displayName: credential.displayName,
          provider: _provider,
          username: credential.username,
          secret: credential.secret,
          imapHost: credential.imapHost,
          imapPort: credential.imapPort,
          smtpHost: credential.smtpHost,
          smtpPort: credential.smtpPort,
          useTls: credential.useTls,
        ),
      );
      final mailbox = MailboxSummary(
        id: vaultItemId,
        address: address,
        displayName: _displayName.text.trim(),
        provider: _provider,
        authType: 'app_password',
        vaultItemId: vaultItemId,
      );
      if (mounted) {
        Navigator.of(
          context,
        ).pop(_AddMailboxResult(mailbox: mailbox, document: document));
      }
    } catch (error) {
      setState(() {
        final credential = _pendingCredential;
        _error =
            credential == null
                ? error.toString()
                : const MailboxSetupDiagnostics().message(
                  provider: _provider,
                  credential: credential,
                  error: error,
                );
        _submitting = false;
        _status = null;
      });
    } finally {
      _pendingCredential = null;
    }
  }

  Future<void> _submitOAuth() async {
    try {
      final address = _address.text.trim();
      final clientId = _oauthClientIdForProvider(_provider);
      if (clientId.isEmpty) {
        throw StateError('OAuth client id is not configured for $_provider.');
      }
      final clientSecret = _oauthClientSecretForProvider(_provider);
      final oauthProvider = oauthProviderConfig(_provider);
      final vaultItemId = widget.vaultCrypto.newVaultItemId(address);
      final tokenSet = await _authorizeOAuthForCurrentPlatform(
        oauthClient: widget.oauthClient,
        provider: oauthProvider,
        clientId: clientId,
        androidClientId: _oauthAndroidClientIdForProvider(_provider),
        clientSecret: clientSecret,
        loginHint: address,
        mobileRedirectUri: _oauthMobileRedirectUriForProvider(_provider),
        forceAccountPicker: true,
        onProgress: _setOAuthProgress,
      );
      final item = oauthMailboxItem(
        id: vaultItemId,
        address: address,
        displayName: _displayName.text.trim(),
        provider: oauthProvider,
        tokenSet: tokenSet,
        oauthClientId: clientId,
        oauthClientSecret: clientSecret,
      );
      final credential = item.toCredential();
      _pendingCredential = credential;
      if (mounted) {
        setState(
          () => _status = _oauthValidationMessage(oauthProvider.provider),
        );
      }
      await const SocketMailTransport().validateCredential(
        credential: credential,
      );
      final document = widget.document.upsertMailbox(item);
      final mailbox = MailboxSummary(
        id: vaultItemId,
        address: address,
        displayName: _displayName.text.trim(),
        provider: oauthProvider.provider,
        authType: 'oauth',
        vaultItemId: vaultItemId,
      );
      if (mounted) {
        Navigator.of(
          context,
        ).pop(_AddMailboxResult(mailbox: mailbox, document: document));
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          final credential = _pendingCredential;
          _error =
              credential == null
                  ? error.toString()
                  : const MailboxSetupDiagnostics().message(
                    provider: _provider,
                    credential: credential,
                    error: error,
                  );
          _submitting = false;
          _status = null;
        });
      }
    } finally {
      _pendingCredential = null;
    }
  }

  MailboxCredential _buildCredential({
    required String accountId,
    required String address,
  }) {
    final displayName =
        _displayName.text.trim().isEmpty ? address : _displayName.text.trim();
    final username =
        _username.text.trim().isEmpty
            ? _defaultUsernameForAddress(address)
            : _username.text.trim();
    return MailboxCredential(
      accountId: accountId,
      address: address,
      displayName: displayName,
      imapHost: _imapHost.text.trim(),
      imapPort: int.tryParse(_imapPort.text.trim()) ?? 993,
      smtpHost: _smtpHost.text.trim(),
      smtpPort: int.tryParse(_smtpPort.text.trim()) ?? 587,
      username: username,
      secret: _secret.text,
      useTls: _useTls,
    );
  }

  void _prefillHosts() {
    final address = _address.text.trim();
    final defaultUsername = _defaultUsernameForAddress(address);
    if (!_usernameManuallyEdited) {
      _setAutoUsername(defaultUsername);
    }
    if (!_looksCompleteEmailAddress(address)) return;
    _applyProviderPreset();
  }

  void _handleUsernameChanged() {
    if (_syncingUsernameFromAddress) return;
    if (_username.text != _lastAutoUsername) {
      _usernameManuallyEdited = true;
    }
  }

  void _setAutoUsername(String value) {
    if (_username.text == value && _lastAutoUsername == value) return;
    _syncingUsernameFromAddress = true;
    _lastAutoUsername = value;
    _username.text = value;
    _syncingUsernameFromAddress = false;
  }

  void _setOAuthProgress(OAuthAuthorizationProgress progress) {
    if (!mounted) return;
    setState(() => _status = _oauthProgressMessage(progress, _provider));
  }

  bool _looksCompleteEmailAddress(String value) {
    final parts = value.split('@');
    if (parts.length != 2) return false;
    final local = parts.first.trim();
    final domain = parts.last.trim();
    if (local.isEmpty || domain.isEmpty || !domain.contains('.')) return false;
    return domain.split('.').every((part) => part.trim().isNotEmpty);
  }

  void _applyProviderPreset() {
    final preset = presetForProvider(_provider, _address.text.trim());
    _imapHost.text = preset.imapHost;
    _imapPort.text = preset.imapPort.toString();
    _smtpHost.text = preset.smtpHost;
    _smtpPort.text = preset.smtpPort.toString();
    _useTls = preset.useTls;
  }

  String _oauthClientIdForProvider(String provider) {
    final vaultConfig = widget.document.oauthProviderFor(provider);
    final normalizedProvider = normalizeOAuthProviderKey(provider);
    if (io.Platform.isAndroid && normalizedProvider != 'gmail') {
      final androidClientId = vaultConfig?.androidClientId.trim() ?? '';
      if (androidClientId.isNotEmpty) return androidClientId;
      return switch (normalizedProvider) {
        'outlook' => widget.outlookAndroidOAuthClientId.trim(),
        _ => '',
      };
    }
    final vaultClientId = vaultConfig?.clientId.trim() ?? '';
    if (vaultClientId.isNotEmpty) return vaultClientId;
    return switch (normalizedProvider) {
      'gmail' => widget.gmailOAuthClientId.trim(),
      'outlook' => widget.outlookOAuthClientId.trim(),
      _ => '',
    };
  }

  String _oauthClientSecretForProvider(String provider) {
    final vaultConfig = widget.document.oauthProviderFor(provider);
    final normalizedProvider = normalizeOAuthProviderKey(provider);
    if (io.Platform.isAndroid && normalizedProvider != 'gmail') {
      if (vaultConfig?.androidClientId.trim().isNotEmpty == true) {
        return vaultConfig!.androidClientSecret.trim();
      }
      return switch (normalizedProvider) {
        'outlook' => widget.outlookAndroidOAuthClientSecret.trim(),
        _ => '',
      };
    }
    if (vaultConfig?.clientId.trim().isNotEmpty == true) {
      return vaultConfig!.clientSecret.trim();
    }
    return switch (normalizedProvider) {
      'gmail' => widget.gmailOAuthClientSecret.trim(),
      'outlook' => widget.outlookOAuthClientSecret.trim(),
      _ => '',
    };
  }

  String _oauthAndroidClientIdForProvider(String provider) {
    if (!_usesGoogleAndroidOAuth(provider)) return '';
    final vaultConfig = widget.document.oauthProviderFor(provider);
    final clientId = vaultConfig?.androidClientId.trim() ?? '';
    if (clientId.isNotEmpty) return clientId;
    return widget.gmailAndroidOAuthClientId.trim();
  }

  Uri? _oauthMobileRedirectUriForProvider(String provider) {
    if (!io.Platform.isAndroid) return null;
    if (_usesGoogleAndroidOAuth(provider)) return null;
    final vaultConfig = widget.document.oauthProviderFor(provider);
    final vaultRedirectUri = vaultConfig?.androidRedirectUri.trim() ?? '';
    if (vaultRedirectUri.isNotEmpty) {
      return _parseOAuthRedirectUri(vaultRedirectUri);
    }
    final buildRedirectUri = switch (provider) {
      'gmail' => widget.gmailAndroidOAuthRedirectUri.trim(),
      'outlook' => widget.outlookAndroidOAuthRedirectUri.trim(),
      _ => '',
    };
    if (buildRedirectUri.isEmpty) return null;
    return _parseOAuthRedirectUri(buildRedirectUri);
  }

  Uri _parseOAuthRedirectUri(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null || !uri.hasScheme) {
      throw StateError('Android OAuth redirect URI is invalid.');
    }
    return uri;
  }
}
