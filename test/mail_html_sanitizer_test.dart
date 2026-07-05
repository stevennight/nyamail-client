import 'package:flutter_test/flutter_test.dart';
import 'package:nyamail/src/mail/mail_appearance.dart';
import 'package:nyamail/src/mail/mail_html_sanitizer.dart';

void main() {
  test('mail html sanitizer removes scripts and event handlers', () {
    final rendered = buildMailHtmlDocument(
      htmlBody:
          [
            '<div onclick="alert(1)">Hello</div>',
            '<script>alert(1)</script>',
            '<a href="javascript:alert(1)">Bad</a>',
          ].join(),
      textBody: 'Hello',
      policy: const MailHtmlRenderPolicy(
        loadRemoteImages: false,
        loadExternalStylesAndFonts: false,
      ),
    );

    expect(rendered.html, isNot(contains('<script')));
    expect(rendered.html, isNot(contains('onclick')));
    expect(rendered.html, isNot(contains('javascript:')));
    expect(rendered.summary.removedScripts, 1);
  });

  test('mail html sanitizer replaces remote images with placeholders', () {
    final blocked = buildMailHtmlDocument(
      htmlBody: '<img src="https://tracker.example/open.png" alt="open">',
      textBody: '',
      policy: const MailHtmlRenderPolicy(
        loadRemoteImages: false,
        loadExternalStylesAndFonts: false,
      ),
    );
    final allowed = buildMailHtmlDocument(
      htmlBody: '<img src="https://cdn.example/image.png">',
      textBody: '',
      policy: const MailHtmlRenderPolicy(
        loadRemoteImages: true,
        loadExternalStylesAndFonts: false,
      ),
    );

    expect(blocked.html, contains(mailLoadImageUrl('remote-0')));
    expect(blocked.html, isNot(contains('tracker.example/open.png')));
    expect(blocked.summary.blockedRemoteImages, 1);
    expect(allowed.html, contains('https://cdn.example/image.png'));
    expect(allowed.summary.blockedRemoteImages, 0);
  });

  test('mail html sanitizer can allow one remote image placeholder', () {
    final blocked = buildMailHtmlDocument(
      htmlBody:
          [
            '<img src="https://cdn.example/first.png">',
            '<img src="https://cdn.example/second.png">',
          ].join(),
      textBody: '',
      policy: const MailHtmlRenderPolicy(
        loadRemoteImages: false,
        loadExternalStylesAndFonts: false,
      ),
    );
    final singleAllowed = buildMailHtmlDocument(
      htmlBody:
          [
            '<img src="https://cdn.example/first.png">',
            '<img src="https://cdn.example/second.png">',
          ].join(),
      textBody: '',
      policy: const MailHtmlRenderPolicy(
        loadRemoteImages: false,
        loadExternalStylesAndFonts: false,
        allowedRemoteImageIds: {'remote-1'},
      ),
    );

    expect(blocked.html, contains(mailLoadImageUrl('remote-0')));
    expect(blocked.html, contains(mailLoadImageUrl('remote-1')));
    expect(blocked.html, isNot(contains('https://cdn.example/first.png')));
    expect(blocked.html, isNot(contains('https://cdn.example/second.png')));
    expect(blocked.summary.blockedRemoteImages, 2);

    expect(singleAllowed.html, contains(mailLoadImageUrl('remote-0')));
    expect(singleAllowed.html, isNot(contains(mailLoadImageUrl('remote-1'))));
    expect(
      singleAllowed.html,
      isNot(contains('https://cdn.example/first.png')),
    );
    expect(singleAllowed.html, contains('https://cdn.example/second.png'));
    expect(singleAllowed.summary.blockedRemoteImages, 1);
    expect(singleAllowed.allowedRemoteImageUrls, {
      'https://cdn.example/second.png',
    });
  });

  test('mail html sanitizer blocks external css and fonts by default', () {
    final blocked = buildMailHtmlDocument(
      htmlBody:
          [
            '<link rel="stylesheet" href="https://cdn.example/mail.css">',
            '<style>',
            '@import url("https://cdn.example/theme.css");',
            '@font-face { font-family: X; src: url("https://cdn.example/x.woff2"); }',
            '.hero { background: url("https://cdn.example/bg.png"); }',
            '</style>',
          ].join(),
      textBody: '',
      policy: const MailHtmlRenderPolicy(
        loadRemoteImages: false,
        loadExternalStylesAndFonts: false,
      ),
    );

    expect(blocked.html, isNot(contains('cdn.example/mail.css')));
    expect(blocked.html, isNot(contains('@font-face')));
    expect(blocked.html, isNot(contains('https://cdn.example/bg.png')));
    expect(blocked.summary.blockedExternalStyles, 2);
    expect(blocked.summary.blockedExternalFonts, 1);
    expect(blocked.summary.blockedCssResources, 1);
    expect(blocked.summary.hasBlockedExternalNonImageResources, isTrue);
  });

  test('mail html sanitizer can allow external css and fonts for one render', () {
    final rendered = buildMailHtmlDocument(
      htmlBody:
          [
            '<link rel="stylesheet" href="https://cdn.example/mail.css">',
            '<style>',
            '@import url("https://cdn.example/theme.css");',
            '@font-face { font-family: X; src: url("https://cdn.example/x.woff2"); }',
            '</style>',
          ].join(),
      textBody: '',
      policy: const MailHtmlRenderPolicy(
        loadRemoteImages: false,
        loadExternalStylesAndFonts: true,
      ),
    );

    expect(rendered.html, contains('https://cdn.example/mail.css'));
    expect(rendered.html, contains('@font-face'));
    expect(rendered.summary.hasBlockedExternalNonImageResources, isFalse);
  });

  test(
    'mail html renderer falls back to html when text body is a document',
    () {
      final rendered = buildMailHtmlDocument(
        htmlBody: '',
        textBody:
            '<html><body><h1>Hello</h1><script>alert(1)</script></body></html>',
        policy: const MailHtmlRenderPolicy(
          loadRemoteImages: false,
          loadExternalStylesAndFonts: false,
        ),
      );

      expect(rendered.html, contains('<h1>Hello</h1>'));
      expect(rendered.html, isNot(contains('&lt;html&gt;')));
      expect(rendered.html, isNot(contains('<script')));
      expect(rendered.summary.removedScripts, 1);
    },
  );

  test('mail html renderer keeps ordinary html-looking text escaped', () {
    final rendered = buildMailHtmlDocument(
      htmlBody: '',
      textBody: '<div>Use this snippet literally</div>',
      policy: const MailHtmlRenderPolicy(
        loadRemoteImages: false,
        loadExternalStylesAndFonts: false,
      ),
    );

    expect(rendered.html, contains('&lt;div&gt;Use this snippet literally'));
    expect(rendered.html, isNot(contains('<div>Use this snippet literally')));
  });

  test('mail html renderer uses dark fallback canvas in auto dark mode', () {
    final rendered = buildMailHtmlDocument(
      htmlBody: '<p>Hello</p>',
      textBody: 'Hello',
      policy: const MailHtmlRenderPolicy(
        loadRemoteImages: false,
        loadExternalStylesAndFonts: false,
        appearance: MailAppearance.automatic,
        hostIsDark: true,
      ),
    );

    expect(rendered.canvasColor, 0xFF111315);
    expect(rendered.html, contains('background: #111315'));
    expect(rendered.html, contains('color: #E8EAED'));
    expect(rendered.html, contains('color-scheme: light dark'));
  });

  test('mail html renderer can force light canvas on dark hosts', () {
    final rendered = buildMailHtmlDocument(
      htmlBody: '<p>Hello</p>',
      textBody: 'Hello',
      policy: const MailHtmlRenderPolicy(
        loadRemoteImages: false,
        loadExternalStylesAndFonts: false,
        appearance: MailAppearance.light,
        hostIsDark: true,
      ),
    );

    expect(rendered.canvasColor, 0xFFFFFFFF);
    expect(rendered.html, contains('background: #FFFFFF'));
    expect(rendered.html, contains('color: #202124'));
    expect(rendered.html, contains('color-scheme: light'));
  });
}
