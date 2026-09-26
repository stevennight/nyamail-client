part of '../mail_home_page.dart';

class _DevicesDialog extends StatefulWidget {
  const _DevicesDialog({
    required this.api,
    required this.token,
    required this.userId,
    required this.currentDevice,
    required this.secureStore,
    required this.vaultSecret,
  });

  final NyaMailApi api;
  final String token;
  final String userId;
  final DeviceSummary currentDevice;
  final LocalSecureStore secureStore;
  final String vaultSecret;

  @override
  State<_DevicesDialog> createState() => _DevicesDialogState();
}

class _DevicesDialogState extends State<_DevicesDialog> {
  late Future<List<DeviceSummary>> _devices = widget.api.listDevices(
    widget.token,
  );
  static const _pairingCode = DevicePairingCode();
  bool _sharing = false;
  String? _revokingDeviceId;
  String? _error;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Devices'),
      content: _DialogContent(
        width: 520,
        child: FutureBuilder<List<DeviceSummary>>(
          future: _devices,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const SizedBox(
                height: 180,
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (snapshot.hasError) {
              return Text(snapshot.error.toString());
            }
            final devices = snapshot.data ?? const [];
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Align(
                  alignment: Alignment.centerRight,
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    alignment: WrapAlignment.end,
                    children: [
                      if (_canScanPairingQr)
                        TextButton.icon(
                          onPressed:
                              _sharing ? null : () => _shareFromQr(devices),
                          icon: const Icon(Icons.qr_code_scanner),
                          label: const Text('Scan pairing QR'),
                        ),
                      TextButton.icon(
                        onPressed:
                            _sharing
                                ? null
                                : () => _shareFromClipboard(devices),
                        icon: const Icon(Icons.content_paste),
                        label: const Text('Paste pairing package'),
                      ),
                    ],
                  ),
                ),
                for (final device in devices)
                  ListTile(
                    leading: Icon(
                      device.trusted
                          ? Icons.verified_user_outlined
                          : Icons.pending_outlined,
                    ),
                    title: Text(device.name),
                    subtitle: Text(
                      device.trusted || device.revoked
                          ? '${device.platform} - ${device.id}'
                          : '${device.platform} - ${device.id}\nPair ${_pairingCode.codeFor(userId: widget.userId, device: device)}',
                    ),
                    isThreeLine: !(device.trusted || device.revoked),
                    trailing:
                        device.id == widget.currentDevice.id
                            ? const Text('This device')
                            : device.revoked
                            ? null
                            : device.trusted
                            ? IconButton(
                              tooltip: 'Revoke device',
                              onPressed:
                                  _busy ? null : () => _revokeDevice(device),
                              icon:
                                  _revokingDeviceId == device.id
                                      ? const SizedBox.square(
                                        dimension: 18,
                                        child: CircularProgressIndicator(),
                                      )
                                      : const Icon(Icons.block_outlined),
                            )
                            : IconButton(
                              tooltip: 'Share vault',
                              onPressed: _busy ? null : () => _shareTo(device),
                              icon: const Icon(Icons.lock_open_outlined),
                            ),
                  ),
                if (_error != null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  ),
              ],
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

  bool get _busy => _sharing || _revokingDeviceId != null;

  bool get _canScanPairingQr {
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS;
  }

  void _reloadDevices() {
    setState(() {
      _devices = widget.api.listDevices(widget.token);
    });
  }

  Future<void> _shareFromClipboard(List<DeviceSummary> devices) async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      await _shareFromPairingPackage(devices, data?.text ?? '');
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error.toString();
        });
      }
    }
  }

  Future<void> _shareFromQr(List<DeviceSummary> devices) async {
    final text = await showDialog<String>(
      context: context,
      builder: (context) => const _PairingQrScannerDialog(),
    );
    if (text == null || text.trim().isEmpty) return;
    await _shareFromPairingPackage(devices, text);
  }

  Future<void> _shareFromPairingPackage(
    List<DeviceSummary> devices,
    String text,
  ) async {
    setState(() {
      _sharing = true;
      _error = null;
    });
    try {
      final request = DevicePairingRequest.decode(text);
      if (request.userId != widget.userId) {
        throw const DevicePairingRequestException(
          'pairing package is for a different user',
        );
      }
      final device =
          devices.where((item) => item.id == request.device.id).firstOrNull;
      if (device == null) {
        throw const DevicePairingRequestException(
          'pairing device is not waiting for approval',
        );
      }
      _assertPairingRequestMatchesDevice(request, device);
      await _shareTo(device, expectedPairingCode: request.pairingCode);
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error.toString();
          _sharing = false;
        });
      }
    }
  }

  Future<void> _revokeDevice(DeviceSummary device) async {
    if (device.id == widget.currentDevice.id) {
      setState(() => _error = 'This device cannot revoke itself.');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: Text('Revoke ${device.name}?'),
            content: const Text(
              'This device will lose access to NyaMail sync until it signs in again and is approved.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton.icon(
                onPressed: () => Navigator.of(context).pop(true),
                icon: const Icon(Icons.block_outlined),
                label: const Text('Revoke'),
              ),
            ],
          ),
    );
    if (confirmed != true) return;
    setState(() {
      _revokingDeviceId = device.id;
      _error = null;
    });
    try {
      await widget.api.revokeDevice(token: widget.token, deviceId: device.id);
      _reloadDevices();
    } catch (error) {
      if (mounted) {
        setState(() => _error = error.toString());
      }
    } finally {
      if (mounted) {
        setState(() => _revokingDeviceId = null);
      }
    }
  }

  void _assertPairingRequestMatchesDevice(
    DevicePairingRequest request,
    DeviceSummary device,
  ) {
    if (device.trusted || device.revoked) {
      throw const DevicePairingRequestException(
        'pairing device is not pending approval',
      );
    }
    if (request.device.publicKey != device.publicKey ||
        request.device.keyAgreementPublicKey != device.keyAgreementPublicKey) {
      throw const DevicePairingRequestException(
        'pairing package keys do not match the pending device',
      );
    }
    final expected = _pairingCode.codeFor(
      userId: widget.userId,
      device: device,
    );
    if (request.pairingCode != expected) {
      throw const DevicePairingRequestException(
        'pairing code does not match the pending device',
      );
    }
  }

  Future<void> _shareTo(
    DeviceSummary device, {
    String? expectedPairingCode,
  }) async {
    setState(() {
      _sharing = true;
      _error = null;
    });
    try {
      final pairingCode = _pairingCode.codeFor(
        userId: widget.userId,
        device: device,
      );
      if (expectedPairingCode != null && expectedPairingCode != pairingCode) {
        throw const DevicePairingRequestException(
          'pairing package does not match selected device',
        );
      }
      final confirmed = await _confirmPairingCode(device, pairingCode);
      if (!confirmed) {
        if (mounted) {
          setState(() => _sharing = false);
        }
        return;
      }
      final vaultSecret = widget.vaultSecret;
      if (vaultSecret.isEmpty) {
        throw StateError('This device has no transferable vault secret yet.');
      }
      if (device.keyAgreementPublicKey.isEmpty) {
        throw StateError('Target device has no encryption public key.');
      }
      final payload = await const VaultShareCrypto().encryptForDevice(
        recipientPublicKey: device.keyAgreementPublicKey,
        plaintext: vaultSecret,
      );
      final signingKey = await widget.secureStore.readOrCreateDeviceKeyPair();
      final approvalSignature = await const DeviceApprovalCrypto()
          .signVaultShareApproval(
            userId: widget.userId,
            fromDevice: widget.currentDevice,
            toDevice: device,
            share: payload,
            pairingCode: pairingCode,
            privateKey: signingKey.privateKey,
          );
      await widget.api.putVaultShare(
        token: widget.token,
        deviceId: device.id,
        senderPublicKey: payload.senderPublicKey,
        algorithm: payload.algorithm,
        nonce: payload.nonce,
        ciphertext: payload.ciphertext,
        mac: payload.mac,
        pairingCode: pairingCode,
        approvalSignature: approvalSignature,
      );
      if (mounted) {
        Navigator.of(context).pop('Vault access shared with ${device.name}.');
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error.toString();
          _sharing = false;
        });
      }
    }
  }

  Future<bool> _confirmPairingCode(
    DeviceSummary device,
    String pairingCode,
  ) async {
    final controller = TextEditingController();
    try {
      final result = await showDialog<bool>(
        context: context,
        builder:
            (context) => AlertDialog(
              title: Text('Share with ${device.name}'),
              content: _DialogContent(
                width: 360,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SelectableText(
                      pairingCode,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: controller,
                      autofocus: true,
                      textCapitalization: TextCapitalization.characters,
                      decoration: const InputDecoration(
                        labelText: 'Pairing code',
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
                FilledButton.icon(
                  onPressed: () {
                    final entered = _pairingCode.normalize(controller.text);
                    Navigator.of(context).pop(entered == pairingCode);
                  },
                  icon: const Icon(Icons.verified_user_outlined),
                  label: const Text('Share'),
                ),
              ],
            ),
      );
      if (result == false && mounted) {
        setState(() => _error = 'Pairing code did not match.');
      }
      return result ?? false;
    } finally {
      controller.dispose();
    }
  }
}

class _PairingQrDialog extends StatelessWidget {
  const _PairingQrDialog({required this.pairingPackage});

  final String pairingPackage;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Pair this device'),
      content: _DialogContent(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              color: Colors.white,
              child: QrImageView(
                data: pairingPackage,
                version: QrVersions.auto,
                size: 260,
                gapless: false,
                errorCorrectionLevel: QrErrorCorrectLevel.M,
                semanticsLabel: 'NyaMail device pairing package',
              ),
            ),
            const SizedBox(height: 12),
            SelectableText(
              pairingPackage,
              maxLines: 3,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: pairingPackage));
            if (context.mounted) {
              Navigator.of(context).pop();
            }
          },
          icon: const Icon(Icons.content_copy),
          label: const Text('Copy'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _RecoveryCodesDialog extends StatelessWidget {
  const _RecoveryCodesDialog({required this.codes});

  final List<String> codes;

  @override
  Widget build(BuildContext context) {
    final joinedCodes = codes.join('\n');
    final colorScheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('Recovery codes'),
      content: _DialogContent(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Save these one-time codes now. They can approve a new device if you lose access to an existing one.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: colorScheme.outlineVariant),
              ),
              child: SelectableText(
                joinedCodes,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  fontFamily: 'monospace',
                  height: 1.35,
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: joinedCodes));
          },
          icon: const Icon(Icons.content_copy),
          label: const Text('Copy all'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('I saved them'),
        ),
      ],
    );
  }
}

class _PairingQrScannerDialog extends StatefulWidget {
  const _PairingQrScannerDialog();

  @override
  State<_PairingQrScannerDialog> createState() =>
      _PairingQrScannerDialogState();
}

class _PairingQrScannerDialogState extends State<_PairingQrScannerDialog> {
  late final MobileScannerController _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  bool _handled = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Scan pairing QR'),
      content: _DialogContent(
        width: 420,
        maxHeight: 460,
        child: SizedBox(
          height: 460,
          child: Column(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: MobileScanner(
                    controller: _controller,
                    onDetect: _handleDetection,
                    errorBuilder: (context, error) {
                      return Center(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(
                            error.errorDetails?.message ?? error.toString(),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        IconButton(
          tooltip: 'Toggle torch',
          onPressed: () => _controller.toggleTorch(),
          icon: const Icon(Icons.flashlight_on_outlined),
        ),
        IconButton(
          tooltip: 'Switch camera',
          onPressed: () => _controller.switchCamera(),
          icon: const Icon(Icons.cameraswitch_outlined),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }

  void _handleDetection(BarcodeCapture capture) {
    if (_handled) return;
    final value =
        capture.barcodes
            .where((barcode) => barcode.rawValue?.trim().isNotEmpty ?? false)
            .map((barcode) => barcode.rawValue!.trim())
            .firstOrNull;
    if (value == null) return;
    try {
      DevicePairingRequest.decode(value);
      _handled = true;
      Navigator.of(context).pop(value);
    } catch (error) {
      if (mounted) {
        setState(() => _error = error.toString());
      }
    }
  }
}
