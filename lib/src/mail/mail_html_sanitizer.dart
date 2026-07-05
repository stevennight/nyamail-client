import 'dart:convert';

import 'mail_appearance.dart';

const mailLoadImagesUrl = 'https://nyamail.invalid/load-images';
const mailLoadImageBaseUrl = 'https://nyamail.invalid/load-image';

String mailLoadImageUrl(String imageId) {
  return Uri.parse(
    mailLoadImageBaseUrl,
  ).replace(queryParameters: {'id': imageId}).toString();
}

class MailHtmlRenderPolicy {
  const MailHtmlRenderPolicy({
    required this.loadRemoteImages,
    required this.loadExternalStylesAndFonts,
    this.allowedRemoteImageIds = const <String>{},
    this.appearance = MailAppearance.automatic,
    this.hostIsDark = false,
  });

  final bool loadRemoteImages;
  final bool loadExternalStylesAndFonts;
  final Set<String> allowedRemoteImageIds;
  final MailAppearance appearance;
  final bool hostIsDark;
}

class MailHtmlRenderResult {
  const MailHtmlRenderResult({
    required this.html,
    required this.textFallback,
    required this.summary,
    required this.canvasColor,
    this.allowedRemoteImageUrls = const <String>{},
  });

  final String html;
  final String textFallback;
  final MailHtmlResourceSummary summary;
  final int canvasColor;
  final Set<String> allowedRemoteImageUrls;
}

class MailHtmlResourceSummary {
  const MailHtmlResourceSummary({
    this.blockedRemoteImages = 0,
    this.blockedInlineImages = 0,
    this.blockedExternalStyles = 0,
    this.blockedExternalFonts = 0,
    this.blockedCssResources = 0,
    this.removedScripts = 0,
  });

  final int blockedRemoteImages;
  final int blockedInlineImages;
  final int blockedExternalStyles;
  final int blockedExternalFonts;
  final int blockedCssResources;
  final int removedScripts;

  int get blockedExternalNonImageResources =>
      blockedExternalStyles + blockedExternalFonts + blockedCssResources;

  bool get hasBlockedExternalNonImageResources =>
      blockedExternalNonImageResources > 0;

  bool get hasBlockedImages => blockedRemoteImages + blockedInlineImages > 0;

  MailHtmlResourceSummary copyWith({
    int? blockedRemoteImages,
    int? blockedInlineImages,
    int? blockedExternalStyles,
    int? blockedExternalFonts,
    int? blockedCssResources,
    int? removedScripts,
  }) {
    return MailHtmlResourceSummary(
      blockedRemoteImages: blockedRemoteImages ?? this.blockedRemoteImages,
      blockedInlineImages: blockedInlineImages ?? this.blockedInlineImages,
      blockedExternalStyles:
          blockedExternalStyles ?? this.blockedExternalStyles,
      blockedExternalFonts: blockedExternalFonts ?? this.blockedExternalFonts,
      blockedCssResources: blockedCssResources ?? this.blockedCssResources,
      removedScripts: removedScripts ?? this.removedScripts,
    );
  }
}

MailHtmlRenderResult buildMailHtmlDocument({
  required String htmlBody,
  required String textBody,
  required MailHtmlRenderPolicy policy,
}) {
  final trimmedHtml = htmlBody.trim();
  final trimmedText = textBody.trim();
  final useTextBodyAsHtml =
      trimmedHtml.isEmpty && _looksLikeHtmlDocument(trimmedText);
  final source =
      trimmedHtml.isNotEmpty
          ? trimmedHtml
          : useTextBodyAsHtml
          ? trimmedText
          : _plainTextToHtml(trimmedText);
  final fallbackHtml =
      trimmedHtml.isNotEmpty
          ? trimmedHtml
          : useTextBodyAsHtml
          ? trimmedText
          : '';
  final fallback =
      trimmedText.isNotEmpty && !useTextBodyAsHtml
          ? trimmedText
          : (fallbackHtml.isNotEmpty ? _htmlToTextFallback(fallbackHtml) : '');
  final sanitizer = _MailHtmlSanitizer(policy);
  final palette = _paletteFor(policy);
  final body = sanitizer.sanitize(source);
  final csp = _contentSecurityPolicy(policy);
  final html = '''
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="$csp">
<style>
:root {
  color-scheme: ${palette.colorScheme};
  background: ${palette.canvas};
  font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
}
html {
  background: ${palette.canvas};
}
body {
  margin: 0;
  padding: 0;
  overflow-wrap: anywhere;
  color: ${palette.text};
  background: ${palette.canvas};
  font-size: 15px;
  line-height: 1.55;
}
a { color: ${palette.link}; }
img { max-width: 100%; height: auto; }
table { max-width: 100%; border-collapse: collapse; }
.nyamail-img-placeholder {
  display: inline-flex;
  align-items: center;
  min-height: 42px;
  margin: 6px 0;
  padding: 10px 12px;
  border: 1px solid ${palette.placeholderBorder};
  border-radius: 6px;
  color: ${palette.placeholderText};
  background: ${palette.placeholderBackground};
  text-decoration: none;
  font: 13px system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
}
</style>
</head>
<body>$body</body>
</html>
''';
  return MailHtmlRenderResult(
    html: html,
    textFallback: fallback,
    summary: sanitizer.summary,
    canvasColor: palette.canvasColor,
    allowedRemoteImageUrls: Set.unmodifiable(sanitizer.allowedRemoteImageUrls),
  );
}

_MailHtmlPalette _paletteFor(MailHtmlRenderPolicy policy) {
  final dark =
      policy.appearance == MailAppearance.dark ||
      (policy.appearance == MailAppearance.automatic && policy.hostIsDark);
  if (dark) {
    return _MailHtmlPalette(
      colorScheme:
          policy.appearance == MailAppearance.dark ? 'dark' : 'light dark',
      canvasColor: 0xFF111315,
      canvas: '#111315',
      text: '#E8EAED',
      link: '#8AB4F8',
      placeholderText: '#E8EAED',
      placeholderBackground: '#202124',
      placeholderBorder: '#5F6368',
    );
  }
  return _MailHtmlPalette(
    colorScheme:
        policy.appearance == MailAppearance.light ? 'light' : 'light dark',
    canvasColor: 0xFFFFFFFF,
    canvas: '#FFFFFF',
    text: '#202124',
    link: '#0B57D0',
    placeholderText: '#3C4043',
    placeholderBackground: '#F7F7F7',
    placeholderBorder: '#C7C7C7',
  );
}

class _MailHtmlPalette {
  const _MailHtmlPalette({
    required this.colorScheme,
    required this.canvasColor,
    required this.canvas,
    required this.text,
    required this.link,
    required this.placeholderText,
    required this.placeholderBackground,
    required this.placeholderBorder,
  });

  final String colorScheme;
  final int canvasColor;
  final String canvas;
  final String text;
  final String link;
  final String placeholderText;
  final String placeholderBackground;
  final String placeholderBorder;
}

String _contentSecurityPolicy(MailHtmlRenderPolicy policy) {
  final imgSrc =
      policy.loadRemoteImages || policy.allowedRemoteImageIds.isNotEmpty
          ? 'data: http: https:'
          : 'data:';
  final styleSrc =
      policy.loadExternalStylesAndFonts
          ? "'unsafe-inline' http: https:"
          : "'unsafe-inline'";
  final fontSrc =
      policy.loadExternalStylesAndFonts ? 'data: http: https:' : 'data:';
  return [
    "default-src 'none'",
    "base-uri 'none'",
    "connect-src 'none'",
    "form-action 'none'",
    "frame-src 'none'",
    "object-src 'none'",
    "script-src 'none'",
    'img-src $imgSrc',
    'style-src $styleSrc',
    'font-src $fontSrc',
  ].join('; ');
}

String _plainTextToHtml(String text) {
  final escaped = const HtmlEscape(
    HtmlEscapeMode.element,
  ).convert(text.isEmpty ? '(no body)' : text);
  return '<pre style="white-space: pre-wrap; font: inherit">$escaped</pre>';
}

bool _looksLikeHtmlDocument(String value) {
  if (value.isEmpty) return false;
  final trimmed = value.trimLeft().replaceFirst('\uFEFF', '').trimLeft();
  return _htmlDocumentStartPattern.hasMatch(trimmed) ||
      _doctypeHtmlPattern.hasMatch(trimmed) ||
      (_bodyOpenPattern.hasMatch(trimmed) &&
          _bodyClosePattern.hasMatch(trimmed));
}

String _htmlToTextFallback(String html) {
  var text = html.replaceAll(_fallbackScriptBlockPattern, '');
  text = text.replaceAll(_fallbackStyleBlockPattern, '');
  text = text.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
  text = text.replaceAll(
    RegExp(
      r'</(?:p|div|section|article|tr|table|li|h[1-6])\s*>',
      caseSensitive: false,
    ),
    '\n',
  );
  text = text.replaceAll(RegExp(r'<[^>]+>'), ' ');
  text = _decodeBasicHtmlEntities(text);
  text = text.replaceAll(RegExp(r'[ \t\f\v]+'), ' ');
  text = text.replaceAll(RegExp(r'\s*\n\s*'), '\n');
  return text.trim();
}

String _decodeBasicHtmlEntities(String value) {
  return value
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'");
}

final _htmlDocumentStartPattern = RegExp(
  r'^(?:<!doctype\s+html\b[^>]*>\s*)?<html\b',
  caseSensitive: false,
);
final _doctypeHtmlPattern = RegExp(
  r'^<!doctype\s+html\b',
  caseSensitive: false,
);
final _bodyOpenPattern = RegExp(r'<body\b', caseSensitive: false);
final _bodyClosePattern = RegExp(r'</body\s*>', caseSensitive: false);
final _fallbackScriptBlockPattern = RegExp(
  r'<script\b[^>]*>.*?</script\s*>',
  caseSensitive: false,
  dotAll: true,
);
final _fallbackStyleBlockPattern = RegExp(
  r'<style\b[^>]*>.*?</style\s*>',
  caseSensitive: false,
  dotAll: true,
);

class _MailHtmlSanitizer {
  _MailHtmlSanitizer(this.policy);

  final MailHtmlRenderPolicy policy;
  var _blockedRemoteImages = 0;
  var _blockedInlineImages = 0;
  var _blockedExternalStyles = 0;
  var _blockedExternalFonts = 0;
  var _blockedCssResources = 0;
  var _removedScripts = 0;
  var _remoteImageIndex = 0;
  final allowedRemoteImageUrls = <String>{};

  static final _scriptBlockPattern = RegExp(
    r'<script\b[^>]*>.*?</script\s*>',
    caseSensitive: false,
    dotAll: true,
  );
  static final _scriptTagPattern = RegExp(
    r'<script\b[^>]*?/?>',
    caseSensitive: false,
    dotAll: true,
  );
  static final _styleBlockPattern = RegExp(
    r'<style\b[^>]*>(.*?)</style\s*>',
    caseSensitive: false,
    dotAll: true,
  );
  static final _linkTagPattern = RegExp(
    r'<link\b[^>]*>',
    caseSensitive: false,
    dotAll: true,
  );
  static final _openingTagPattern = RegExp(
    r'<([a-zA-Z][a-zA-Z0-9:_-]*)([^<>]*)>',
    caseSensitive: false,
    dotAll: true,
  );
  static final _closingTagPattern = RegExp(
    r'</([a-zA-Z][a-zA-Z0-9:_-]*)\s*>',
    caseSensitive: false,
  );
  static final _attributePattern = RegExp(
    r'''([a-zA-Z_:][-a-zA-Z0-9_:.]*)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?''',
    dotAll: true,
  );
  static final _importPattern = RegExp(
    r'@import\b[^;]+;',
    caseSensitive: false,
    dotAll: true,
  );
  static final _fontFacePattern = RegExp(
    r'@font-face\s*\{.*?\}',
    caseSensitive: false,
    dotAll: true,
  );
  static final _cssUrlPattern = RegExp(
    r'url\(\s*([^)]+?)\s*\)',
    caseSensitive: false,
    dotAll: true,
  );
  static final _cssExpressionPattern = RegExp(
    r'expression\s*\(',
    caseSensitive: false,
  );

  static const _blockedTags = {
    'applet',
    'base',
    'body',
    'button',
    'canvas',
    'embed',
    'form',
    'frame',
    'frameset',
    'head',
    'html',
    'iframe',
    'input',
    'math',
    'meta',
    'object',
    'option',
    'script',
    'select',
    'source',
    'svg',
    'textarea',
    'track',
  };

  MailHtmlResourceSummary get summary => MailHtmlResourceSummary(
    blockedRemoteImages: _blockedRemoteImages,
    blockedInlineImages: _blockedInlineImages,
    blockedExternalStyles: _blockedExternalStyles,
    blockedExternalFonts: _blockedExternalFonts,
    blockedCssResources: _blockedCssResources,
    removedScripts: _removedScripts,
  );

  String sanitize(String html) {
    var output = html;
    output = output.replaceAllMapped(_scriptBlockPattern, (match) {
      _removedScripts++;
      return '';
    });
    output = output.replaceAllMapped(_scriptTagPattern, (match) {
      _removedScripts++;
      return '';
    });
    output = output.replaceAllMapped(_linkTagPattern, _sanitizeLinkTag);
    output = output.replaceAllMapped(_styleBlockPattern, (match) {
      final css = _sanitizeCss(match.group(1) ?? '');
      return css.trim().isEmpty ? '' : '<style>$css</style>';
    });
    output = output.replaceAllMapped(_openingTagPattern, _sanitizeOpeningTag);
    output = output.replaceAllMapped(_closingTagPattern, (match) {
      final tag = (match.group(1) ?? '').toLowerCase();
      return _blockedTags.contains(tag) ? '' : '</$tag>';
    });
    return output;
  }

  String _sanitizeLinkTag(Match match) {
    final attrs = _parseAttributes(match.group(0) ?? '');
    final rel = (attrs['rel'] ?? '').toLowerCase();
    final href = attrs['href'] ?? '';
    final isStyle =
        rel.contains('stylesheet') ||
        rel.contains('preload') ||
        rel.contains('modulepreload') ||
        _looksLikeStylesheet(href);
    final isFont = rel.contains('preload') && _looksLikeFont(href);
    if (isStyle || isFont || _isRemoteUrl(href)) {
      if (!policy.loadExternalStylesAndFonts) {
        if (isFont) {
          _blockedExternalFonts++;
        } else {
          _blockedExternalStyles++;
        }
        return '';
      }
    }
    return '<link${_sanitizeAttributes('link', attrs)}>';
  }

  String _sanitizeOpeningTag(Match match) {
    final tag = (match.group(1) ?? '').toLowerCase();
    if (_blockedTags.contains(tag)) return '';
    final attrs = _parseAttributes(match.group(2) ?? '');
    if (tag == 'img') return _sanitizeImage(attrs);
    final sanitizedAttrs = _sanitizeAttributes(tag, attrs);
    final isSelfClosing = (match.group(0) ?? '').trimRight().endsWith('/>');
    return '<$tag$sanitizedAttrs${isSelfClosing ? ' /' : ''}>';
  }

  String _sanitizeImage(Map<String, String> attrs) {
    final src = attrs['src']?.trim() ?? '';
    if (src.isEmpty) return '';
    if (_isRemoteUrl(src)) {
      final imageId = 'remote-${_remoteImageIndex++}';
      final allowed =
          policy.loadRemoteImages ||
          policy.allowedRemoteImageIds.contains(imageId);
      if (!allowed) {
        _blockedRemoteImages++;
        return _imagePlaceholder(
          'Remote image blocked. Click to load this image.',
          remoteImageId: imageId,
        );
      }
      allowedRemoteImageUrls.add(src);
      final sanitizedAttrs = _sanitizeAttributes(
        'img',
        attrs,
        allowedRemoteImageSrc: src,
      );
      return '<img$sanitizedAttrs loading="lazy" decoding="async">';
    }
    if (_isCidUrl(src)) {
      _blockedInlineImages++;
      return _imagePlaceholder('Inline image is not available yet.');
    }
    if (_isDataImageUrl(src)) {
      final sanitizedAttrs = _sanitizeAttributes('img', attrs);
      return '<img$sanitizedAttrs>';
    }
    _blockedRemoteImages++;
    return _imagePlaceholder('Image source blocked.');
  }

  String _imagePlaceholder(String label, {String? remoteImageId}) {
    final text = _escapeHtml(label);
    if (remoteImageId == null) {
      return '<span class="nyamail-img-placeholder">$text</span>';
    }
    final href = _escapeAttribute(mailLoadImageUrl(remoteImageId));
    return '<a class="nyamail-img-placeholder" href="$href">$text</a>';
  }

  String _sanitizeAttributes(
    String tag,
    Map<String, String> attrs, {
    String? allowedRemoteImageSrc,
  }) {
    final output = <String>[];
    attrs.forEach((name, value) {
      final lower = name.toLowerCase();
      if (lower.startsWith('on') || lower == 'srcdoc') return;
      if (lower == 'style') {
        final css = _sanitizeCss(value);
        if (css.trim().isEmpty) return;
        output.add(' $lower="${_escapeAttribute(css)}"');
        return;
      }
      if (lower == 'href') {
        final sanitized = _sanitizeHref(value);
        if (sanitized == null) return;
        output.add(' href="${_escapeAttribute(sanitized)}"');
        if (tag == 'a') {
          output.add(' target="_blank" rel="noopener noreferrer"');
        }
        return;
      }
      if (lower == 'src' || lower == 'background' || lower == 'poster') {
        final sanitized = _sanitizeResourceUrl(
          value,
          lower,
          allowedRemoteImageSrc: allowedRemoteImageSrc,
        );
        if (sanitized == null) return;
        output.add(' $lower="${_escapeAttribute(sanitized)}"');
        return;
      }
      if (_isDangerousUrlValue(value)) return;
      output.add(' $lower="${_escapeAttribute(value)}"');
    });
    return output.join();
  }

  String? _sanitizeHref(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    final uri = Uri.tryParse(trimmed);
    final scheme = uri?.scheme.toLowerCase() ?? '';
    if (scheme.isEmpty ||
        scheme == 'http' ||
        scheme == 'https' ||
        scheme == 'mailto' ||
        scheme == 'tel') {
      return trimmed;
    }
    return null;
  }

  String? _sanitizeResourceUrl(
    String value,
    String attribute, {
    String? allowedRemoteImageSrc,
  }) {
    final trimmed = value.trim();
    if (trimmed.isEmpty || _isDangerousUrlValue(trimmed)) return null;
    if (_isRemoteUrl(trimmed)) {
      if (attribute == 'src' &&
          (policy.loadRemoteImages || trimmed == allowedRemoteImageSrc)) {
        return trimmed;
      }
      if (policy.loadExternalStylesAndFonts) return trimmed;
      _blockedCssResources++;
      return null;
    }
    if (_isDataImageUrl(trimmed)) return trimmed;
    if (_isCidUrl(trimmed)) return null;
    return null;
  }

  String _sanitizeCss(String css) {
    var output = css.replaceAll(_cssExpressionPattern, '');
    output = output.replaceAllMapped(_importPattern, (match) {
      if (!policy.loadExternalStylesAndFonts) {
        _blockedExternalStyles++;
        return '';
      }
      return _isDangerousUrlValue(match.group(0) ?? '') ? '' : match.group(0)!;
    });
    output = output.replaceAllMapped(_fontFacePattern, (match) {
      if (!policy.loadExternalStylesAndFonts) {
        _blockedExternalFonts++;
        return '';
      }
      return _sanitizeCssUrls(match.group(0) ?? '');
    });
    return _sanitizeCssUrls(output);
  }

  String _sanitizeCssUrls(String css) {
    return css.replaceAllMapped(_cssUrlPattern, (match) {
      final raw = (match.group(1) ?? '').trim();
      final value = _unquoteCssUrl(raw);
      if (_isDangerousUrlValue(value)) return 'none';
      if (_isRemoteUrl(value) && !policy.loadExternalStylesAndFonts) {
        _blockedCssResources++;
        return 'none';
      }
      if (_isCidUrl(value)) return 'none';
      return 'url("${_escapeCssUrl(value)}")';
    });
  }

  Map<String, String> _parseAttributes(String raw) {
    final attrs = <String, String>{};
    for (final match in _attributePattern.allMatches(raw)) {
      final name = match.group(1);
      if (name == null || name.startsWith('<')) continue;
      final value = match.group(2) ?? match.group(3) ?? match.group(4) ?? '';
      attrs[name.toLowerCase()] = value;
    }
    return attrs;
  }

  bool _looksLikeStylesheet(String value) {
    final path =
        Uri.tryParse(value.trim())?.path.toLowerCase() ?? value.toLowerCase();
    return path.endsWith('.css');
  }

  bool _looksLikeFont(String value) {
    final path =
        Uri.tryParse(value.trim())?.path.toLowerCase() ?? value.toLowerCase();
    return path.endsWith('.woff') ||
        path.endsWith('.woff2') ||
        path.endsWith('.ttf') ||
        path.endsWith('.otf') ||
        path.endsWith('.eot');
  }

  bool _isRemoteUrl(String value) {
    final scheme = Uri.tryParse(value.trim())?.scheme.toLowerCase();
    return scheme == 'http' || scheme == 'https';
  }

  bool _isCidUrl(String value) =>
      Uri.tryParse(value.trim())?.scheme.toLowerCase() == 'cid';

  bool _isDataImageUrl(String value) {
    final trimmed = value.trim().toLowerCase();
    return trimmed.startsWith('data:image/');
  }

  bool _isDangerousUrlValue(String value) {
    final compact = value.trim().replaceAll(RegExp(r'\s+'), '').toLowerCase();
    return compact.startsWith('javascript:') || compact.startsWith('vbscript:');
  }

  String _unquoteCssUrl(String value) {
    if ((value.startsWith('"') && value.endsWith('"')) ||
        (value.startsWith("'") && value.endsWith("'"))) {
      return value.substring(1, value.length - 1);
    }
    return value;
  }

  String _escapeCssUrl(String value) =>
      value.replaceAll('\\', r'\\').replaceAll('"', r'\"');

  String _escapeHtml(String value) =>
      const HtmlEscape(HtmlEscapeMode.element).convert(value);

  String _escapeAttribute(String value) =>
      const HtmlEscape(HtmlEscapeMode.attribute).convert(value);
}
