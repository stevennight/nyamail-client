part of '../mail_home_page.dart';

class _Reader extends StatelessWidget {
  const _Reader({
    required this.message,
    this.bodyLoading = false,
    this.mailboxContextLabel = '',
    required this.onSendReply,
    required this.onSendReplyAll,
    required this.onForward,
    required this.onSetRead,
    required this.onSetStarred,
    required this.onArchive,
    required this.onDelete,
    required this.onMoveToInbox,
    required this.onMoveToMailbox,
    required this.onDownloadAttachment,
    required this.renderSettings,
    this.mobileFullScreen = false,
    this.onClose,
  });

  final MailMessage? message;
  final bool bodyLoading;
  final String mailboxContextLabel;
  final Future<void> Function(
    MailMessage message,
    String textBody, {
    String htmlBody,
    List<OutgoingAttachment> attachments,
  })
  onSendReply;
  final Future<void> Function(
    MailMessage message,
    String textBody, {
    String htmlBody,
    List<OutgoingAttachment> attachments,
  })
  onSendReplyAll;
  final Future<void> Function(MailMessage message) onForward;
  final Future<void> Function(MailMessage message, bool read) onSetRead;
  final Future<void> Function(MailMessage message, bool starred) onSetStarred;
  final Future<void> Function(MailMessage message) onArchive;
  final Future<void> Function(MailMessage message) onDelete;
  final Future<void> Function(MailMessage message) onMoveToInbox;
  final Future<void> Function(MailMessage message, MailboxKind destination)
  onMoveToMailbox;
  final Future<void> Function(MailMessage message, MailAttachment attachment)
  onDownloadAttachment;
  final MailRenderSettings renderSettings;
  final bool mobileFullScreen;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final message = this.message;
    if (message == null) {
      return const _ReaderEmptyState();
    }
    return _ReaderBody(
      message: message,
      bodyLoading: bodyLoading,
      mailboxContextLabel: mailboxContextLabel,
      onSendReply: onSendReply,
      onSendReplyAll: onSendReplyAll,
      onForward: onForward,
      onSetRead: onSetRead,
      onSetStarred: onSetStarred,
      onArchive: onArchive,
      onDelete: onDelete,
      onMoveToInbox: onMoveToInbox,
      onMoveToMailbox: onMoveToMailbox,
      onDownloadAttachment: onDownloadAttachment,
      renderSettings: renderSettings,
      mobileFullScreen: mobileFullScreen,
      onClose: onClose,
    );
  }
}

class _ReaderEmptyState extends StatelessWidget {
  const _ReaderEmptyState();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.mark_email_unread_outlined,
              size: 48,
              color: colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 14),
            Text(
              'Select a message',
              textAlign: TextAlign.center,
              style: textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            Text(
              'Your mail will open here.',
              textAlign: TextAlign.center,
              style: textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReaderSenderHeader extends StatelessWidget {
  const _ReaderSenderHeader({required this.message});

  final MailMessage message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final name = _displaySender(message.from);
    final address = _senderAddress(message.from);
    final avatarColor = _senderAvatarColor(
      address.isNotEmpty ? address : name,
      colorScheme,
    );
    final onAvatar =
        ThemeData.estimateBrightnessForColor(avatarColor) == Brightness.dark
            ? Colors.white
            : Colors.black;
    final recipientLines = <String>[
      if (message.to.isNotEmpty) 'To ${message.to.join(', ')}',
      if (message.cc.isNotEmpty) 'Cc ${message.cc.join(', ')}',
      if (message.replyTo.isNotEmpty) 'Reply-To ${message.replyTo.join(', ')}',
    ];
    final subdued = theme.textTheme.bodySmall?.copyWith(
      color: colorScheme.onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              radius: 20,
              backgroundColor: avatarColor,
              foregroundColor: onAvatar,
              child: Text(
                _senderInitial(name.isNotEmpty ? name : address),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (address.isNotEmpty && address != name)
                    Text(
                      address,
                      style: subdued,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Text(mailMessageDisplayDate(message.receivedAt), style: subdued),
          ],
        ),
        if (recipientLines.isNotEmpty) ...[
          const SizedBox(height: 6),
          for (final line in recipientLines)
            Padding(
              padding: const EdgeInsetsDirectional.only(start: 52, top: 2),
              child: Text(
                line,
                style: subdued,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ],
    );
  }
}

class _ComposeDialog extends StatefulWidget {
  const _ComposeDialog({
    this.title = 'New message',
    required this.accounts,
    required this.initialAccountId,
    this.initialTo = '',
    this.initialCc = '',
    this.initialBcc = '',
    this.initialSubject = '',
    this.initialBody = '',
    this.initialHtmlBody = '',
    this.initialAttachments = const [],
    this.onDraftChanged,
    required this.onSend,
  });

  final String title;
  final List<MailAccount> accounts;
  final String? initialAccountId;
  final String initialTo;
  final String initialCc;
  final String initialBcc;
  final String initialSubject;
  final String initialBody;
  final String initialHtmlBody;
  final List<OutgoingAttachment> initialAttachments;
  final Future<void> Function(MailDraft draft)? onDraftChanged;
  final Future<void> Function({
    required String accountId,
    required String to,
    required String cc,
    required String bcc,
    required String subject,
    required String textBody,
    required String htmlBody,
    required List<OutgoingAttachment> attachments,
  })
  onSend;

  @override
  State<_ComposeDialog> createState() => _ComposeDialogState();
}

class _ComposeDialogState extends State<_ComposeDialog> {
  late String _accountId = _initialAccountId();
  late final TextEditingController _to;
  late final TextEditingController _cc;
  late final TextEditingController _bcc;
  late final TextEditingController _subject;
  late final TextEditingController _body;
  final _attachments = <OutgoingAttachment>[];
  InAppWebViewController? _bodyWebController;
  bool _bodyEditorReady = false;
  bool _showCcBcc = false;
  bool _savingDraft = false;
  bool _draftSaveFailed = false;
  bool _draftEverSaved = false;
  Timer? _draftSaveTimer;
  bool _sending = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _to = TextEditingController(text: widget.initialTo);
    _cc = TextEditingController(text: widget.initialCc);
    _bcc = TextEditingController(text: widget.initialBcc);
    _subject = TextEditingController(text: widget.initialSubject);
    _body = TextEditingController(text: widget.initialBody);
    _attachments.addAll(widget.initialAttachments);
    _showCcBcc =
        widget.initialCc.trim().isNotEmpty ||
        widget.initialBcc.trim().isNotEmpty;
    _to.addListener(_scheduleDraftSave);
    _cc.addListener(_scheduleDraftSave);
    _bcc.addListener(_scheduleDraftSave);
    _subject.addListener(_scheduleDraftSave);
    if (!_supportsReplyRichEditor) {
      _body.addListener(_scheduleDraftSave);
    }
  }

  @override
  void dispose() {
    _draftSaveTimer?.cancel();
    _to.dispose();
    _cc.dispose();
    _bcc.dispose();
    _subject.dispose();
    _body.dispose();
    super.dispose();
  }

  String _initialAccountId() {
    final initial = widget.initialAccountId;
    if (initial != null &&
        widget.accounts.any((account) => account.id == initial)) {
      return initial;
    }
    return widget.accounts.first.id;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: _DialogContent(
        width: 520,
        maxHeight: 620,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              initialValue: _accountId,
              decoration: const InputDecoration(labelText: 'From'),
              items: [
                for (final account in widget.accounts)
                  DropdownMenuItem(
                    value: account.id,
                    child: Text(
                      '${account.displayName} <${account.address}>',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged:
                  _sending
                      ? null
                      : (value) {
                        setState(() => _accountId = value ?? _accountId);
                        _scheduleDraftSave();
                      },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _to,
              decoration: const InputDecoration(
                labelText: 'To',
                hintText: 'name@example.com',
              ),
            ),
            const SizedBox(height: 10),
            if (!_showCcBcc) ...[
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed:
                      _sending ? null : () => setState(() => _showCcBcc = true),
                  icon: const Icon(Icons.person_add_alt_outlined),
                  label: const Text('Cc/Bcc'),
                ),
              ),
            ] else ...[
              TextField(
                controller: _cc,
                decoration: const InputDecoration(
                  labelText: 'Cc',
                  hintText: 'name@example.com',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _bcc,
                decoration: const InputDecoration(
                  labelText: 'Bcc',
                  hintText: 'name@example.com',
                ),
              ),
            ],
            const SizedBox(height: 10),
            TextField(
              controller: _subject,
              decoration: const InputDecoration(labelText: 'Subject'),
            ),
            const SizedBox(height: 10),
            _composeBodyEditor(context),
            const SizedBox(height: 12),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: _sending ? null : _pickAttachments,
                  icon: const Icon(Icons.attach_file),
                  label: const Text('Attach'),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _attachments.isEmpty
                        ? 'No attachments'
                        : '${_attachments.length} attached - '
                            '${_formatBytes(_attachmentTotalBytes)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            if (_attachments.isNotEmpty) ...[
              const SizedBox(height: 8),
              for (var index = 0; index < _attachments.length; index++)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.insert_drive_file_outlined),
                  title: Text(
                    _attachments[index].filename,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    _outgoingAttachmentSubtitle(_attachments[index]),
                  ),
                  trailing: IconButton(
                    tooltip: 'Remove attachment',
                    onPressed:
                        _sending
                            ? null
                            : () {
                              setState(() => _attachments.removeAt(index));
                              _scheduleDraftSave();
                            },
                    icon: const Icon(Icons.close),
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
        if (_draftStatusLabel != null)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Text(
              _draftStatusLabel!,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color:
                    _draftSaveFailed
                        ? Theme.of(context).colorScheme.error
                        : Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        TextButton(
          onPressed: _sending ? null : _cancel,
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: _sending ? null : _send,
          icon:
              _sending
                  ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(),
                  )
                  : const Icon(Icons.send),
          label: const Text('Send'),
        ),
      ],
    );
  }

  Widget _composeBodyEditor(BuildContext context) {
    if (!_supportsReplyRichEditor) {
      return TextField(
        controller: _body,
        minLines: 8,
        maxLines: 12,
        decoration: const InputDecoration(labelText: 'Message'),
      );
    }
    final colorScheme = Theme.of(context).colorScheme;
    final dark = colorScheme.brightness == Brightness.dark;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _ReplyComposerToolbar(
          enabled: _bodyEditorReady && !_sending,
          onCommand: _execBodyEditorCommand,
          onInsertLink: _insertBodyLink,
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 240,
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: colorScheme.outlineVariant),
              borderRadius: BorderRadius.circular(8),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: InAppWebView(
                initialData: InAppWebViewInitialData(
                  data: _replyEditorHtml(
                    dark: dark,
                    initialText: widget.initialBody,
                    initialHtml: widget.initialHtmlBody,
                    placeholderText: 'Write a message',
                  ),
                  mimeType: 'text/html',
                  encoding: 'utf8',
                  baseUrl: WebUri('about:blank'),
                ),
                initialSettings: InAppWebViewSettings(
                  javaScriptEnabled: true,
                  javaScriptCanOpenWindowsAutomatically: false,
                  mediaPlaybackRequiresUserGesture: true,
                  useShouldOverrideUrlLoading: true,
                  useShouldInterceptRequest: true,
                  cacheEnabled: false,
                  clearCache: true,
                  incognito: true,
                  transparentBackground: false,
                  supportZoom: false,
                ),
                onWebViewCreated: (controller) {
                  _bodyWebController = controller;
                  controller.addJavaScriptHandler(
                    handlerName: 'nyamailComposeChanged',
                    callback: (_) {
                      _scheduleDraftSave();
                      return null;
                    },
                  );
                },
                onLoadStop: (controller, _) async {
                  if (!mounted) return;
                  setState(() => _bodyEditorReady = true);
                  await controller.evaluateJavascript(
                    source:
                        "document.getElementById('editor')?.addEventListener('input', "
                        "() => window.flutter_inappwebview.callHandler('nyamailComposeChanged'));",
                  );
                  unawaited(_focusBodyEditor());
                },
                shouldOverrideUrlLoading: (controller, action) async {
                  final uri = Uri.tryParse(
                    action.request.url?.toString() ?? '',
                  );
                  if (uri != null && uri.scheme == 'about') {
                    return NavigationActionPolicy.ALLOW;
                  }
                  return NavigationActionPolicy.CANCEL;
                },
                shouldInterceptRequest: (controller, request) async {
                  final uri = Uri.tryParse(request.url.toString());
                  if (uri == null || !_isRemoteHttpUri(uri)) return null;
                  return WebResourceResponse(
                    contentType: 'text/plain',
                    contentEncoding: 'utf-8',
                    data: Uint8List.fromList(utf8.encode('')),
                    headers: const {},
                    statusCode: 204,
                    reasonPhrase: 'No Content',
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _focusBodyEditor() async {
    try {
      await _bodyWebController?.evaluateJavascript(
        source: 'window.nyamailFocusEditor && window.nyamailFocusEditor();',
      );
    } catch (_) {
      // Focusing is best-effort.
    }
  }

  Future<void> _execBodyEditorCommand(String command) async {
    await _evaluateBodyEditorCommand(command);
  }

  Future<void> _evaluateBodyEditorCommand(
    String command, [
    String value = '',
  ]) async {
    final controller = _bodyWebController;
    if (controller == null || !_bodyEditorReady) return;
    try {
      await controller.evaluateJavascript(
        source:
            'window.nyamailExecCommand && '
            'window.nyamailExecCommand(${jsonEncode(command)}, ${jsonEncode(value)});',
      );
      _scheduleDraftSave();
      await _focusBodyEditor();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _insertBodyLink() async {
    final controller = TextEditingController();
    try {
      final raw = await showDialog<String>(
        context: context,
        builder:
            (context) => AlertDialog(
              title: const Text('Insert link'),
              content: TextField(
                controller: controller,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'URL',
                  hintText: 'https://example.com',
                ),
                keyboardType: TextInputType.url,
                onSubmitted: (value) => Navigator.of(context).pop(value),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(controller.text),
                  child: const Text('Insert'),
                ),
              ],
            ),
      );
      final url = _normalizeComposerLink(raw);
      if (url == null) return;
      await _evaluateBodyEditorCommand('createLink', url);
    } finally {
      controller.dispose();
    }
  }

  void _scheduleDraftSave() {
    if (widget.onDraftChanged == null || _sending) return;
    _draftSaveTimer?.cancel();
    if (!_savingDraft) {
      setState(() {
        _savingDraft = true;
        _draftSaveFailed = false;
      });
    }
    _draftSaveTimer = Timer(const Duration(milliseconds: 500), () {
      unawaited(_saveDraftNow());
    });
  }

  Future<void> _saveDraftNow() async {
    final onDraftChanged = widget.onDraftChanged;
    if (onDraftChanged == null) return;
    if (mounted && !_savingDraft) {
      setState(() {
        _savingDraft = true;
        _draftSaveFailed = false;
      });
    }
    try {
      final body = await _currentComposeContent();
      await onDraftChanged(
        MailDraft(
          accountId: _accountId,
          to: _to.text,
          cc: _cc.text,
          bcc: _bcc.text,
          subject: _subject.text,
          body: body.textBody,
          htmlBody: body.htmlBody,
          attachments: [
            for (final attachment in _attachments)
              MailDraftAttachment(
                filename: attachment.filename,
                contentType: attachment.contentType,
                bytes: attachment.bytes,
              ),
          ],
          updatedAt: DateTime.now(),
        ),
      );
      if (mounted) {
        setState(() {
          _savingDraft = false;
          _draftSaveFailed = false;
          _draftEverSaved = true;
        });
      }
    } catch (_) {
      // Draft persistence is a local convenience and must not block sending.
      if (mounted) {
        setState(() {
          _savingDraft = false;
          _draftSaveFailed = true;
        });
      }
    }
  }

  String? get _draftStatusLabel {
    if (widget.onDraftChanged == null || _sending) return null;
    if (_savingDraft) return 'Saving draft...';
    if (_draftSaveFailed) return 'Draft not saved';
    if (_draftEverSaved) return 'Draft saved locally';
    return null;
  }

  int get _attachmentTotalBytes {
    return _attachments.fold<int>(
      0,
      (total, attachment) => total + attachment.bytes.length,
    );
  }

  Future<void> _pickAttachments() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        withData: true,
      );
      if (result == null) return;
      final selected = <OutgoingAttachment>[];
      for (final file in result.files) {
        final bytes = file.bytes;
        if (bytes == null) {
          setState(() => _error = 'Could not read ${file.name}.');
          return;
        }
        selected.add(
          OutgoingAttachment(
            filename: file.name,
            contentType: _contentTypeForFilename(file.name),
            bytes: bytes,
          ),
        );
      }
      final total =
          _attachmentTotalBytes +
          selected.fold<int>(
            0,
            (sum, attachment) => sum + attachment.bytes.length,
          );
      if (total > _maxOutgoingAttachmentBytes) {
        setState(
          () =>
              _error =
                  'Attachments must be ${_formatBytes(_maxOutgoingAttachmentBytes)} or less.',
        );
        return;
      }
      setState(() {
        _attachments.addAll(selected);
        _error = null;
      });
      _scheduleDraftSave();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _cancel() async {
    _draftSaveTimer?.cancel();
    await _saveDraftNow();
    if (mounted) Navigator.of(context).pop(false);
  }

  Future<void> _send() async {
    final body = await _currentComposeContent();
    final hasRecipient =
        _to.text.trim().isNotEmpty ||
        _cc.text.trim().isNotEmpty ||
        _bcc.text.trim().isNotEmpty;
    if (!hasRecipient) {
      setState(() => _error = 'At least one recipient is required.');
      return;
    }
    if (!_hasSendableMailContent(
      subject: _subject.text,
      textBody: body.textBody,
      attachments: _attachments,
    )) {
      setState(() => _error = 'Add a subject, message, or attachment.');
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    _draftSaveTimer?.cancel();
    await _saveDraftNow();
    try {
      await widget.onSend(
        accountId: _accountId,
        to: _to.text.trim(),
        cc: _cc.text.trim(),
        bcc: _bcc.text.trim(),
        subject: _subject.text.trim(),
        textBody: body.textBody,
        htmlBody: body.htmlBody,
        attachments: List<OutgoingAttachment>.unmodifiable(_attachments),
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error.toString();
          _sending = false;
        });
      }
    }
  }

  Future<_ReplyComposerResult> _currentComposeContent() async {
    if (!_supportsReplyRichEditor) {
      final text = _body.text.trim();
      return _ReplyComposerResult(
        textBody: text,
        htmlBody: _plainTextToOutgoingHtml(text),
      );
    }
    final controller = _bodyWebController;
    if (controller == null || !_bodyEditorReady) {
      final text = _body.text.trim();
      return _ReplyComposerResult(
        textBody: text,
        htmlBody: _plainTextToOutgoingHtml(text),
      );
    }
    final raw = await controller.evaluateJavascript(
      source: 'JSON.stringify(window.nyamailGetContent());',
    );
    final decoded = _decodeReplyEditorContent(raw);
    final text = _normalizeReplyText(decoded['text'] as String? ?? '');
    final html = _normalizeReplyHtml(decoded['html'] as String? ?? '', text);
    return _ReplyComposerResult(textBody: text, htmlBody: html);
  }
}

class _ReaderBody extends StatefulWidget {
  const _ReaderBody({
    required this.message,
    this.bodyLoading = false,
    required this.mailboxContextLabel,
    required this.onSendReply,
    required this.onSendReplyAll,
    required this.onForward,
    required this.onSetRead,
    required this.onSetStarred,
    required this.onArchive,
    required this.onDelete,
    required this.onMoveToInbox,
    required this.onMoveToMailbox,
    required this.onDownloadAttachment,
    required this.renderSettings,
    required this.mobileFullScreen,
    this.onClose,
  });

  final MailMessage message;
  final bool bodyLoading;
  final String mailboxContextLabel;
  final Future<void> Function(
    MailMessage message,
    String textBody, {
    String htmlBody,
    List<OutgoingAttachment> attachments,
  })
  onSendReply;
  final Future<void> Function(
    MailMessage message,
    String textBody, {
    String htmlBody,
    List<OutgoingAttachment> attachments,
  })
  onSendReplyAll;
  final Future<void> Function(MailMessage message) onForward;
  final Future<void> Function(MailMessage message, bool read) onSetRead;
  final Future<void> Function(MailMessage message, bool starred) onSetStarred;
  final Future<void> Function(MailMessage message) onArchive;
  final Future<void> Function(MailMessage message) onDelete;
  final Future<void> Function(MailMessage message) onMoveToInbox;
  final Future<void> Function(MailMessage message, MailboxKind destination)
  onMoveToMailbox;
  final Future<void> Function(MailMessage message, MailAttachment attachment)
  onDownloadAttachment;
  final MailRenderSettings renderSettings;
  final bool mobileFullScreen;
  final VoidCallback? onClose;

  @override
  State<_ReaderBody> createState() => _ReaderBodyState();
}

class _ReaderBodyState extends State<_ReaderBody> {
  bool _sending = false;
  bool _acting = false;
  bool _loadRemoteImagesOnce = false;
  bool _loadExternalStylesAndFontsOnce = false;
  final _allowedRemoteImageIds = <String>{};
  MailAppearance? _appearanceOverride;
  MailHtmlRenderResult? _cachedRendered;
  String? _cachedRenderedHtmlBody;
  String? _cachedRenderedTextBody;
  MailHtmlRenderPolicy? _cachedRenderPolicy;
  String? _downloadingAttachment;
  String? _error;

  @override
  void didUpdateWidget(covariant _ReaderBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.message.id != widget.message.id) {
      _loadRemoteImagesOnce = false;
      _loadExternalStylesAndFontsOnce = false;
      _allowedRemoteImageIds.clear();
      _appearanceOverride = null;
      _clearRenderedCache();
    }
  }

  @override
  Widget build(BuildContext context) {
    final message = widget.message;
    final canReplyAll =
        message.to.isNotEmpty ||
        message.cc.isNotEmpty ||
        message.replyTo.isNotEmpty;
    final effectiveMailbox = message.effectiveMailbox;
    final canDelete = effectiveMailbox != MailboxKind.trash;
    final moveDestinations = standardMailboxKinds
        .where((kind) => kind != effectiveMailbox)
        .toList(growable: false);
    final hostIsDark =
        Theme.of(context).colorScheme.brightness == Brightness.dark;
    final effectiveAppearance =
        _appearanceOverride ?? widget.renderSettings.appearance;
    final renderPolicy = MailHtmlRenderPolicy(
      loadRemoteImages:
          widget.renderSettings.autoLoadRemoteImages || _loadRemoteImagesOnce,
      loadExternalStylesAndFonts:
          widget.renderSettings.autoLoadExternalStylesAndFonts ||
          _loadExternalStylesAndFontsOnce,
      allowedRemoteImageIds: Set.unmodifiable(_allowedRemoteImageIds),
      appearance: effectiveAppearance,
      hostIsDark: hostIsDark,
    );
    final rendered = _renderedFor(
      htmlBody: message.htmlBody,
      textBody: message.body.isEmpty ? message.preview : message.body,
      policy: renderPolicy,
    );
    final title = Text(
      mailMessageSubjectLabel(message.subject),
      style: Theme.of(
        context,
      ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600),
      maxLines: widget.mobileFullScreen ? 3 : 2,
      overflow: TextOverflow.ellipsis,
    );
    final actionButtons = <Widget>[
      if (_canMoveToInbox(effectiveMailbox))
        IconButton(
          tooltip: 'Move to Inbox',
          onPressed:
              _acting
                  ? null
                  : () => _runAction(widget.onMoveToInbox, closeAfter: true),
          icon: const Icon(Icons.move_to_inbox_outlined),
        )
      else
        IconButton(
          tooltip: 'Archive',
          onPressed:
              _acting
                  ? null
                  : () => _runAction(widget.onArchive, closeAfter: true),
          icon: const Icon(Icons.archive_outlined),
        ),
      PopupMenuButton<MailboxKind>(
        tooltip: 'Move to...',
        enabled: !_acting && moveDestinations.isNotEmpty,
        icon: const Icon(Icons.drive_file_move_outlined),
        onSelected:
            (destination) => _runAction(
              (message) => widget.onMoveToMailbox(message, destination),
              closeAfter: true,
            ),
        itemBuilder:
            (context) => [
              for (final kind in moveDestinations)
                PopupMenuItem(
                  value: kind,
                  child: Row(
                    children: [
                      Icon(_iconForMailbox(kind), size: 18),
                      const SizedBox(width: 10),
                      Text(_labelForMailbox(kind)),
                    ],
                  ),
                ),
            ],
      ),
      IconButton(
        tooltip: message.starred ? 'Unstar' : 'Star',
        onPressed:
            _acting
                ? null
                : () => _runAction(
                  (message) => widget.onSetStarred(message, !message.starred),
                ),
        icon: Icon(message.starred ? Icons.star : Icons.star_border),
      ),
      IconButton(
        tooltip: message.read ? 'Mark unread' : 'Mark read',
        onPressed:
            _acting
                ? null
                : () => _runAction(
                  (message) => widget.onSetRead(message, !message.read),
                ),
        icon: Icon(
          message.read
              ? Icons.mark_email_unread_outlined
              : Icons.mark_email_read_outlined,
        ),
      ),
      IconButton(
        tooltip: canDelete ? 'Delete' : 'Already in Trash',
        onPressed:
            _acting || !canDelete
                ? null
                : () => _runAction(widget.onDelete, closeAfter: true),
        icon: const Icon(Icons.delete_outline),
      ),
      IconButton(
        tooltip: 'Reply',
        onPressed: _sending ? null : _showReplyComposer,
        icon: const Icon(Icons.reply),
      ),
      if (canReplyAll)
        IconButton(
          tooltip: 'Reply all',
          onPressed: _sending ? null : () => _showReplyComposer(replyAll: true),
          icon: const Icon(Icons.reply_all),
        ),
      IconButton(
        tooltip: 'Forward',
        onPressed: _acting ? null : () => widget.onForward(widget.message),
        icon: const Icon(Icons.forward),
      ),
      PopupMenuButton<_MessageAppearanceAction>(
        tooltip:
            _appearanceOverride == null
                ? 'Message appearance: ${widget.renderSettings.appearance.label} setting'
                : 'Message appearance: ${_appearanceOverride!.label} for this message',
        icon: Icon(
          _iconForMailAppearance(effectiveAppearance),
          color:
              _appearanceOverride == null
                  ? null
                  : Theme.of(context).colorScheme.primary,
        ),
        onSelected: _setMessageAppearance,
        itemBuilder:
            (context) => [
              PopupMenuItem(
                value: _MessageAppearanceAction.useSetting,
                child: Row(
                  children: [
                    const Icon(Icons.settings_suggest_outlined),
                    const SizedBox(width: 12),
                    Text(
                      'Use setting (${widget.renderSettings.appearance.label})',
                    ),
                  ],
                ),
              ),
              for (final appearance in MailAppearance.values)
                PopupMenuItem(
                  value: _messageAppearanceActionFor(appearance),
                  child: Row(
                    children: [
                      Icon(_iconForMailAppearance(appearance)),
                      const SizedBox(width: 12),
                      Text(appearance.label),
                    ],
                  ),
                ),
            ],
      ),
    ];
    final header =
        widget.mobileFullScreen
            ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (widget.onClose != null)
                      IconButton(
                        tooltip: 'Back',
                        onPressed: widget.onClose,
                        icon: const Icon(Icons.arrow_back),
                      ),
                    Expanded(child: title),
                  ],
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(children: actionButtons),
                  ),
                ),
              ],
            )
            : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Organize actions on the left, reply actions on the right.
                Row(
                  children: [
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(children: actionButtons.sublist(0, 5)),
                      ),
                    ),
                    ...actionButtons.sublist(5),
                  ],
                ),
                const SizedBox(height: 14),
                title,
              ],
            );
    return Padding(
      padding:
          widget.mobileFullScreen
              ? const EdgeInsets.fromLTRB(16, 12, 16, 0)
              : const EdgeInsets.fromLTRB(20, 10, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          header,
          const SizedBox(height: 12),
          _ReaderSenderHeader(message: message),
          if (widget.mailboxContextLabel.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: [
                  Icon(
                    Icons.folder_outlined,
                    size: 16,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'In ${widget.mailboxContextLabel}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (rendered.summary.hasBlockedExternalNonImageResources ||
              rendered.summary.removedScripts > 0) ...[
            const SizedBox(height: 12),
            _MailResourceWarning(
              icon: Icons.shield_outlined,
              title: _externalResourceWarningTitle(rendered.summary),
              message: _externalResourceWarningMessage(rendered.summary),
              actionLabel:
                  rendered.summary.hasBlockedExternalNonImageResources
                      ? 'Allow once'
                      : null,
              onAction:
                  rendered.summary.hasBlockedExternalNonImageResources
                      ? () {
                        setState(() {
                          _loadExternalStylesAndFontsOnce = true;
                        });
                      }
                      : null,
            ),
          ],
          if (rendered.summary.hasBlockedImages &&
              !renderPolicy.loadRemoteImages) ...[
            const SizedBox(height: 8),
            _MailResourceWarning(
              icon: Icons.image_not_supported_outlined,
              title: _imageResourceWarningTitle(rendered.summary),
              message: 'Remote images are not loaded automatically.',
              actionLabel: 'Load images',
              onAction: () {
                setState(() => _loadRemoteImagesOnce = true);
              },
            ),
          ],
          const SizedBox(height: 24),
          Expanded(
            child: ListView(
              children: [
                if (!message.bodyLoaded && widget.bodyLoading) ...[
                  const LinearProgressIndicator(),
                  const SizedBox(height: 12),
                  Text(
                    'Loading full message...',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  if (message.preview.trim().isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(
                      message.preview.trim(),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                ],
                MailHtmlView(
                  rendered: rendered,
                  policy: renderPolicy,
                  onLoadRemoteImagesOnce: () {
                    setState(() => _loadRemoteImagesOnce = true);
                  },
                  onLoadRemoteImageOnce: (imageId) {
                    setState(() => _allowedRemoteImageIds.add(imageId));
                  },
                ),
                if (message.attachments.isNotEmpty) ...[
                  const SizedBox(height: 24),
                  Text(
                    'Attachments',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  const SizedBox(height: 8),
                  for (final attachment in message.attachments) ...[
                    Builder(
                      builder: (context) {
                        final key = _attachmentKey(attachment);
                        final downloading = _downloadingAttachment == key;
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.attach_file),
                          title: Text(
                            attachment.filename,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(_attachmentSubtitle(attachment)),
                          trailing: IconButton(
                            tooltip:
                                attachment.partId.isEmpty
                                    ? 'Attachment unavailable'
                                    : 'Download and open',
                            onPressed:
                                attachment.partId.isEmpty || downloading
                                    ? null
                                    : () => _downloadAttachment(attachment),
                            icon:
                                downloading
                                    ? const SizedBox.square(
                                      dimension: 18,
                                      child: CircularProgressIndicator(),
                                    )
                                    : const Icon(Icons.download_outlined),
                          ),
                        );
                      },
                    ),
                  ],
                ],
              ],
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
    );
  }

  MailHtmlRenderResult _renderedFor({
    required String htmlBody,
    required String textBody,
    required MailHtmlRenderPolicy policy,
  }) {
    final cached = _cachedRendered;
    if (cached != null &&
        _cachedRenderedHtmlBody == htmlBody &&
        _cachedRenderedTextBody == textBody &&
        _sameRenderPolicy(_cachedRenderPolicy, policy)) {
      return cached;
    }
    final rendered = buildMailHtmlDocument(
      htmlBody: htmlBody,
      textBody: textBody,
      policy: policy,
    );
    _cachedRendered = rendered;
    _cachedRenderedHtmlBody = htmlBody;
    _cachedRenderedTextBody = textBody;
    _cachedRenderPolicy = policy;
    return rendered;
  }

  bool _sameRenderPolicy(
    MailHtmlRenderPolicy? previous,
    MailHtmlRenderPolicy next,
  ) {
    return previous != null &&
        previous.loadRemoteImages == next.loadRemoteImages &&
        previous.loadExternalStylesAndFonts ==
            next.loadExternalStylesAndFonts &&
        previous.appearance == next.appearance &&
        previous.hostIsDark == next.hostIsDark &&
        setEquals(previous.allowedRemoteImageIds, next.allowedRemoteImageIds);
  }

  void _clearRenderedCache() {
    _cachedRendered = null;
    _cachedRenderedHtmlBody = null;
    _cachedRenderedTextBody = null;
    _cachedRenderPolicy = null;
  }

  void _setMessageAppearance(_MessageAppearanceAction action) {
    setState(() {
      _appearanceOverride = switch (action) {
        _MessageAppearanceAction.useSetting => null,
        _MessageAppearanceAction.automatic => MailAppearance.automatic,
        _MessageAppearanceAction.light => MailAppearance.light,
        _MessageAppearanceAction.dark => MailAppearance.dark,
      };
    });
  }

  Future<void> _showReplyComposer({bool replyAll = false}) async {
    final result = await _openReplyComposer(replyAll ? 'Reply all' : 'Reply');
    if (result == null || result.textBody.trim().isEmpty) return;
    await _sendReplyContent(result, replyAll: replyAll);
  }

  Future<_ReplyComposerResult?> _openReplyComposer(String title) {
    if (widget.mobileFullScreen) {
      return Navigator.of(context).push<_ReplyComposerResult>(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder:
              (context) => Scaffold(
                body: SafeArea(
                  child: _ReplyComposerSurface(title: title, fullScreen: true),
                ),
              ),
        ),
      );
    }
    return showDialog<_ReplyComposerResult>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        final size = MediaQuery.sizeOf(context);
        final availableWidth = size.width - 96;
        final availableHeight = size.height - 96;
        final width =
            availableWidth > 0 && availableWidth < 720 ? availableWidth : 720.0;
        final height =
            availableHeight > 0 && availableHeight < 560
                ? availableHeight
                : 560.0;
        return Dialog(
          clipBehavior: Clip.antiAlias,
          child: SizedBox(
            width: width,
            height: height,
            child: _ReplyComposerSurface(title: title, fullScreen: false),
          ),
        );
      },
    );
  }

  Future<void> _sendReplyContent(
    _ReplyComposerResult result, {
    bool replyAll = false,
  }) async {
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      if (replyAll) {
        await widget.onSendReplyAll(
          widget.message,
          result.textBody,
          htmlBody: result.htmlBody,
          attachments: result.attachments,
        );
      } else {
        await widget.onSendReply(
          widget.message,
          result.textBody,
          htmlBody: result.htmlBody,
          attachments: result.attachments,
        );
      }
      if (mounted) setState(() => _sending = false);
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error.toString();
          _sending = false;
        });
      }
    }
  }

  Future<void> _runAction(
    Future<void> Function(MailMessage message) action, {
    bool closeAfter = false,
  }) async {
    setState(() {
      _acting = true;
      _error = null;
    });
    try {
      await action(widget.message);
      if (!mounted) return;
      setState(() => _acting = false);
      if (closeAfter && widget.mobileFullScreen) {
        widget.onClose?.call();
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error.toString();
          _acting = false;
        });
      }
    }
  }

  Future<void> _downloadAttachment(MailAttachment attachment) async {
    final key = _attachmentKey(attachment);
    setState(() {
      _downloadingAttachment = key;
      _error = null;
    });
    try {
      await widget.onDownloadAttachment(widget.message, attachment);
      if (mounted) setState(() => _downloadingAttachment = null);
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error.toString();
          _downloadingAttachment = null;
        });
      }
    }
  }
}

class _MailResourceWarning extends StatelessWidget {
  const _MailResourceWarning({
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        border: Border.all(color: colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: colorScheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title, style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: 2),
                Text(
                  message,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(width: 10),
            TextButton(onPressed: onAction, child: Text(actionLabel!)),
          ],
        ],
      ),
    );
  }
}

class _ReplyComposerResult {
  const _ReplyComposerResult({
    required this.textBody,
    required this.htmlBody,
    this.attachments = const [],
  });

  final String textBody;
  final String htmlBody;
  final List<OutgoingAttachment> attachments;
}

class _ReplyComposerSurface extends StatefulWidget {
  const _ReplyComposerSurface({required this.title, required this.fullScreen});

  final String title;
  final bool fullScreen;

  @override
  State<_ReplyComposerSurface> createState() => _ReplyComposerSurfaceState();
}

class _ReplyComposerSurfaceState extends State<_ReplyComposerSurface> {
  final _plainText = TextEditingController();
  final _attachments = <OutgoingAttachment>[];
  InAppWebViewController? _webController;
  bool _editorReady = false;
  bool _finishing = false;
  String? _error;

  @override
  void dispose() {
    _plainText.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            if (widget.fullScreen)
              IconButton(
                tooltip: 'Back',
                onPressed: _finishing ? null : _requestClose,
                icon: const Icon(Icons.arrow_back),
              ),
            Expanded(
              child: Text(
                widget.title,
                style: Theme.of(context).textTheme.titleLarge,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              tooltip: 'Close',
              onPressed: _finishing ? null : _requestClose,
              icon: const Icon(Icons.close),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (_supportsReplyRichEditor) ...[
          _ReplyComposerToolbar(
            enabled: _editorReady && !_finishing,
            onCommand: _execEditorCommand,
            onInsertLink: _insertLink,
          ),
          const SizedBox(height: 8),
        ],
        Expanded(
          child:
              _supportsReplyRichEditor
                  ? _richEditor(context)
                  : TextField(
                    controller: _plainText,
                    autofocus: true,
                    expands: true,
                    minLines: null,
                    maxLines: null,
                    textAlignVertical: TextAlignVertical.top,
                    decoration: const InputDecoration(
                      hintText: 'Write a reply',
                      border: OutlineInputBorder(),
                    ),
                  ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            OutlinedButton.icon(
              onPressed: _finishing ? null : _pickAttachments,
              icon: const Icon(Icons.attach_file),
              label: const Text('Attach'),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _attachments.isEmpty
                    ? 'No attachments'
                    : '${_attachments.length} attached - '
                        '${_formatBytes(_attachmentTotalBytes)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        if (_attachments.isNotEmpty) ...[
          const SizedBox(height: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 108),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: _attachments.length,
              itemBuilder: (context, index) {
                final attachment = _attachments[index];
                return ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.insert_drive_file_outlined),
                  title: Text(
                    attachment.filename,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(_outgoingAttachmentSubtitle(attachment)),
                  trailing: IconButton(
                    tooltip: 'Remove attachment',
                    onPressed:
                        _finishing
                            ? null
                            : () {
                              setState(() => _attachments.removeAt(index));
                            },
                    icon: const Icon(Icons.close),
                  ),
                );
              },
            ),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: _finishing ? null : _requestClose,
              child: const Text('Cancel'),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: _finishing ? null : _finish,
              icon:
                  _finishing
                      ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                      : const Icon(Icons.send),
              label: const Text('Send'),
            ),
          ],
        ),
      ],
    );
    return Padding(
      padding:
          widget.fullScreen
              ? const EdgeInsets.fromLTRB(12, 8, 12, 12)
              : const EdgeInsets.all(20),
      child: content,
    );
  }

  Widget _richEditor(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final dark = colorScheme.brightness == Brightness.dark;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: InAppWebView(
          initialData: InAppWebViewInitialData(
            data: _replyEditorHtml(dark: dark),
            mimeType: 'text/html',
            encoding: 'utf8',
            baseUrl: WebUri('about:blank'),
          ),
          initialSettings: InAppWebViewSettings(
            javaScriptEnabled: true,
            javaScriptCanOpenWindowsAutomatically: false,
            mediaPlaybackRequiresUserGesture: true,
            useShouldOverrideUrlLoading: true,
            useShouldInterceptRequest: true,
            cacheEnabled: false,
            clearCache: true,
            incognito: true,
            transparentBackground: false,
            supportZoom: false,
          ),
          onWebViewCreated: (controller) => _webController = controller,
          onLoadStop: (controller, _) {
            if (!mounted) return;
            setState(() => _editorReady = true);
            unawaited(_focusEditor());
          },
          shouldOverrideUrlLoading: (controller, action) async {
            final uri = Uri.tryParse(action.request.url?.toString() ?? '');
            if (uri != null && uri.scheme == 'about') {
              return NavigationActionPolicy.ALLOW;
            }
            return NavigationActionPolicy.CANCEL;
          },
          shouldInterceptRequest: (controller, request) async {
            final uri = Uri.tryParse(request.url.toString());
            if (uri == null || !_isRemoteHttpUri(uri)) return null;
            return WebResourceResponse(
              contentType: 'text/plain',
              contentEncoding: 'utf-8',
              data: Uint8List.fromList(utf8.encode('')),
              headers: const {},
              statusCode: 204,
              reasonPhrase: 'No Content',
            );
          },
        ),
      ),
    );
  }

  Future<void> _focusEditor() async {
    try {
      await _webController?.evaluateJavascript(
        source: 'window.nyamailFocusEditor && window.nyamailFocusEditor();',
      );
    } catch (_) {
      // Focusing is best-effort; the user can still tap into the editor.
    }
  }

  Future<void> _execEditorCommand(String command) async {
    await _evaluateEditorCommand(command);
  }

  Future<void> _evaluateEditorCommand(
    String command, [
    String value = '',
  ]) async {
    final controller = _webController;
    if (controller == null || !_editorReady) return;
    try {
      await controller.evaluateJavascript(
        source:
            'window.nyamailExecCommand && '
            'window.nyamailExecCommand(${jsonEncode(command)}, ${jsonEncode(value)});',
      );
      await _focusEditor();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _insertLink() async {
    final controller = TextEditingController();
    try {
      final raw = await showDialog<String>(
        context: context,
        builder:
            (context) => AlertDialog(
              title: const Text('Insert link'),
              content: TextField(
                controller: controller,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'URL',
                  hintText: 'https://example.com',
                ),
                keyboardType: TextInputType.url,
                onSubmitted: (value) => Navigator.of(context).pop(value),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(controller.text),
                  child: const Text('Insert'),
                ),
              ],
            ),
      );
      final url = _normalizeComposerLink(raw);
      if (url == null) return;
      await _evaluateEditorCommand('createLink', url);
    } finally {
      controller.dispose();
    }
  }

  int get _attachmentTotalBytes {
    return _attachments.fold<int>(
      0,
      (total, attachment) => total + attachment.bytes.length,
    );
  }

  Future<void> _pickAttachments() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        withData: true,
      );
      if (result == null) return;
      final selected = <OutgoingAttachment>[];
      for (final file in result.files) {
        final bytes = file.bytes;
        if (bytes == null) {
          setState(() => _error = 'Could not read ${file.name}.');
          return;
        }
        selected.add(
          OutgoingAttachment(
            filename: file.name,
            contentType: _contentTypeForFilename(file.name),
            bytes: bytes,
          ),
        );
      }
      final total =
          _attachmentTotalBytes +
          selected.fold<int>(
            0,
            (sum, attachment) => sum + attachment.bytes.length,
          );
      if (total > _maxOutgoingAttachmentBytes) {
        setState(
          () =>
              _error =
                  'Attachments must be ${_formatBytes(_maxOutgoingAttachmentBytes)} or less.',
        );
        return;
      }
      setState(() {
        _attachments.addAll(selected);
        _error = null;
      });
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _finish() async {
    setState(() {
      _finishing = true;
      _error = null;
    });
    try {
      final result = await _currentContent();
      if (!_hasSendableMailContent(
        textBody: result.textBody,
        attachments: result.attachments,
      )) {
        if (mounted) {
          setState(() {
            _error = 'Add a message or attachment.';
            _finishing = false;
          });
        }
        return;
      }
      if (mounted) Navigator.of(context).pop(result);
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error.toString();
          _finishing = false;
        });
      }
    }
  }

  Future<void> _requestClose() async {
    try {
      final result = await _currentContent();
      final hasDraft = _hasSendableMailContent(
        textBody: result.textBody,
        attachments: result.attachments,
      );
      if (!hasDraft) {
        if (mounted) Navigator.of(context).pop();
        return;
      }
      if (!mounted) return;
      final discard =
          await showDialog<bool>(
            context: context,
            builder:
                (context) => AlertDialog(
                  title: const Text('Discard reply?'),
                  content: const Text(
                    'This reply has unsent content or attachments.',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      child: const Text('Keep editing'),
                    ),
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: Theme.of(context).colorScheme.error,
                        foregroundColor: Theme.of(context).colorScheme.onError,
                      ),
                      onPressed: () => Navigator.of(context).pop(true),
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('Discard'),
                    ),
                  ],
                ),
          ) ??
          false;
      if (discard && mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<_ReplyComposerResult> _currentContent() async {
    if (!_supportsReplyRichEditor) {
      final text = _plainText.text.trim();
      return _ReplyComposerResult(
        textBody: text,
        htmlBody: _plainTextToOutgoingHtml(text),
        attachments: List<OutgoingAttachment>.unmodifiable(_attachments),
      );
    }
    final controller = _webController;
    if (controller == null || !_editorReady) {
      return _ReplyComposerResult(
        textBody: '',
        htmlBody: '',
        attachments: List<OutgoingAttachment>.unmodifiable(_attachments),
      );
    }
    final raw = await controller.evaluateJavascript(
      source: 'JSON.stringify(window.nyamailGetContent());',
    );
    final decoded = _decodeReplyEditorContent(raw);
    final text = _normalizeReplyText(decoded['text'] as String? ?? '');
    final html = _normalizeReplyHtml(decoded['html'] as String? ?? '', text);
    return _ReplyComposerResult(
      textBody: text,
      htmlBody: html,
      attachments: List<OutgoingAttachment>.unmodifiable(_attachments),
    );
  }
}

class _ReplyComposerToolbar extends StatelessWidget {
  const _ReplyComposerToolbar({
    required this.enabled,
    required this.onCommand,
    required this.onInsertLink,
  });

  final bool enabled;
  final ValueChanged<String> onCommand;
  final VoidCallback onInsertLink;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          _button(
            icon: Icons.format_bold,
            tooltip: 'Bold',
            onPressed: () => onCommand('bold'),
          ),
          _button(
            icon: Icons.format_italic,
            tooltip: 'Italic',
            onPressed: () => onCommand('italic'),
          ),
          _button(
            icon: Icons.format_underlined,
            tooltip: 'Underline',
            onPressed: () => onCommand('underline'),
          ),
          const SizedBox(width: 6),
          _button(
            icon: Icons.format_list_bulleted,
            tooltip: 'Bulleted list',
            onPressed: () => onCommand('insertUnorderedList'),
          ),
          _button(
            icon: Icons.format_list_numbered,
            tooltip: 'Numbered list',
            onPressed: () => onCommand('insertOrderedList'),
          ),
          const SizedBox(width: 6),
          _button(
            icon: Icons.link,
            tooltip: 'Insert link',
            onPressed: onInsertLink,
          ),
          _button(
            icon: Icons.format_clear,
            tooltip: 'Clear formatting',
            onPressed: () => onCommand('removeFormat'),
          ),
        ],
      ),
    );
  }

  Widget _button({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    return IconButton(
      tooltip: tooltip,
      onPressed: enabled ? onPressed : null,
      icon: Icon(icon),
      visualDensity: VisualDensity.compact,
    );
  }
}

bool get _supportsReplyRichEditor {
  if (kIsWeb) return true;
  return switch (defaultTargetPlatform) {
    TargetPlatform.android ||
    TargetPlatform.iOS ||
    TargetPlatform.macOS ||
    TargetPlatform.windows => true,
    TargetPlatform.fuchsia || TargetPlatform.linux => false,
  };
}

String _replyEditorHtml({
  required bool dark,
  String initialText = '',
  String initialHtml = '',
  String placeholderText = 'Write a reply',
}) {
  final background = dark ? '#111315' : '#FFFFFF';
  final text = dark ? '#E8EAED' : '#202124';
  final caret = dark ? '#8AB4F8' : '#0B57D0';
  final placeholder = dark ? '#9AA0A6' : '#5F6368';
  final editorInitialHtml =
      initialHtml.trim().isNotEmpty
          ? initialHtml
          : initialText.trim().isEmpty
          ? ''
          : _plainTextToOutgoingHtml(initialText);
  final initialHtmlBase64Json = jsonEncode(
    base64Encode(utf8.encode(editorInitialHtml)),
  );
  final placeholderJson = jsonEncode(placeholderText);
  return '''
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
:root {
  color-scheme: ${dark ? 'dark' : 'light'};
  background: $background;
  font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
}
html, body {
  min-height: 100%;
  margin: 0;
  background: $background;
  color: $text;
}
#editor {
  min-height: 100vh;
  box-sizing: border-box;
  padding: 14px;
  outline: none;
  caret-color: $caret;
  overflow-wrap: anywhere;
  font-size: 15px;
  line-height: 1.55;
}
#editor:empty::before {
  content: $placeholderJson;
  color: $placeholder;
}
a { color: $caret; }
blockquote {
  margin: 8px 0;
  padding-left: 12px;
  border-left: 3px solid $placeholder;
}
</style>
</head>
<body>
<div id="editor" contenteditable="true" role="textbox" aria-multiline="true"></div>
<script>
(function () {
  const editor = document.getElementById('editor');
  function decodeInitialHtml(value) {
    try {
      const bytes = Uint8Array.from(atob(value), (character) => character.charCodeAt(0));
      return new TextDecoder('utf-8').decode(bytes);
    } catch (_) {
      return '';
    }
  }
  editor.innerHTML = decodeInitialHtml($initialHtmlBase64Json);
  function safeHref(value) {
    const normalized = String(value || '').trim().toLowerCase();
    return normalized.startsWith('http://') ||
      normalized.startsWith('https://') ||
      normalized.startsWith('mailto:') ||
      normalized.startsWith('tel:');
  }
  function sanitize() {
    editor.querySelectorAll('script, style, link, iframe, object, embed, meta, base, form, input, button, textarea, select, img').forEach((node) => node.remove());
    editor.querySelectorAll('*').forEach((node) => {
      Array.from(node.attributes).forEach((attribute) => {
        const name = attribute.name.toLowerCase();
        if (name.startsWith('on') || name === 'style' || name === 'src' || name === 'srcset') {
          node.removeAttribute(attribute.name);
        }
        if (name === 'href' && !safeHref(attribute.value)) {
          node.removeAttribute(attribute.name);
        }
      });
      if (node.tagName === 'A') {
        node.setAttribute('rel', 'noopener noreferrer');
      }
    });
  }
  sanitize();
  editor.addEventListener('paste', () => window.setTimeout(sanitize, 0));
  window.nyamailFocusEditor = function () {
    editor.focus();
  };
  window.nyamailExecCommand = function (command, value) {
    editor.focus();
    document.execCommand(command, false, value || null);
    sanitize();
  };
  window.nyamailGetContent = function () {
    sanitize();
    return {
      html: editor.innerHTML || '',
      text: editor.innerText || ''
    };
  };
  editor.focus();
})();
</script>
</body>
</html>
''';
}

Map<String, Object?> _decodeReplyEditorContent(Object? raw) {
  if (raw is Map) return raw.cast<String, Object?>();
  var value = raw?.toString() ?? '{}';
  for (var attempt = 0; attempt < 2; attempt++) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is Map) return decoded.cast<String, Object?>();
      if (decoded is String) {
        value = decoded;
        continue;
      }
    } catch (_) {
      break;
    }
  }
  return const {};
}

String _normalizeReplyText(String value) {
  return value.replaceAll('\u00a0', ' ').trim();
}

String _normalizeReplyHtml(String html, String text) {
  final normalized = html.trim();
  if (text.trim().isEmpty) return '';
  if (normalized.isEmpty || normalized == '<br>') {
    return _plainTextToOutgoingHtml(text);
  }
  return '<div>$normalized</div>';
}

String _plainTextToOutgoingHtml(String text) {
  final escaped = const HtmlEscape(HtmlEscapeMode.element).convert(text.trim());
  return '<div>${escaped.replaceAll('\n', '<br>')}</div>';
}

bool _hasSendableMailContent({
  String subject = '',
  String textBody = '',
  List<OutgoingAttachment> attachments = const [],
}) {
  return subject.trim().isNotEmpty ||
      textBody.trim().isNotEmpty ||
      attachments.isNotEmpty;
}

String? _normalizeComposerLink(String? raw) {
  final value = raw?.trim();
  if (value == null || value.isEmpty) return null;
  final withScheme =
      RegExp(r'^[a-z][a-z0-9+.-]*:', caseSensitive: false).hasMatch(value)
          ? value
          : value.contains('@') && !value.contains('/')
          ? 'mailto:$value'
          : 'https://$value';
  final uri = Uri.tryParse(withScheme);
  if (uri == null) return null;
  final scheme = uri.scheme.toLowerCase();
  if (scheme == 'http' ||
      scheme == 'https' ||
      scheme == 'mailto' ||
      scheme == 'tel') {
    return uri.toString();
  }
  return null;
}

bool _isRemoteHttpUri(Uri uri) {
  final scheme = uri.scheme.toLowerCase();
  return scheme == 'http' || scheme == 'https';
}

String _externalResourceWarningTitle(MailHtmlResourceSummary summary) {
  final count = summary.blockedExternalNonImageResources;
  if (count <= 0) return 'Active content removed';
  return count == 1
      ? '1 external style or font blocked'
      : '$count external styles or fonts blocked';
}

String _externalResourceWarningMessage(MailHtmlResourceSummary summary) {
  final parts = <String>[];
  if (summary.blockedExternalStyles > 0) {
    parts.add('${summary.blockedExternalStyles} CSS');
  }
  if (summary.blockedExternalFonts > 0) {
    parts.add('${summary.blockedExternalFonts} font');
  }
  if (summary.blockedCssResources > 0) {
    parts.add('${summary.blockedCssResources} CSS URL');
  }
  if (summary.removedScripts > 0) {
    parts.add('${summary.removedScripts} script');
  }
  if (parts.isEmpty) return 'Scripts are always blocked.';
  return '${parts.join(', ')} removed or blocked for this message.';
}

String _imageResourceWarningTitle(MailHtmlResourceSummary summary) {
  final total = summary.blockedRemoteImages + summary.blockedInlineImages;
  if (total == 1) return '1 image blocked';
  return '$total images blocked';
}
