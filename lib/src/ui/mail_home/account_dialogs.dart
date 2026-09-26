part of '../mail_home_page.dart';

class _LoginDialog extends StatefulWidget {
  const _LoginDialog({
    required this.api,
    required this.apiBaseUrl,
    required this.secureStore,
  });

  final NyaMailApi api;
  final String apiBaseUrl;
  final LocalSecureStore secureStore;

  @override
  State<_LoginDialog> createState() => _LoginDialogState();
}

class _LoginDialogState extends State<_LoginDialog> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _displayName = TextEditingController();
  bool _register = false;
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _displayName.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_register ? 'Create NyaMail account' : 'Sign in'),
      content: _DialogContent(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _email,
              decoration: const InputDecoration(labelText: 'Email'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _password,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Password'),
            ),
            if (_register) ...[
              const SizedBox(height: 10),
              TextField(
                controller: _displayName,
                decoration: const InputDecoration(labelText: 'Display name'),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 12),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.dns_outlined),
              title: const Text('Sync server'),
              subtitle: Text(
                widget.apiBaseUrl,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: TextButton(
                onPressed:
                    _submitting
                        ? null
                        : () => Navigator.of(
                          context,
                        ).pop(_LoginDialogAction.serverSettings),
                child: const Text('Change'),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed:
              _submitting ? null : () => setState(() => _register = !_register),
          child: Text(_register ? 'Use existing account' : 'Create account'),
        ),
        FilledButton(
          onPressed: _submitting ? null : _submit,
          child:
              _submitting
                  ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(),
                  )
                  : const Text('Continue'),
        ),
      ],
    );
  }

  Future<void> _submit() async {
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final stableDeviceId = await widget.secureStore.readStableDeviceId();
      final deviceKeyPair =
          await widget.secureStore.readOrCreateDeviceKeyPair();
      final deviceBoxKeyPair =
          await widget.secureStore.readOrCreateDeviceBoxKeyPair();
      final device = DeviceInfoPayload(
        id: stableDeviceId,
        name: 'NyaMail device',
        platform: const String.fromEnvironment(
          'NYAMAIL_PLATFORM',
          defaultValue: 'auto',
        ),
        publicKey: deviceKeyPair.publicKey,
        keyAgreementPublicKey: deviceBoxKeyPair.publicKey,
      );
      final AuthSession session;
      if (_register) {
        session = await widget.api.register(
          email: _email.text.trim(),
          password: _password.text,
          displayName: _displayName.text.trim(),
          device: device,
        );
      } else {
        session = await widget.api.login(
          email: _email.text.trim(),
          password: _password.text,
          device: device,
        );
      }
      await widget.secureStore.saveStableDeviceId(session.deviceId);
      _LoginPasswordMemory.write(_password.text);
      if (mounted) Navigator.of(context).pop(session);
    } catch (error) {
      setState(() {
        _error = error.toString();
        _submitting = false;
      });
    }
  }
}

enum _LoginDialogAction { serverSettings }

enum _SyncAccountAction { serverSettings, syncNow, leaveSync, signOut }

class _SyncAccountStatus {
  const _SyncAccountStatus({
    required this.profileId,
    this.cursor = 0,
    this.lastSyncedAt,
    this.recordCount = 0,
    this.dirtyRecordCount = 0,
    this.tombstoneCount = 0,
    this.hasRecordVault = false,
    this.error,
  });

  final String profileId;
  final int cursor;
  final DateTime? lastSyncedAt;
  final int recordCount;
  final int dirtyRecordCount;
  final int tombstoneCount;
  final bool hasRecordVault;
  final String? error;

  bool get hasError => error != null && error!.trim().isNotEmpty;
}

class _SyncAccountDialog extends StatelessWidget {
  const _SyncAccountDialog({
    required this.session,
    required this.apiBaseUrl,
    required this.status,
  });

  final LocalSession session;
  final String apiBaseUrl;
  final _SyncAccountStatus status;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final statusColor =
        status.hasError
            ? colorScheme.error
            : status.dirtyRecordCount > 0
            ? colorScheme.tertiary
            : colorScheme.primary;
    return AlertDialog(
      title: const Text('Sync account'),
      content: _DialogContent(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.verified_user_outlined),
              title: const Text('Signed in as'),
              subtitle: Text(session.email),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.devices_outlined),
              title: Text(session.deviceName),
              subtitle: Text('${session.devicePlatform} - ${session.deviceId}'),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.dns_outlined),
              title: const Text('Sync server'),
              subtitle: Text(
                apiBaseUrl,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: TextButton(
                onPressed:
                    () => Navigator.of(
                      context,
                    ).pop(_SyncAccountAction.serverSettings),
                child: const Text('Change'),
              ),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                status.dirtyRecordCount > 0
                    ? Icons.sync_problem_outlined
                    : Icons.cloud_done_outlined,
                color: statusColor,
              ),
              title: Text(_syncStatusTitle(status)),
              subtitle: Text(
                _syncStatusSubtitle(status),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: colorScheme.outlineVariant),
              ),
              child: Text(
                'Signing out disconnects sync on this device. Your local encrypted vault, mailbox settings, and mail cache remain available.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
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
        TextButton.icon(
          onPressed:
              () => Navigator.of(context).pop(_SyncAccountAction.syncNow),
          icon: const Icon(Icons.sync),
          label: const Text('Sync now'),
        ),
        TextButton.icon(
          style: TextButton.styleFrom(foregroundColor: colorScheme.error),
          onPressed:
              () => Navigator.of(context).pop(_SyncAccountAction.leaveSync),
          icon: const Icon(Icons.link_off_outlined),
          label: const Text('Leave sync'),
        ),
        FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: colorScheme.error,
            foregroundColor: colorScheme.onError,
          ),
          onPressed:
              () => Navigator.of(context).pop(_SyncAccountAction.signOut),
          icon: const Icon(Icons.logout),
          label: const Text('Sign out'),
        ),
      ],
    );
  }
}
