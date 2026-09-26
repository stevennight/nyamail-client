import 'package:flutter_test/flutter_test.dart';
import 'package:nyamail/src/mail/imap_body_structure.dart';

void main() {
  test('parses multipart/mixed with alternative text and an attachment', () {
    final part =
        parseBodyStructureFromFetch(
          '* 12 FETCH (UID 501 RFC822.SIZE 3000000 BODYSTRUCTURE '
          '((("TEXT" "PLAIN" ("CHARSET" "UTF-8") NIL NIL "QUOTED-PRINTABLE" 120 4 '
          'NIL NIL NIL)("TEXT" "HTML" ("CHARSET" "UTF-8") NIL NIL "BASE64" 400 6 '
          'NIL NIL NIL) "ALTERNATIVE" ("BOUNDARY" "b2") NIL NIL)'
          '("APPLICATION" "PDF" ("NAME" "report.pdf") NIL NIL "BASE64" 2999000 '
          'NIL ("ATTACHMENT" ("FILENAME" "report.pdf")) NIL) '
          '"MIXED" ("BOUNDARY" "b1") NIL NIL))',
        )!;

    expect(part.isMultipart, isTrue);
    expect(part.subtype, 'mixed');
    final leaves = part.leaves.toList();
    expect(leaves.map((leaf) => leaf.partId), ['1.1', '1.2', '2']);
    expect(leaves.where((leaf) => leaf.isText).map((leaf) => leaf.mimeType), [
      'text/plain',
      'text/html',
    ]);
    final attachment = leaves.last;
    expect(attachment.isAttachment, isTrue);
    expect(attachment.filename, 'report.pdf');
    expect(attachment.encoding, 'base64');
    expect(attachment.decodedSize, closeTo(2999000 * 57 / 78, 1));
  });

  test('numbers a single-part message as section 1', () {
    final part =
        parseImapBodyStructure(
          '("TEXT" "PLAIN" ("CHARSET" "US-ASCII") NIL NIL "7BIT" 25 1)',
        )!;

    expect(part.isMultipart, isFalse);
    expect(part.partId, '1');
    expect(part.isText, isTrue);
  });

  test('skips envelope and nested body of message/rfc822 parts', () {
    final part =
        parseImapBodyStructure(
          '(("TEXT" "PLAIN" NIL NIL NIL "7BIT" 10 1)'
          '("MESSAGE" "RFC822" NIL NIL NIL "7BIT" 500 '
          '("Mon, 1 Jul 2026 08:00:00 +0000" "Fwd" NIL NIL NIL NIL NIL NIL NIL '
          '"<id@example.com>") ("TEXT" "PLAIN" NIL NIL NIL "7BIT" 20 2) 12 NIL '
          '("INLINE" NIL) NIL) "MIXED")',
        )!;

    final forwarded = part.children.last;
    expect(forwarded.partId, '2');
    expect(forwarded.mimeType, 'message/rfc822');
    expect(forwarded.disposition, 'inline');
    expect(forwarded.children, isEmpty);
  });

  test('decodes RFC 2231 filenames and inline literals', () {
    final part =
        parseImapBodyStructure(
          '(("TEXT" "PLAIN" NIL NIL NIL "7BIT" 10 1)'
          '("IMAGE" "PNG" NIL NIL NIL "BASE64" 100 NIL '
          '("ATTACHMENT" ("FILENAME*" "utf-8\'\'%E6%8A%A5%E5%91%8A.png")) NIL)'
          '("APPLICATION" "ZIP" ("NAME" {9}\r\nfiles.zip) NIL NIL "BASE64" 10 NIL '
          'NIL NIL) "MIXED")',
        )!;

    expect(part.children[1].filename, '报告.png');
    expect(part.children[1].isAttachment, isTrue);
    expect(part.children[2].filename, 'files.zip');
    expect(part.children[2].isAttachment, isTrue);
  });

  test('returns null for malformed structures', () {
    expect(parseImapBodyStructure('("TEXT" "PLAIN"'), isNull);
    expect(parseBodyStructureFromFetch('* 1 FETCH (UID 5)'), isNull);
  });
}
