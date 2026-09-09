import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';

import '../mail/mail_html_sanitizer.dart';

class MailHtmlView extends StatefulWidget {
  const MailHtmlView({
    required this.rendered,
    required this.policy,
    required this.onLoadRemoteImagesOnce,
    required this.onLoadRemoteImageOnce,
    super.key,
  });

  final MailHtmlRenderResult rendered;
  final MailHtmlRenderPolicy policy;
  final VoidCallback onLoadRemoteImagesOnce;
  final ValueChanged<String> onLoadRemoteImageOnce;

  @override
  State<MailHtmlView> createState() => _MailHtmlViewState();
}

class _MailHtmlViewState extends State<MailHtmlView> {
  static const _initialHeight = 240.0;
  static const _minimumHeight = 96.0;
  static const _maximumHeight = 30000.0;

  /// Ignore height reports that only nudge the pane by a few pixels. Combined
  /// with the JS-side coalescing this stops the WebView <-> Flutter resize loop
  /// that otherwise locks the UI thread while the window is being resized.
  static const _heightChangeThreshold = 8.0;
  static const _heightApplyDelay = Duration(milliseconds: 90);

  double _height = _initialHeight;
  double _reportedHeight = _initialHeight;
  Timer? _heightApplyTimer;
  bool _loadImagesTriggered = false;

  @override
  void didUpdateWidget(covariant MailHtmlView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.rendered.html != widget.rendered.html ||
        oldWidget.policy.loadRemoteImages != widget.policy.loadRemoteImages ||
        oldWidget.policy.loadExternalStylesAndFonts !=
            widget.policy.loadExternalStylesAndFonts) {
      _heightApplyTimer?.cancel();
      _heightApplyTimer = null;
      _height = _initialHeight;
      _reportedHeight = _initialHeight;
      _loadImagesTriggered = false;
    }
  }

  @override
  void dispose() {
    _heightApplyTimer?.cancel();
    super.dispose();
  }

  void _onReportedHeight(double raw) {
    final clamped = raw.clamp(_minimumHeight, _maximumHeight).toDouble();
    _reportedHeight = clamped;
    if ((clamped - _height).abs() < _heightChangeThreshold) return;
    _heightApplyTimer ??= Timer(_heightApplyDelay, () {
      _heightApplyTimer = null;
      if (!mounted) return;
      if ((_reportedHeight - _height).abs() < _heightChangeThreshold) return;
      setState(() => _height = _reportedHeight);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_supportsInlineWebView) {
      return SelectableText(
        widget.rendered.textFallback,
        style: Theme.of(context).textTheme.bodyLarge,
      );
    }

    void triggerLoadImagesOnce() {
      if (_loadImagesTriggered) return;
      _loadImagesTriggered = true;
      widget.onLoadRemoteImagesOnce();
    }

    void triggerLoadImageOnce(String imageId) {
      if (_loadImagesTriggered) return;
      _loadImagesTriggered = true;
      widget.onLoadRemoteImageOnce(imageId);
    }

    return RepaintBoundary(
      child: ColoredBox(
        color: Color(widget.rendered.canvasColor),
        child: SizedBox(
          height: _height,
          child: ClipRect(
            child: InAppWebView(
              key: ValueKey(widget.rendered.documentKey),
              initialData: InAppWebViewInitialData(
                data: widget.rendered.html,
                mimeType: 'text/html',
                encoding: 'utf8',
                baseUrl: WebUri('about:blank'),
              ),
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                javaScriptCanOpenWindowsAutomatically: false,
                mediaPlaybackRequiresUserGesture: true,
                useShouldOverrideUrlLoading: true,
                useShouldInterceptRequest:
                    !widget.policy.loadRemoteImages ||
                    !widget.policy.loadExternalStylesAndFonts,
                cacheEnabled: false,
                clearCache: true,
                incognito: true,
                transparentBackground: true,
                disableContextMenu: true,
                supportZoom: true,
                useWideViewPort: true,
                loadWithOverviewMode: true,
                horizontalScrollBarEnabled: true,
                verticalScrollBarEnabled: false,
              ),
              onWebViewCreated: (controller) {
                controller.addJavaScriptHandler(
                  handlerName: 'nyamailHeight',
                  callback: (arguments) {
                    if (arguments.isEmpty) return null;
                    final raw = arguments.first;
                    final next =
                        raw is num ? raw.toDouble() : double.tryParse('$raw');
                    if (next == null || !mounted) return null;
                    _onReportedHeight(next);
                    return null;
                  },
                );
              },
              onLoadStop: (controller, url) async {
                await _installHeightObserver(controller);
              },
              shouldOverrideUrlLoading: (controller, action) async {
                final url = action.request.url;
                if (url == null) return NavigationActionPolicy.CANCEL;
                final uri = Uri.tryParse(url.toString());
                if (uri == null) return NavigationActionPolicy.CANCEL;
                final imageId = _loadImageIdFromUri(uri);
                if (imageId != null) {
                  triggerLoadImageOnce(imageId);
                  return NavigationActionPolicy.CANCEL;
                }
                if (_isLoadImagesUri(uri)) {
                  triggerLoadImagesOnce();
                  return NavigationActionPolicy.CANCEL;
                }
                if (uri.scheme == 'about' || uri.scheme == 'data') {
                  return NavigationActionPolicy.ALLOW;
                }
                if (_shouldOpenExternally(uri)) {
                  await launchUrl(uri, mode: LaunchMode.externalApplication);
                }
                return NavigationActionPolicy.CANCEL;
              },
              onLoadStart: (controller, url) async {
                final uri = Uri.tryParse(url?.toString() ?? '');
                if (uri == null) return;
                final imageId = _loadImageIdFromUri(uri);
                if (imageId != null) {
                  triggerLoadImageOnce(imageId);
                  await controller.stopLoading();
                  return;
                }
                if (!_isLoadImagesUri(uri)) return;
                triggerLoadImagesOnce();
                await controller.stopLoading();
              },
              shouldInterceptRequest: (controller, request) async {
                final uri = Uri.tryParse(request.url.toString());
                if (uri == null) return null;
                final imageId = _loadImageIdFromUri(uri);
                if (imageId != null) {
                  triggerLoadImageOnce(imageId);
                  return WebResourceResponse(
                    contentType: 'text/html',
                    contentEncoding: 'utf-8',
                    data: Uint8List.fromList(utf8.encode('')),
                    headers: const {},
                    statusCode: 204,
                    reasonPhrase: 'No Content',
                  );
                }
                if (_isLoadImagesUri(uri)) {
                  triggerLoadImagesOnce();
                  return WebResourceResponse(
                    contentType: 'text/html',
                    contentEncoding: 'utf-8',
                    data: Uint8List.fromList(utf8.encode('')),
                    headers: const {},
                    statusCode: 204,
                    reasonPhrase: 'No Content',
                  );
                }
                if (!_isRemoteHttpUri(uri)) return null;
                if (widget.policy.loadRemoteImages ||
                    _isAllowedRemoteImageUri(
                      uri,
                      widget.rendered.allowedRemoteImageUrls,
                    ) ||
                    widget.policy.loadExternalStylesAndFonts) {
                  return null;
                }
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
    );
  }

  Future<void> _installHeightObserver(InAppWebViewController controller) async {
    try {
      await controller.evaluateJavascript(
        source: '''
(function() {
  function fitWideContent() {
    function setImportant(node, name, value) {
      if (node.style.getPropertyValue(name) === value &&
          node.style.getPropertyPriority(name) === 'important') {
        return;
      }
      node.style.setProperty(name, value, 'important');
    }
    var selectors = [
      'img',
      'video',
      'canvas',
      'svg',
      'iframe',
      'pre'
    ];
    selectors.forEach(function(selector) {
      document.querySelectorAll(selector).forEach(function(node) {
        setImportant(node, 'max-width', '100%');
        setImportant(node, 'box-sizing', 'border-box');
        if (selector === 'img' || selector === 'video' || selector === 'canvas') {
          setImportant(node, 'height', 'auto');
        }
      });
    });
    document.querySelectorAll('td, th').forEach(function(node) {
      setImportant(node, 'word-break', 'break-word');
      setImportant(node, 'overflow-wrap', 'anywhere');
    });
    fitBodyToViewport();
  }
  function resetBodyFit(frame, root) {
    root.style.transform = '';
    root.style.width = '';
    frame.style.height = '';
    frame.dataset.nyamailScale = '1';
  }
  function fitBodyToViewport() {
    var frame = document.getElementById('nyamail-scale-frame');
    var root = document.getElementById('nyamail-fit-root');
    if (!frame || !root) return;
    resetBodyFit(frame, root);
    var viewport = Math.max(
      1,
      frame.clientWidth || document.documentElement.clientWidth || window.innerWidth || 1
    );
    var contentWidth = Math.max(
      root.scrollWidth || 0,
      root.offsetWidth || 0,
      root.getBoundingClientRect ? root.getBoundingClientRect().width || 0 : 0
    );
    if (contentWidth <= viewport + 1) return;
    var scale = viewport / contentWidth;
    if (!isFinite(scale) || scale <= 0 || scale >= 1) return;
    root.style.transform = 'scale(' + scale + ')';
    frame.style.height = Math.ceil((root.scrollHeight || root.offsetHeight || 0) * scale) + 'px';
    frame.dataset.nyamailScale = scale.toFixed(4);
  }
  function heightOf(node) {
    if (!node) return 0;
    return Math.max(
      node.scrollHeight || 0,
      node.offsetHeight || 0,
      node.clientHeight || 0
    );
  }
  function postHeight() {
    fitWideContent();
    var doc = document.documentElement;
    var body = document.body;
    var height = Math.ceil(Math.max(
      heightOf(doc),
      heightOf(body),
      document.scrollingElement ? document.scrollingElement.scrollHeight || 0 : 0
    ));
    window.flutter_inappwebview.callHandler('nyamailHeight', height);
  }
  // Coalesce observer bursts: measuring re-mutates the DOM (scaling wide
  // content, setting an explicit frame height), which would otherwise retrigger
  // the observers every frame and lock up the UI thread while the window is
  // being resized.
  var nyamailHeightScheduled = false;
  var nyamailHeightTimer = null;
  var nyamailLastPost = 0;
  function schedulePostHeight() {
    if (nyamailHeightScheduled) return;
    nyamailHeightScheduled = true;
    var run = function() {
      nyamailHeightScheduled = false;
      nyamailLastPost = Date.now();
      postHeight();
    };
    var since = Date.now() - nyamailLastPost;
    if (since >= 120) {
      (window.requestAnimationFrame || window.setTimeout)(run);
    } else {
      if (nyamailHeightTimer) clearTimeout(nyamailHeightTimer);
      nyamailHeightTimer = setTimeout(run, 120 - since);
    }
  }
  if (window.__nyamailResizeObserver) {
    window.__nyamailResizeObserver.disconnect();
  }
  if (window.ResizeObserver) {
    window.__nyamailResizeObserver = new ResizeObserver(schedulePostHeight);
    window.__nyamailResizeObserver.observe(document.documentElement);
  }
  if (window.__nyamailMutationObserver) {
    window.__nyamailMutationObserver.disconnect();
  }
  if (window.MutationObserver && document.body) {
    window.__nyamailMutationObserver = new MutationObserver(schedulePostHeight);
    window.__nyamailMutationObserver.observe(document.body, {
      childList: true,
      subtree: true
    });
  }
  fitWideContent();
  window.addEventListener('load', postHeight, { once: true });
  setTimeout(postHeight, 0);
  setTimeout(postHeight, 100);
  setTimeout(postHeight, 500);
  postHeight();
})();
''',
      );
    } catch (_) {
      // Height measurement is a rendering enhancement; keep the fallback size.
    }
  }
}

bool get _supportsInlineWebView {
  if (kIsWeb) return true;
  return switch (defaultTargetPlatform) {
    TargetPlatform.android ||
    TargetPlatform.iOS ||
    TargetPlatform.macOS ||
    TargetPlatform.windows => true,
    TargetPlatform.fuchsia || TargetPlatform.linux => false,
  };
}

bool _shouldOpenExternally(Uri uri) {
  final scheme = uri.scheme.toLowerCase();
  return scheme == 'http' ||
      scheme == 'https' ||
      scheme == 'mailto' ||
      scheme == 'tel';
}

bool _isLoadImagesUri(Uri uri) {
  final scheme = uri.scheme.toLowerCase();
  final host = uri.host.toLowerCase();
  if (scheme == 'nyamail' && host == 'load-images') {
    return true;
  }
  return (scheme == 'https' || scheme == 'http') &&
      host == 'nyamail.invalid' &&
      uri.path == '/load-images';
}

String? _loadImageIdFromUri(Uri uri) {
  final scheme = uri.scheme.toLowerCase();
  final host = uri.host.toLowerCase();
  if ((scheme == 'nyamail' && host == 'load-image') ||
      ((scheme == 'https' || scheme == 'http') &&
          host == 'nyamail.invalid' &&
          uri.path == '/load-image')) {
    final imageId = uri.queryParameters['id']?.trim();
    if (imageId != null && imageId.isNotEmpty) return imageId;
  }
  return null;
}

bool _isAllowedRemoteImageUri(Uri uri, Set<String> allowedUrls) {
  return allowedUrls.contains(uri.toString());
}

bool _isRemoteHttpUri(Uri uri) {
  final scheme = uri.scheme.toLowerCase();
  return scheme == 'http' || scheme == 'https';
}
