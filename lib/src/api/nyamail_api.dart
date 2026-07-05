import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';

class NyaMailApi {
  NyaMailApi({required String baseUrl, http.Client? client})
    : _baseUri = Uri.parse(baseUrl),
      _client = client ?? http.Client();

  final Uri _baseUri;
  final http.Client _client;

  Future<AuthSession> register({
    required String email,
    required String password,
    required String displayName,
    required DeviceInfoPayload device,
    EncryptedBlob? initialVault,
  }) async {
    final response = await _post('/v1/auth/register', {
      'email': email,
      'password': password,
      'display_name': displayName,
      'device': device.toJson(),
      if (initialVault != null) 'vault': initialVault.toJson(),
    });
    return AuthSession.fromJson(response);
  }

  Future<AuthSession> login({
    required String email,
    required String password,
    required DeviceInfoPayload device,
  }) async {
    final response = await _post('/v1/auth/login', {
      'email': email,
      'password': password,
      'device': device.toJson(),
    });
    return AuthSession.fromJson(response);
  }

  Future<List<DeviceSummary>> listDevices(String token) async {
    final response = await _get('/v1/devices', token: token);
    return (response as List)
        .map(
          (item) =>
              DeviceSummary.fromJson((item as Map).cast<String, Object?>()),
        )
        .toList();
  }

  Future<void> revokeDevice({
    required String token,
    required String deviceId,
  }) async {
    await _post('/v1/devices/$deviceId/revoke', const {}, token: token);
  }

  Future<VaultSnapshot?> getVault(String token) async {
    try {
      final response = await _get('/v1/vault', token: token);
      return VaultSnapshot.fromJson((response as Map).cast<String, Object?>());
    } on NyaMailApiException catch (error) {
      if (error.statusCode == 404) return null;
      rethrow;
    }
  }

  Future<VaultShare> putVaultShare({
    required String token,
    required String deviceId,
    required String senderPublicKey,
    required String algorithm,
    required String nonce,
    required String ciphertext,
    required String mac,
    required String pairingCode,
    required String approvalSignature,
  }) async {
    final response = await _put('/v1/devices/$deviceId/vault-share', {
      'sender_public_key': senderPublicKey,
      'algorithm': algorithm,
      'nonce': nonce,
      'ciphertext': ciphertext,
      'mac': mac,
      'pairing_code': pairingCode,
      'approval_signature': approvalSignature,
    }, token: token);
    return VaultShare.fromJson(response);
  }

  Future<VaultShare?> getVaultShare(String token) async {
    try {
      final response = await _get('/v1/vault-share', token: token);
      return VaultShare.fromJson((response as Map).cast<String, Object?>());
    } on NyaMailApiException catch (error) {
      if (error.statusCode == 404) return null;
      rethrow;
    }
  }

  Future<void> consumeVaultShare({
    required String token,
    required String shareId,
  }) async {
    await _post('/v1/vault-share/$shareId/consume', const {}, token: token);
  }

  Future<SyncPushResult> pushSyncRecords({
    required String token,
    required List<SyncRecord> records,
  }) async {
    final response = await _post('/v1/sync/push', {
      'records': records.map((record) => record.toJson()).toList(),
    }, token: token);
    return SyncPushResult.fromJson(response);
  }

  Future<SyncPullResult> pullSyncRecords({
    required String token,
    int after = 0,
    int limit = 500,
  }) async {
    final uri = _resolve('/v1/sync/pull').replace(
      queryParameters: {'after': after.toString(), 'limit': limit.toString()},
    );
    final response = await _client.get(uri, headers: _headers(token));
    return SyncPullResult.fromJson(_decode(response));
  }

  Future<void> leaveSyncDevice({required String token}) async {
    await _post('/v1/sync/device/leave', const {}, token: token);
  }

  Future<ReleaseCheckResult> checkRelease({
    required String platform,
    required String channel,
    required int build,
    String arch = '',
  }) async {
    final uri = _resolve('/v1/release/latest').replace(
      queryParameters: {
        'platform': platform,
        'channel': channel,
        'build': build.toString(),
        if (arch.isNotEmpty) 'arch': arch,
      },
    );
    final response = await _client.get(uri);
    return ReleaseCheckResult.fromJson(_decode(response));
  }

  Future<dynamic> _get(String path, {String? token}) async {
    final response = await _client.get(
      _resolve(path),
      headers: _headers(token),
    );
    return _decode(response);
  }

  Future<Map<String, Object?>> _post(
    String path,
    Map<String, Object?> body, {
    String? token,
  }) async {
    final response = await _client.post(
      _resolve(path),
      headers: _headers(token),
      body: jsonEncode(body),
    );
    final decoded = _decode(response);
    if (decoded == null) return <String, Object?>{};
    return (decoded as Map).cast<String, Object?>();
  }

  Future<Map<String, Object?>> _put(
    String path,
    Map<String, Object?> body, {
    String? token,
  }) async {
    final response = await _client.put(
      _resolve(path),
      headers: _headers(token),
      body: jsonEncode(body),
    );
    return _decode(response) as Map<String, Object?>;
  }

  Uri _resolve(String path) {
    final normalized = path.startsWith('/') ? path.substring(1) : path;
    return _baseUri.replace(
      path: '${_baseUri.path}/$normalized'.replaceAll('//', '/'),
    );
  }

  Map<String, String> _headers(String? token) => {
    'content-type': 'application/json; charset=utf-8',
    if (token != null) 'authorization': 'Bearer $token',
  };

  dynamic _decode(http.Response response) {
    final data = response.body.isEmpty ? null : jsonDecode(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final message = data is Map ? data['error']?.toString() : null;
      throw NyaMailApiException(
        response.statusCode,
        message ?? 'Request failed',
      );
    }
    return data;
  }
}

class NyaMailApiException implements Exception {
  const NyaMailApiException(this.statusCode, this.message);

  final int statusCode;
  final String message;

  @override
  String toString() => 'NyaMailApiException($statusCode): $message';
}
