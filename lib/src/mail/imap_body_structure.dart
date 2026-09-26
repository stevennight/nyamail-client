/// Parser for the IMAP `BODYSTRUCTURE` fetch item (RFC 3501 section 7.4.2).
///
/// Opening a message used to download the whole raw message, attachments
/// included. With the structure known up front, only the text parts are
/// fetched and attachments are listed from metadata and downloaded on demand.
library;

class ImapBodyPart {
  const ImapBodyPart({
    required this.partId,
    required this.type,
    required this.subtype,
    this.params = const {},
    this.encoding = '',
    this.size = 0,
    this.disposition = '',
    this.dispositionParams = const {},
    this.children = const [],
  });

  /// IMAP section number ("1", "2.1", ...). Empty for a multipart root.
  final String partId;

  /// Lower-case media type and subtype, e.g. `text` / `plain`.
  final String type;
  final String subtype;

  /// Content-Type parameters with lower-case keys.
  final Map<String, String> params;

  /// Lower-case Content-Transfer-Encoding.
  final String encoding;

  /// Encoded size in octets as reported by the server.
  final int size;

  /// Lower-case Content-Disposition value, or empty.
  final String disposition;
  final Map<String, String> dispositionParams;
  final List<ImapBodyPart> children;

  bool get isMultipart => type == 'multipart';

  String get mimeType => '$type/$subtype';

  String get filename =>
      dispositionParams['filename'] ??
      _rfc2231Value(dispositionParams['filename*']) ??
      params['name'] ??
      _rfc2231Value(params['name*']) ??
      '';

  /// Mirrors the attachment rule of the raw MIME parser: an explicit
  /// attachment, or any named part that is not marked inline.
  bool get isAttachment =>
      disposition == 'attachment' ||
      (filename.isNotEmpty && disposition != 'inline');

  bool get isText =>
      !isMultipart &&
      !isAttachment &&
      type == 'text' &&
      (subtype == 'plain' || subtype == 'html');

  /// Approximate decoded size, used for attachment size labels.
  int get decodedSize {
    if (encoding == 'base64') {
      // 76 characters per line plus CRLF encode 57 bytes.
      return (size * 57 / 78).round();
    }
    return size;
  }

  Iterable<ImapBodyPart> get leaves sync* {
    if (!isMultipart) {
      yield this;
      return;
    }
    for (final child in children) {
      yield* child.leaves;
    }
  }
}

/// Parses the parenthesised value of a BODYSTRUCTURE item (starting at its
/// opening parenthesis). Returns null when the text is not a structure this
/// parser understands, so callers can fall back to fetching the raw message.
ImapBodyPart? parseImapBodyStructure(String text) {
  try {
    final tokens = _ImapListParser(text).parse();
    if (tokens is! List) return null;
    return _partFromList(tokens, '', isRoot: true);
  } on FormatException {
    return null;
  } on RangeError {
    return null;
  } on TypeError {
    return null;
  }
}

/// Finds the BODYSTRUCTURE value inside a FETCH response line and parses it.
ImapBodyPart? parseBodyStructureFromFetch(String fetchLine) {
  final match = RegExp(
    r'\bBODYSTRUCTURE\s+\(',
    caseSensitive: false,
  ).firstMatch(fetchLine);
  if (match == null) return null;
  return parseImapBodyStructure(fetchLine.substring(match.end - 1));
}

ImapBodyPart _partFromList(
  List<Object?> list,
  String partId, {
  bool isRoot = false,
}) {
  if (list.isNotEmpty && list.first is List) {
    final children = <ImapBodyPart>[];
    var index = 0;
    while (index < list.length && list[index] is List) {
      final childId = partId.isEmpty ? '${index + 1}' : '$partId.${index + 1}';
      children.add(_partFromList(list[index] as List<Object?>, childId));
      index++;
    }
    final subtype = _string(list, index).toLowerCase();
    final params = _params(list, index + 1);
    final disposition = _disposition(list, index + 2);
    return ImapBodyPart(
      partId: partId,
      type: 'multipart',
      subtype: subtype,
      params: params,
      disposition: disposition.$1,
      dispositionParams: disposition.$2,
      children: children,
    );
  }

  final type = _string(list, 0).toLowerCase();
  final subtype = _string(list, 1).toLowerCase();
  // A non-multipart message body is section 1.
  final id = isRoot ? '1' : partId;
  var extensionStart = 7;
  if (type == 'text') {
    extensionStart = 8; // body-fld-lines
  } else if (type == 'message' && subtype == 'rfc822') {
    extensionStart = 10; // envelope, body, body-fld-lines
  }
  // Extension data: body-fld-md5, then body-fld-dsp.
  final disposition = _disposition(list, extensionStart + 1);
  return ImapBodyPart(
    partId: id,
    type: type,
    subtype: subtype,
    params: _params(list, 2),
    encoding: _string(list, 5).toLowerCase(),
    size: int.tryParse(_string(list, 6)) ?? 0,
    disposition: disposition.$1,
    dispositionParams: disposition.$2,
  );
}

/// Decodes an RFC 2231 extended parameter (`utf-8''n%C3%A4me.pdf`).
String? _rfc2231Value(String? raw) {
  if (raw == null) return null;
  final parts = raw.split("'");
  final encoded = parts.length >= 3 ? parts.sublist(2).join("'") : raw;
  try {
    return Uri.decodeComponent(encoded);
  } catch (_) {
    // Invalid percent or UTF-8 sequences: keep the raw text.
    return encoded;
  }
}

String _string(List<Object?> list, int index) {
  if (index >= list.length) return '';
  final value = list[index];
  return value is String ? value : '';
}

Map<String, String> _params(List<Object?> list, int index) {
  if (index >= list.length) return const {};
  final value = list[index];
  if (value is! List) return const {};
  final params = <String, String>{};
  for (var i = 0; i + 1 < value.length; i += 2) {
    final key = value[i];
    final paramValue = value[i + 1];
    if (key is String && paramValue is String) {
      params[key.toLowerCase()] = paramValue;
    }
  }
  return params;
}

(String, Map<String, String>) _disposition(List<Object?> list, int index) {
  if (index >= list.length) return ('', const {});
  final value = list[index];
  if (value is! List || value.isEmpty || value.first is! String) {
    return ('', const {});
  }
  return ((value.first as String).toLowerCase(), _params(value, 1));
}

/// Tokenises an IMAP parenthesised list into nested Dart lists. Atoms and
/// quoted strings become [String]s, `NIL` becomes null.
class _ImapListParser {
  _ImapListParser(this._text);

  final String _text;
  int _index = 0;

  Object? parse() {
    _skipSpaces();
    return _value();
  }

  Object? _value() {
    _skipSpaces();
    if (_index >= _text.length) {
      throw const FormatException('Unexpected end of IMAP list');
    }
    final char = _text[_index];
    if (char == '(') return _list();
    if (char == '"') return _quoted();
    if (char == '{') return _literal();
    return _atom();
  }

  List<Object?> _list() {
    _index++; // (
    final values = <Object?>[];
    while (true) {
      _skipSpaces();
      if (_index >= _text.length) {
        throw const FormatException('Unterminated IMAP list');
      }
      if (_text[_index] == ')') {
        _index++;
        return values;
      }
      values.add(_value());
    }
  }

  String _quoted() {
    _index++; // opening quote
    final buffer = StringBuffer();
    while (_index < _text.length) {
      final char = _text[_index++];
      if (char == r'\' && _index < _text.length) {
        buffer.write(_text[_index++]);
      } else if (char == '"') {
        return buffer.toString();
      } else {
        buffer.write(char);
      }
    }
    throw const FormatException('Unterminated IMAP string');
  }

  String _literal() {
    final close = _text.indexOf('}', _index);
    if (close < 0) throw const FormatException('Bad IMAP literal');
    final length = int.parse(_text.substring(_index + 1, close));
    var start = close + 1;
    if (_text.startsWith('\r\n', start)) {
      start += 2;
    } else if (_text.startsWith('\n', start)) {
      start += 1;
    }
    _index = start + length;
    return _text.substring(start, _index);
  }

  String? _atom() {
    final start = _index;
    while (_index < _text.length) {
      final char = _text[_index];
      if (char == ' ' || char == '(' || char == ')') break;
      _index++;
    }
    final atom = _text.substring(start, _index);
    if (atom.isEmpty) throw const FormatException('Empty IMAP atom');
    return atom.toUpperCase() == 'NIL' ? null : atom;
  }

  void _skipSpaces() {
    while (_index < _text.length &&
        (_text[_index] == ' ' ||
            _text[_index] == '\r' ||
            _text[_index] == '\n')) {
      _index++;
    }
  }
}
