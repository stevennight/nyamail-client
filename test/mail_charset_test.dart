import 'dart:convert';

import 'package:charset/charset.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nyamail/src/mail/mail_transport.dart';

/// Raw messages reach the parser as latin1 binary strings of the IMAP bytes.
String rawMessage(List<List<int>> parts) =>
    latin1.decode([for (final part in parts) ...part]);

List<int> ascii7(String value) => ascii.encode(value);

void main() {
  test('decodes an 8bit GBK body', () {
    final message = parseRfc822Message(
      rawMessage([
        ascii7(
          'Subject: =?GBK?B?${base64Encode(gbk.encode('会议通知'))}?=\r\n'
          'Content-Type: text/plain; charset="gb2312"\r\n'
          'Content-Transfer-Encoding: 8bit\r\n\r\n',
        ),
        gbk.encode('明天上午十点开会。'),
      ]),
      id: 'acc:inbox:1',
      accountId: 'acc',
    );

    expect(message.subject, '会议通知');
    expect(message.body, '明天上午十点开会。');
  });

  test('decodes base64 and quoted-printable GBK parts', () {
    final html = gbk.encode('<p>你好，世界</p>');
    final qp =
        [
          for (final byte in gbk.encode('纯文本'))
            '=${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}',
        ].join();
    final message = parseRfc822Message(
      rawMessage([
        ascii7(
          'Subject: Test\r\n'
          'Content-Type: multipart/alternative; boundary="b"\r\n\r\n'
          '--b\r\n'
          'Content-Type: text/plain; charset=GBK\r\n'
          'Content-Transfer-Encoding: quoted-printable\r\n\r\n'
          '$qp\r\n'
          '--b\r\n'
          'Content-Type: text/html; charset=GB18030\r\n'
          'Content-Transfer-Encoding: base64\r\n\r\n'
          '${base64Encode(html)}\r\n'
          '--b--\r\n',
        ),
      ]),
      id: 'acc:inbox:2',
      accountId: 'acc',
    );

    expect(message.body, '纯文本');
    expect(message.htmlBody, '<p>你好，世界</p>');
  });

  test('keeps UTF-8 bodies and raw UTF-8 headers working', () {
    final message = parseRfc822Message(
      rawMessage([
        ascii7('Subject: '),
        utf8.encode('直接的主题'),
        ascii7('\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n'),
        utf8.encode('正文 ✓'),
      ]),
      id: 'acc:inbox:3',
      accountId: 'acc',
    );

    expect(message.subject, '直接的主题');
    expect(message.body, '正文 ✓');
  });

  test('falls back to GBK for unencoded non-UTF-8 headers', () {
    final message = parseRfc822Message(
      rawMessage([
        ascii7('From: '),
        gbk.encode('张三'),
        ascii7(' <zhang@example.com>\r\nSubject: hi\r\n\r\nbody'),
      ]),
      id: 'acc:inbox:4',
      accountId: 'acc',
    );

    expect(message.from, '张三 <zhang@example.com>');
  });

  test('decodes Windows code pages', () {
    final message = parseRfc822Message(
      rawMessage([
        ascii7(
          'Subject: x\r\n'
          'Content-Type: text/plain; charset=windows-1251\r\n\r\n',
        ),
        [0xCF, 0xF0, 0xE8, 0xE2, 0xE5, 0xF2],
      ]),
      id: 'acc:inbox:5',
      accountId: 'acc',
    );

    expect(message.body, 'Привет');
  });
}
