/// Manages WebSocket connection to the signaling server.
/// Handles connection lifecycle, exponential backoff reconnection, and
/// signaling protocol (register, connect, WebRTC offer/answer/ICE relay).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'crypto_service.dart';
import 'device_storage.dart';
import 'log_service.dart';

/// Connection state for the central signaling server
enum SignalingConnectionState {
  disconnected,
  connecting,
  connected,
  waitingToReconnect,
}

/// Delegate for signaling events
abstract class SignalingServiceDelegate {
  void onConnectRequest(String fromDeviceId, Map<String, dynamic> data);
  void onPingRequest(String fromDeviceId);
  void onDisconnectRequest(String fromDeviceId);
  void onWebRTCAnswer(String sdp);
  void onICECandidate(String candidate, String? sdpMid, int sdpMLineIndex);
  void onRenegotiationRequest();
  void onSignalingStateChanged(SignalingConnectionState state);
}

class SignalingService {
  SignalingServiceDelegate? delegate;

  WebSocketChannel? _webSocket;
  StreamSubscription? _webSocketSubscription;
  SignalingConnectionState _connectionState =
      SignalingConnectionState.disconnected;
  int _reconnectAttempt = 0;
  Timer? _reconnectTimer;
  String? _connectedClientDeviceId;
  int _connectEpoch = 0;

  static const _maxReconnectDelay = Duration(seconds: 30);
  static const _baseReconnectDelay = Duration(seconds: 1);
  static const _socketConnectTimeout = Duration(seconds: 8);
  static const _socketPingInterval = Duration(seconds: 15);

  SignalingConnectionState get connectionState => _connectionState;
  String? get connectedDeviceId => _connectedClientDeviceId;

  /// Connect to the central signaling server
  Future<void> connect() async {
    if (_connectionState == SignalingConnectionState.connecting ||
        _connectionState == SignalingConnectionState.connected) {
      hlog('Already connecting/connected, skipping', source: 'Signaling');
      return;
    }

    final serverUrl = DeviceStorage.shared.getServerUrl();
    final wsUrl = serverUrl
        .replaceFirst('https://', 'wss://')
        .replaceFirst('http://', 'ws://');

    final url = '$wsUrl/v0/ws';

    _reconnectTimer?.cancel();
    _reconnectTimer = null;

    final epoch = ++_connectEpoch;

    _setConnectionState(SignalingConnectionState.connecting);
    hlog('Connecting to: $url', source: 'Signaling');

    IOWebSocketChannel? socket;
    try {
      socket = IOWebSocketChannel.connect(
        Uri.parse(url),
        connectTimeout: _socketConnectTimeout,
        pingInterval: _socketPingInterval,
      );

      // Wait for the WebSocket upgrade. The TCP connect phase has its own
      // timeout via connectTimeout above, so total wait can be up to 2×.
      await socket.ready.timeout(_socketConnectTimeout);

      // This attempt became stale while waiting for the socket handshake.
      if (epoch != _connectEpoch ||
          _connectionState != SignalingConnectionState.connecting) {
        // Fire-and-forget: we don't await close on stale sockets since errors
        // from them are benign and we don't want to delay the new connection.
        socket.sink.close();
        return;
      }

      // Replace any stale listener/socket before promoting the new one.
      await _webSocketSubscription?.cancel();
      _webSocketSubscription = null;
      _webSocket?.sink.close();

      _webSocket = socket;
      _webSocketSubscription = socket.stream.listen(
        _handleMessage,
        onError: (error) {
          hlog('WebSocket error: $error', source: 'Signaling');
          _handleDisconnect();
        },
        onDone: () {
          hlog('WebSocket closed', source: 'Signaling');
          _handleDisconnect();
        },
      );

      _setConnectionState(SignalingConnectionState.connected);
      if (_reconnectAttempt > 0) {
        hlog(
          'Connected after $_reconnectAttempt reconnect attempt(s)',
          source: 'Signaling',
        );
      } else {
        hlog('Connected successfully', source: 'Signaling');
      }
      _reconnectAttempt = 0;

      // Send registration message.
      await _sendRegisterMessage();
    } catch (e) {
      hlog('Connection failed: $e', source: 'Signaling');

      // Fire-and-forget close — errors from a failed socket are benign.
      socket?.sink.close();

      // A newer connect/disconnect action superseded this attempt.
      if (epoch != _connectEpoch) {
        return;
      }

      _setConnectionState(SignalingConnectionState.disconnected);
      _scheduleReconnect();
    }
  }

  /// Disconnect from the server
  void disconnect() {
    hlog('Disconnecting', source: 'Signaling');

    // Invalidate any in-flight connect attempt.
    _connectEpoch++;

    _reconnectTimer?.cancel();
    _reconnectTimer = null;

    _webSocketSubscription?.cancel();
    _webSocketSubscription = null;

    _webSocket?.sink.close();
    _webSocket = null;

    _setConnectionState(SignalingConnectionState.disconnected);
    _reconnectAttempt = 0;
    _connectedClientDeviceId = null;
  }

  /// Send WebRTC offer to connected client device
  Future<void> sendWebRTCOffer(String sdp) async {
    await _sendToServer(type: 'webrtc_offer', payload: {'sdp': sdp});
  }

  /// Send ICE candidate to connected client device
  Future<void> sendICECandidate(
    String candidate,
    String? sdpMid,
    int sdpMLineIndex,
  ) async {
    await _sendToServer(
      type: 'webrtc_ice_candidate',
      payload: {
        'candidate': candidate,
        'sdpMid': sdpMid,
        'sdpMLineIndex': sdpMLineIndex,
      },
    );
  }

  /// Send connect acknowledgment
  Future<void> sendConnectAck(String toDeviceId) async {
    final hostname = Platform.localHostname;
    await _sendToServer(
      type: 'connect_ack',
      to: toDeviceId,
      payload: {'hostname': hostname},
    );
  }

  /// Send pong response
  Future<void> sendPong(String toDeviceId) async {
    await _sendToServer(type: 'pong', to: toDeviceId, payload: {});
  }

  /// Send a server-bound message (not peer-to-peer, no signing needed).
  /// Used for messages the server handles directly, like push_notification.
  void sendServerMessage(String type, Map<String, dynamic> data) {
    if (_webSocket == null) {
      hlog(
        'Cannot send $type: not connected to signaling server',
        source: 'Signaling',
      );
      return;
    }

    final deviceId = DeviceStorage.shared.getOrCreateDeviceId();
    final message = {'type': type, 'from': deviceId, 'data': data};
    final text = jsonEncode(message);
    _webSocket!.sink.add(text);
  }

  // MARK: - Private Methods

  void _setConnectionState(SignalingConnectionState state) {
    _connectionState = state;
    delegate?.onSignalingStateChanged(state);
  }

  Future<void> _sendRegisterMessage() async {
    final deviceId = DeviceStorage.shared.getOrCreateDeviceId();
    final publicKey = await CryptoService.shared.getPublicKeyBase64();

    final message = {
      'type': 'register',
      'from': deviceId,
      'userId': deviceId,
      'data': {'deviceType': 'host', 'publicKey': publicKey},
    };

    final text = jsonEncode(message);
    _webSocket?.sink.add(text);
  }

  Future<void> _sendToServer({
    required String type,
    String? to,
    required Map<String, dynamic> payload,
  }) async {
    final target = to ?? _connectedClientDeviceId;
    if (target == null) {
      hlog('No target device to send to', source: 'Signaling');
      return;
    }

    final deviceId = DeviceStorage.shared.getOrCreateDeviceId();
    final publicKey = await CryptoService.shared.getPublicKeyBase64();

    // Build message for signing
    final message = {
      'type': type,
      'from': deviceId,
      'to': target,
      'userId': deviceId,
      'data': payload,
    };

    // Sign the payload
    final signed = await CryptoService.shared.signPayload(message);
    if (signed == null) {
      hlog('Failed to sign message', source: 'Signaling');
      return;
    }

    // Wrap in envelope format
    final envelope = {
      'payload': signed.payload,
      'sig': signed.signature,
      'publicKey': publicKey,
    };

    final text = jsonEncode(envelope);
    _webSocket?.sink.add(text);
  }

  void _handleMessage(dynamic message) {
    final text = message is String
        ? message
        : utf8.decode(message as List<int>);

    Map<String, dynamic>? raw;
    try {
      raw = jsonDecode(text) as Map<String, dynamic>;
    } catch (e) {
      hlog('Invalid JSON message', source: 'Signaling');
      return;
    }

    // Check if this is an envelope (peer-to-peer) or simple message (server)
    if (raw.containsKey('payload') && raw['payload'] is String) {
      _handleEnvelopeMessage(raw);
    } else {
      _handleSimpleMessage(raw);
    }
  }

  Future<void> _handleEnvelopeMessage(Map<String, dynamic> envelope) async {
    final payloadString = envelope['payload'] as String?;
    final signature = envelope['sig'] as String?;
    final publicKey = envelope['publicKey'] as String?;

    if (payloadString == null || signature == null || publicKey == null) {
      hlog('Envelope missing required fields', source: 'Signaling');
      return;
    }

    // Verify the sender is a known paired client by public key
    final pairedClient = DeviceStorage.shared.getPairedClient(
      byPublicKey: publicKey,
    );
    if (pairedClient == null) {
      hlog(
        'Rejecting message from unknown/unpaired public key',
        source: 'Signaling',
      );
      return;
    }

    // Verify Ed25519 signature
    final isValid = await CryptoService.shared.verifyPayload(
      payloadString,
      signature,
      publicKey,
    );

    if (!isValid) {
      hlog(
        'Signature verification failed — rejecting message',
        source: 'Signaling',
      );
      return;
    }

    Map<String, dynamic>? payload;
    try {
      payload = jsonDecode(payloadString) as Map<String, dynamic>;
    } catch (e) {
      hlog('Failed to parse envelope payload', source: 'Signaling');
      return;
    }

    final type = payload['type'] as String?;
    final fromDevice = payload['from'] as String?;
    final data = payload['data'] as Map<String, dynamic>? ?? {};

    // Additional check: verify fromDeviceId matches the paired client
    if (fromDevice != null && fromDevice != pairedClient.deviceId) {
      hlog(
        'Device ID mismatch: message from $fromDevice but key belongs to ${pairedClient.deviceId}',
        source: 'Signaling',
      );
      return;
    }

    switch (type) {
      case 'connect':
        if (fromDevice != null) {
          _connectedClientDeviceId = fromDevice;
          delegate?.onConnectRequest(fromDevice, data);
        }
        break;

      case 'ping':
        if (fromDevice != null) {
          delegate?.onPingRequest(fromDevice);
        }
        break;

      case 'disconnect':
        if (fromDevice != null) {
          delegate?.onDisconnectRequest(fromDevice);
          _connectedClientDeviceId = null;
        }
        break;

      case 'webrtc_answer':
        final sdp = data['sdp'] as String?;
        if (sdp != null) {
          delegate?.onWebRTCAnswer(sdp);
        }
        break;

      case 'webrtc_ice_candidate':
        final candidate = data['candidate'] as String?;
        final sdpMid = data['sdpMid'] as String?;
        final sdpMLineIndex = data['sdpMLineIndex'] as int? ?? 0;
        if (candidate != null) {
          delegate?.onICECandidate(candidate, sdpMid, sdpMLineIndex);
        }
        break;

      case 'webrtc_request_renegotiation':
        delegate?.onRenegotiationRequest();
        break;

      default:
        hlog('Unknown envelope message type: $type', source: 'Signaling');
    }
  }

  void _handleSimpleMessage(Map<String, dynamic> message) {
    final type = message['type'] as String?;

    switch (type) {
      case 'error':
        final data = message['data'] as Map<String, dynamic>?;
        final code = data?['code'] as String? ?? 'UNKNOWN';
        final errorMessage = data?['message'] as String? ?? 'Unknown error';
        hlog('Server error: $code - $errorMessage', source: 'Signaling');
        break;

      case 'register_ack':
        break;

      default:
        hlog('Unknown simple message type: $type', source: 'Signaling');
    }
  }

  void _handleDisconnect() {
    if (_connectionState != SignalingConnectionState.connecting &&
        _connectionState != SignalingConnectionState.connected) {
      return;
    }

    _webSocketSubscription?.cancel();
    _webSocketSubscription = null;

    _webSocket?.sink.close();
    _webSocket = null;

    _setConnectionState(SignalingConnectionState.disconnected);
    _connectedClientDeviceId = null;

    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();

    // Exponential backoff with jitter
    final exponentialDelay = _baseReconnectDelay * pow(2, _reconnectAttempt);
    final delay = exponentialDelay > _maxReconnectDelay
        ? _maxReconnectDelay
        : exponentialDelay;
    final jitter = Duration(milliseconds: Random().nextInt(500));
    final totalDelay = delay + jitter;

    _reconnectAttempt++;
    _setConnectionState(SignalingConnectionState.waitingToReconnect);

    hlog(
      'Scheduling reconnect in ${totalDelay.inSeconds}s (attempt $_reconnectAttempt)',
      source: 'Signaling',
    );

    _reconnectTimer = Timer(totalDelay, () {
      connect();
    });
  }

  /// Trigger immediate reconnection, resetting exponential backoff.
  /// Called by RemoteSessionManager when network becomes available.
  void reconnectImmediately() {
    // Only act if we're disconnected or waiting to reconnect
    if (_connectionState != SignalingConnectionState.disconnected &&
        _connectionState != SignalingConnectionState.waitingToReconnect) {
      hlog(
        'Already connecting/connected, skipping immediate reconnect',
        source: 'Signaling',
      );
      return;
    }

    hlog(
      'Network available - triggering immediate reconnect',
      source: 'Signaling',
    );

    // Cancel any pending scheduled reconnect
    _reconnectTimer?.cancel();
    _reconnectTimer = null;

    // Reset backoff for fresh start
    _reconnectAttempt = 0;

    // Connect immediately
    connect();
  }
}
