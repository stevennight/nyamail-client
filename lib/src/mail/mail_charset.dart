import 'dart:convert';

import 'package:charset/charset.dart';

/// Decodes message text bytes using the MIME `charset` parameter.
///
/// Raw messages are handled as latin1 "binary strings" (one char per byte)
/// until a text part is decoded here, so bodies in GBK, Shift_JIS, Windows
/// code pages and so on are no longer forced through UTF-8.
String decodeMailText(List<int> bytes, String? charset) {
  final name = (charset ?? '').trim().replaceAll('"', '').toLowerCase();
  switch (name) {
    case '':
    case 'utf-8':
    case 'utf8':
    case 'us-ascii':
    case 'ascii':
      return utf8.decode(bytes, allowMalformed: true);
    case 'iso-8859-1':
    case 'latin1':
    case 'latin-1':
      return latin1.decode(bytes);
  }
  if (_isGbkFamily(name)) {
    return gbk.decode(bytes, allowMalformed: true);
  }
  final encoding = Charset.getByName(name);
  if (encoding != null) {
    try {
      return encoding.decode(bytes);
    } catch (_) {
      // Fall through to the lenient default below.
    }
  }
  return utf8.decode(bytes, allowMalformed: true);
}

/// Header values without an RFC 2047 charset: accept raw UTF-8 (common) and
/// fall back to GBK, which Chinese mailers still send unencoded.
String decodeRawHeaderText(String value) {
  final bytes = binaryStringBytes(value);
  if (bytes == null || bytes.every((byte) => byte < 0x80)) return value;
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return gbk.decode(bytes, allowMalformed: true);
  }
}

/// The bytes behind a latin1 binary string, or null when [value] already
/// holds decoded text (any code unit above 0xFF).
List<int>? binaryStringBytes(String value) {
  final units = value.codeUnits;
  for (final unit in units) {
    if (unit > 0xFF) return null;
  }
  return units;
}

bool _isGbkFamily(String name) {
  return name == 'gbk' ||
      name == 'gb2312' ||
      name == 'gb_2312' ||
      name == 'gb-2312' ||
      name == 'gb18030' ||
      name == 'cp936' ||
      name == 'ms936' ||
      name == 'windows-936' ||
      name == 'x-gbk' ||
      name == 'euc-cn' ||
      name == 'csgb2312';
}
