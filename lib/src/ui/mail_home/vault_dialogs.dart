part of '../mail_home_page.dart';

class _LocalVaultCreationInput {
  const _LocalVaultCreationInput({
    required this.displayName,
    required this.password,
    required this.enableQuickUnlock,
  });

  final String displayName;
  final String password;
  final bool enableQuickUnlock;
}

class _LocalVaultCreationDialog extends StatefulWidget {
  const _LocalVaultCreationDialog({
    required this.quickUnlockAvailable,
    required this.quickUnlockMethod,
  });

  final bool quickUnlockAvailable;
  final String quickUnlockMethod;

  @override
  State<_LocalVaultCreationDialog> createState() =>
      _LocalVaultCreationDialogState();
}

class _LocalVaultCreationDialogState extends State<_LocalVaultCreationDialog> {
  final _displayName = TextEditingController();
  final _password = TextEditingController();
  final _confirmPassword = TextEditingController();
  bool _enableQuickUnlock = true;
  String? _error;

  @override
  void dispose() {
    _displayName.dispose();
    _password.dispose();
    _confirmPassword.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Create local vault'),
      content: _DialogContent(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _displayName,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(labelText: 'Vault name'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _password,
              obscureText: true,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(labelText: 'Vault password'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _confirmPassword,
              obscureText: true,
              onSubmitted: (_) => _submit(),
              decoration: const InputDecoration(labelText: 'Confirm password'),
            ),
            const SizedBox(height: 8),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: widget.quickUnlockAvailable && _enableQuickUnlock,
              onChanged:
                  widget.quickUnlockAvailable
                      ? (value) =>
                          setState(() => _enableQuickUnlock = value ?? false)
                      : null,
              title: const Text('Enable system quick unlock'),
              subtitle: Text(widget.quickUnlockMethod),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
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
        FilledButton(onPressed: _submit, child: const Text('Create')),
      ],
    );
  }

  void _submit() {
    final password = _password.text;
    if (password.length < 12) {
      setState(() => _error = 'Use at least 12 characters.');
      return;
    }
    if (password != _confirmPassword.text) {
      setState(() => _error = 'Passwords do not match.');
      return;
    }
    Navigator.of(context).pop(
      _LocalVaultCreationInput(
        displayName: _displayName.text.trim(),
        password: password,
        enableQuickUnlock: widget.quickUnlockAvailable && _enableQuickUnlock,
      ),
    );
  }
}

class _LocalVaultUnlockInput {
  const _LocalVaultUnlockInput.password(this.password) : useQuickUnlock = false;

  const _LocalVaultUnlockInput.quickUnlock()
    : password = null,
      useQuickUnlock = true;

  final String? password;
  final bool useQuickUnlock;
}

class _LocalVaultUnlockDialog extends StatefulWidget {
  const _LocalVaultUnlockDialog({
    required this.profile,
    required this.quickUnlockAvailable,
    required this.quickUnlockMethod,
  });

  final LocalProfile profile;
  final bool quickUnlockAvailable;
  final String quickUnlockMethod;

  @override
  State<_LocalVaultUnlockDialog> createState() =>
      _LocalVaultUnlockDialogState();
}

class _LocalVaultUnlockDialogState extends State<_LocalVaultUnlockDialog> {
  final _password = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Unlock ${widget.profile.label}'),
      content: _DialogContent(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.quickUnlockAvailable) ...[
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed:
                      () => Navigator.of(
                        context,
                      ).pop(const _LocalVaultUnlockInput.quickUnlock()),
                  icon: const Icon(Icons.fingerprint),
                  label: Text(widget.quickUnlockMethod),
                ),
              ),
              const SizedBox(height: 12),
            ],
            TextField(
              controller: _password,
              obscureText: true,
              onSubmitted: (_) => _submit(),
              decoration: const InputDecoration(labelText: 'Vault password'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
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
        FilledButton(onPressed: _submit, child: const Text('Unlock')),
      ],
    );
  }

  void _submit() {
    if (_password.text.isEmpty) {
      setState(() => _error = 'Enter the vault password.');
      return;
    }
    Navigator.of(context).pop(_LocalVaultUnlockInput.password(_password.text));
  }
}

class _VaultPasswordInput {
  const _VaultPasswordInput(this.password);

  final String password;
}

class _VaultPasswordDialog extends StatefulWidget {
  const _VaultPasswordDialog({
    required this.title,
    required this.message,
    required this.confirmPassword,
    this.passwordLabel = 'Vault password',
    this.actionLabel = 'Continue',
  });

  final String title;
  final String message;
  final bool confirmPassword;
  final String passwordLabel;
  final String actionLabel;

  @override
  State<_VaultPasswordDialog> createState() => _VaultPasswordDialogState();
}

class _VaultPasswordDialogState extends State<_VaultPasswordDialog> {
  final _password = TextEditingController();
  final _confirmPassword = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    _confirmPassword.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: _DialogContent(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Align(alignment: Alignment.centerLeft, child: Text(widget.message)),
            const SizedBox(height: 12),
            TextField(
              controller: _password,
              obscureText: true,
              textInputAction:
                  widget.confirmPassword
                      ? TextInputAction.next
                      : TextInputAction.done,
              onSubmitted: (_) {
                if (!widget.confirmPassword) _submit();
              },
              decoration: InputDecoration(labelText: widget.passwordLabel),
            ),
            if (widget.confirmPassword) ...[
              const SizedBox(height: 10),
              TextField(
                controller: _confirmPassword,
                obscureText: true,
                onSubmitted: (_) => _submit(),
                decoration: const InputDecoration(
                  labelText: 'Confirm password',
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
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: Text(widget.actionLabel)),
      ],
    );
  }

  void _submit() {
    final password = _password.text;
    if (password.length < 12) {
      setState(() => _error = 'Use at least 12 characters.');
      return;
    }
    if (widget.confirmPassword && password != _confirmPassword.text) {
      setState(() => _error = 'Passwords do not match.');
      return;
    }
    Navigator.of(context).pop(_VaultPasswordInput(password));
  }
}

class _VaultImportConflictDialog extends StatefulWidget {
  const _VaultImportConflictDialog({required this.plan});

  final VaultImportPlan plan;

  @override
  State<_VaultImportConflictDialog> createState() =>
      _VaultImportConflictDialogState();
}

class _VaultImportConflictDialogState
    extends State<_VaultImportConflictDialog> {
  VaultImportConflictPolicy _policy = VaultImportConflictPolicy.keepLocal;

  @override
  Widget build(BuildContext context) {
    final plan = widget.plan;
    final conflictCount =
        plan.mailboxConflicts.length + plan.oauthProviderConflicts.length;
    return AlertDialog(
      title: const Text('Import conflicts found'),
      content: _DialogContent(
        width: 500,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${plan.newMailboxCount} new mailbox accounts and ${plan.newOAuthProviderCount} new OAuth providers will be added. $conflictCount existing entries match the import.',
            ),
            const SizedBox(height: 12),
            RadioGroup<VaultImportConflictPolicy>(
              groupValue: _policy,
              onChanged: (value) {
                if (value != null) setState(() => _policy = value);
              },
              child: const Column(
                children: [
                  RadioListTile<VaultImportConflictPolicy>(
                    contentPadding: EdgeInsets.zero,
                    value: VaultImportConflictPolicy.keepLocal,
                    title: Text('Keep local entries'),
                    subtitle: Text(
                      'Safer when the imported file may be older.',
                    ),
                  ),
                  RadioListTile<VaultImportConflictPolicy>(
                    contentPadding: EdgeInsets.zero,
                    value: VaultImportConflictPolicy.replaceLocal,
                    title: Text('Replace matching entries'),
                    subtitle: Text(
                      'Use credentials and settings from the file.',
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_policy),
          child: const Text('Import'),
        ),
      ],
    );
  }
}

String _newLocalProfileId() {
  return 'local-vault-${DateTime.now().microsecondsSinceEpoch}';
}

enum _LocalVaultSettingsAction { enableQuickUnlock, disableQuickUnlock }

class _LocalVaultSettingsDialog extends StatelessWidget {
  const _LocalVaultSettingsDialog({
    required this.profile,
    required this.quickUnlockAvailable,
    required this.quickUnlockEnabled,
    required this.quickUnlockMethod,
  });

  final LocalProfile profile;
  final bool quickUnlockAvailable;
  final bool quickUnlockEnabled;
  final String quickUnlockMethod;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('Local vault'),
      content: _DialogContent(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.lock_outline),
              title: Text(profile.label),
              subtitle: Text(profile.id),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                quickUnlockEnabled
                    ? Icons.fingerprint
                    : Icons.lock_open_outlined,
                color:
                    quickUnlockEnabled
                        ? colorScheme.primary
                        : colorScheme.onSurfaceVariant,
              ),
              title: Text(
                quickUnlockEnabled
                    ? 'System quick unlock enabled'
                    : 'System quick unlock disabled',
              ),
              subtitle: Text(
                quickUnlockAvailable
                    ? quickUnlockMethod
                    : '$quickUnlockMethod is not available on this device.',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        if (quickUnlockEnabled)
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: colorScheme.error,
              foregroundColor: colorScheme.onError,
            ),
            onPressed:
                () => Navigator.of(
                  context,
                ).pop(_LocalVaultSettingsAction.disableQuickUnlock),
            icon: const Icon(Icons.lock_reset_outlined),
            label: const Text('Disable'),
          )
        else
          FilledButton.icon(
            onPressed:
                quickUnlockAvailable
                    ? () => Navigator.of(
                      context,
                    ).pop(_LocalVaultSettingsAction.enableQuickUnlock)
                    : null,
            icon: const Icon(Icons.fingerprint),
            label: const Text('Enable'),
          ),
      ],
    );
  }
}
