/// Device storage service for managing device identity and paired clients.
/// Handles device ID generation, Ed25519 keypair management, and server URL storage.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/paired_client.dart';
import 'log_service.dart';

export '../models/paired_client.dart';

class DeviceStorage {
  static final DeviceStorage shared = DeviceStorage._();
  DeviceStorage._();

  SharedPreferences? _prefs;
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();
  String? _deviceId;
  Uint8List? _privateKey;

  // Keys for SharedPreferences (non-sensitive data)
  static const _deviceIdKey = 'device_id';
  static const _publicKeyKey = 'public_key';
  static const _serverUrlKey = 'server_url';
  static const _pairedClientsKey = 'paired_clients';
  static const _streamQualityKey = 'stream_quality'; // 1.0 = sharp, 2.0 = responsive
  static const _apnsTokensKey = 'apns_tokens'; // deviceId -> APNs token
  static const _lastConnectedClientKey = 'last_connected_client';
  static const _lastConnectedAtKey = 'last_connected_at'; // ISO-8601 timestamp

  // Keys for secure storage (sensitive data — stored in macOS Keychain)
  static const _securePrivateKeyKey = 'ed25519_private_key';

  // Legacy key for migration from SharedPreferences
  static const _legacyPrivateKeyKey = 'private_key';

  // Default server URL
  static const _defaultServerUrl = 'https://connect.afkdev.app';

  Future<void> initialize() async {
    _prefs = await SharedPreferences.getInstance();
    await _migratePrivateKeyToSecureStorage();
  }

  /// Migrate private key from SharedPreferences (plaintext) to secure storage (Keychain).
  /// Runs once — removes the legacy key after successful migration.
  /// If secure storage fails (e.g. Keychain unavailable), keeps using SharedPreferences.
  Future<void> _migratePrivateKeyToSecureStorage() async {
    final legacyKey = _prefs?.getString(_legacyPrivateKeyKey);
    if (legacyKey == null) return;

    try {
      // Check if already migrated
      final existing = await _secureStorage.read(key: _securePrivateKeyKey);
      if (existing != null) {
        // Already in secure storage — just remove the legacy copy
        await _prefs?.remove(_legacyPrivateKeyKey);
        hlog('Removed legacy private key from SharedPreferences', source: 'Storage');
        return;
      }

      // Migrate to secure storage
      await _secureStorage.write(key: _securePrivateKeyKey, value: legacyKey);
      await _prefs?.remove(_legacyPrivateKeyKey);
      hlog('Migrated private key to secure storage (Keychain)', source: 'Storage');
    } catch (e) {
      // Keychain access failed — keep using SharedPreferences as fallback
      hlog('Secure storage migration failed ($e), keeping legacy storage', source: 'Storage');
    }
  }

  /// Get or create a unique device ID
  String getOrCreateDeviceId() {
    if (_deviceId != null) return _deviceId!;

    _deviceId = _prefs?.getString(_deviceIdKey);
    if (_deviceId == null) {
      // Generate a proper UUID
      _deviceId = const Uuid().v4();
      _prefs?.setString(_deviceIdKey, _deviceId!);
      hlog('Generated new device ID: $_deviceId', source: 'Storage');
    }
    return _deviceId!;
  }

  /// Get private key. Tries secure storage (Keychain) first, falls back to SharedPreferences.
  Future<Uint8List?> getPrivateKey() async {
    if (_privateKey != null) return _privateKey;

    // Try secure storage first
    try {
      final stored = await _secureStorage.read(key: _securePrivateKeyKey);
      if (stored != null) {
        _privateKey = base64Decode(stored);
        return _privateKey;
      }
    } catch (e) {
      hlog('Secure storage read failed ($e), trying legacy storage', source: 'Storage');
    }

    // Fallback to SharedPreferences (legacy or if Keychain fails)
    final legacyStored = _prefs?.getString(_legacyPrivateKeyKey);
    if (legacyStored != null) {
      _privateKey = base64Decode(legacyStored);
    }
    return _privateKey;
  }

  /// Store a new keypair. Tries secure storage (Keychain) first, falls back to SharedPreferences.
  Future<void> storeKeyPair(Uint8List privateKey, String publicKeyBase64) async {
    _privateKey = privateKey;
    final encoded = base64Encode(privateKey);

    try {
      await _secureStorage.write(key: _securePrivateKeyKey, value: encoded);
      hlog('Stored new keypair (private key in secure storage)', source: 'Storage');
    } catch (e) {
      // Fallback to SharedPreferences if Keychain fails
      await _prefs?.setString(_legacyPrivateKeyKey, encoded);
      hlog('Secure storage write failed ($e), stored in SharedPreferences', source: 'Storage');
    }
    await _prefs?.setString(_publicKeyKey, publicKeyBase64);
  }

  /// Get server URL
  String getServerUrl() {
    return _prefs?.getString(_serverUrlKey) ?? _defaultServerUrl;
  }

  /// Set server URL
  Future<void> setServerUrl(String url) async {
    await _prefs?.setString(_serverUrlKey, url);
  }

  /// Check if there are any paired clients
  bool get hasPairedClients {
    final clients = _prefs?.getStringList(_pairedClientsKey);
    return clients != null && clients.isNotEmpty;
  }

  /// Get list of paired clients
  List<PairedClient> getPairedClients() {
    final clientsJson = _prefs?.getStringList(_pairedClientsKey) ?? [];
    return clientsJson.map((json) => PairedClient.fromJson(jsonDecode(json))).toList();
  }

  /// Add a paired client
  Future<void> addPairedClient(PairedClient client) async {
    final clients = getPairedClients();
    clients.removeWhere((c) => c.deviceId == client.deviceId);
    clients.add(client);

    final clientsJson = clients.map((c) => jsonEncode(c.toJson())).toList();
    await _prefs?.setStringList(_pairedClientsKey, clientsJson);
  }

  /// Get paired client by public key
  PairedClient? getPairedClient({String? byPublicKey, String? byDeviceId}) {
    final clients = getPairedClients();
    if (byPublicKey != null) {
      return clients.where((c) => c.publicKey == byPublicKey).firstOrNull;
    }
    if (byDeviceId != null) {
      return clients.where((c) => c.deviceId == byDeviceId).firstOrNull;
    }
    return null;
  }

  /// Remove all paired clients
  Future<void> clearPairedClients() async {
    await _prefs?.remove(_pairedClientsKey);
  }

  /// Get stream quality scale factor (1.0 = sharp/full res, 2.0 = responsive/half res)
  double getStreamQuality() {
    return _prefs?.getDouble(_streamQualityKey) ?? 1.0; // Default to sharp
  }

  /// Set stream quality scale factor
  Future<void> setStreamQuality(double scaleFactor) async {
    await _prefs?.setDouble(_streamQualityKey, scaleFactor);
    hlog('Stream quality set to: $scaleFactor', source: 'Storage');
  }

  /// Check if using responsive (lower resolution) streaming
  bool get isResponsiveStreaming => getStreamQuality() >= 2.0;

  // ── APNs Token Management ──

  /// Store APNs token for a paired client device.
  Future<void> storeApnsToken(String deviceId, String token) async {
    final tokens = _getApnsTokens();
    tokens[deviceId] = token;
    await _prefs?.setString(_apnsTokensKey, jsonEncode(tokens));
    hlog('Stored APNs token for device: $deviceId', source: 'Storage');
  }

  /// Get APNs token for a specific device.
  String? getApnsToken(String deviceId) {
    return _getApnsTokens()[deviceId];
  }

  /// Record which client connected most recently.
  Future<void> setLastConnectedClient(String deviceId) async {
    await _prefs?.setString(_lastConnectedClientKey, deviceId);
  }

  /// Get the last connected client's device ID.
  String? get lastConnectedClientId {
    return _prefs?.getString(_lastConnectedClientKey);
  }

  /// Record when a client was last connected.
  Future<void> setLastConnectedAt(DateTime at) async {
    await _prefs?.setString(_lastConnectedAtKey, at.toUtc().toIso8601String());
  }

  /// Timestamp of the last successful client connect.
  DateTime? get lastConnectedAt {
    final raw = _prefs?.getString(_lastConnectedAtKey);
    if (raw == null) return null;
    try {
      return DateTime.parse(raw).toUtc();
    } catch (_) {
      return null;
    }
  }

  /// Get APNs token for the last connected client.
  String? get lastConnectedApnsToken {
    final deviceId = lastConnectedClientId;
    if (deviceId == null) return null;
    return getApnsToken(deviceId);
  }

  Map<String, String> _getApnsTokens() {
    final raw = _prefs?.getString(_apnsTokensKey);
    if (raw == null) return {};
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map((k, v) => MapEntry(k, v as String));
    } catch (_) {
      return {};
    }
  }
}
