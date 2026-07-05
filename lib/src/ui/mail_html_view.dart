import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';

import '../mail/mail_html_sanitizer.dart';

class MailHtmlView extends StatelessWidget {
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
  Widget build(BuildContext context) {
    if (!_supportsInlineWebView) {
      return SelectableText(
        rendered.textFallback,
        style: Theme.of(context).textTheme.bodyLarge,
      );
    }
    var loadImagesTriggered = false;
    void triggerLoadImagesOnce() {
      if (loadImagesTriggered) return;
      loadImagesTriggered = true;
      onLoadRemoteImagesOnce();
    }

    void triggerLoadImageOnce(String imageId) {
      if (loadImagesTriggered) return;
      loadImagesTriggered = true;
      onLoadRemoteImageOnce(imageId);
    }

    return ColoredBox(
      color: Color(rendered.canvasColor),
      child: SizedBox(
        height: 520,
        child: ClipRect(
          child: InAppWebView(
            key: ValueKey(
              Object.hash(
                rendered.html,
                policy.loadRemoteImages,
                policy.loadExternalStylesAndFonts,
              ),
            ),
            initialData: InAppWebViewInitialData(
              data: rendered.html,
              mimeType: 'text/html',
              encoding: 'utf8',
              baseUrl: WebUri('about:blank'),
            ),
            initialSettings: InAppWebViewSettings(
              javaScriptEnabled: false,
              javaScriptCanOpenWindowsAutomatically: false,
              mediaPlaybackRequiresUserGesture: true,
              useShouldOverrideUrlLoading: true,
              useShouldInterceptRequest:
                  !policy.loadRemoteImages ||
                  !policy.loadExternalStylesAndFonts,
              cacheEnabled: false,
              clearCache: true,
              incognito: true,
              transparentBackground: true,
              disableContextMenu: true,
              supportZoom: true,
            ),
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
              if (policy.loadRemoteImages ||
                  _isAllowedRemoteImageUri(
                    uri,
                    rendered.allowedRemoteImageUrls,
                  ) ||
                  policy.loadExternalStylesAndFonts) {
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
    );
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
