/// Coordinates the remote desktop streaming session lifecycle.
/// Orchestrates signaling, WebRTC, network monitoring, and peripheral services
/// (cursor, window, input) - delegates to specialized services for each.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'app_host_service.dart';
import 'crypto_service.dart';
import 'cursor_service.dart';
import 'device_storage.dart';
import 'display_wake_service.dart';
import 'input_service.dart';
import 'linux/linux_input_handler.dart';
import 'log_service.dart';
import 'network_monitor_service.dart';
import 'cli_server.dart';
import 'signaling_service.dart';
import 'webrtc_service.dart';
import 'window_manager_service.dart';

class RemoteSessionManager extends ChangeNotifier
    implements SignalingServiceDelegate, WebRTCServiceDelegate {
  final SignalingService _signalingService = SignalingService();
  final WebRTCService _webrtcService = WebRTCService();
  final CliServer _cliServer = CliServer();

  String? _connectedClientId;
  bool _isSettingUpWebRTC = false;
  int _sessionGeneration = 0;
  DateTime? _sessionStartTime;

  static const Duration _notificationRecencyWindow = Duration(minutes: 30);

  String? get connectedClientId => _connectedClientId;
  bool get isStreaming => _connectedClientId != null && !_isSettingUpWebRTC;

  RemoteSessionManager() {
    _signalingService.delegate = this;
    _webrtcService.delegate = this;
  }

  /// Initialize and auto-connect to signaling server
  Future<void> initialize() async {
    await DeviceStorage.shared.initialize();

    // Initialize crypto
    final storedPrivateKey = DeviceStorage.shared.getPrivateKey();
    if (storedPrivateKey != null) {
      await CryptoService.shared.initialize(seed: storedPrivateKey);
    } else {
      await CryptoService.shared.initialize();
      final newPrivateKey = await CryptoService.shared.getPrivateKeyBytes();
      final newPublicKey = await CryptoService.shared.getPublicKeyBase64();
      await DeviceStorage.shared.storeKeyPair(newPrivateKey, newPublicKey);
    }

    hlog(
      'Initialized, device: ${DeviceStorage.shared.getOrCreateDeviceId()}',
      source: 'RemoteSession',
    );

    // Start notification socket server for agent hooks
    await _startCliServer();

    // Start network monitoring for faster reconnection
    _startNetworkMonitoring();

    // Auto-connect to signaling
    _signalingService.connect();
  }

  /// Start monitoring network connectivity for faster reconnection
  void _startNetworkMonitoring() {
    NetworkMonitorService.shared.onNetworkBecameAvailable = () {
      hlog(
        'Network became available, triggering reconnect',
        source: 'RemoteSession',
      );
      _signalingService.reconnectImmediately();
    };
    NetworkMonitorService.shared.onNetworkBecameUnavailable = () {
      hlog(
        'Network unavailable, disconnecting signaling to avoid stale connection',
        source: 'RemoteSession',
      );
      _signalingService.disconnect();
    };
    NetworkMonitorService.shared.startMonitoring();
  }

  /// Start the local notification socket server for agent hooks.
  Future<void> _startCliServer() async {
    _cliServer.onNotification = _handleAgentNotification;
    try {
      await _cliServer.start();
    } catch (e) {
      hlog('CLI server failed to start: $e', source: 'RemoteSession');
    }
  }

  /// Handle a notification from the `afk` CLI — relay to signaling server for APNs delivery.
  void _handleAgentNotification(String message, String timestamp) {
    final apnsToken = DeviceStorage.shared.lastConnectedApnsToken;
    if (apnsToken == null) {
      hlog(
        'No APNs token available, cannot send push notification',
        source: 'RemoteSession',
      );
      return;
    }

    final lastConnectedAt = DeviceStorage.shared.lastConnectedAt;
    if (lastConnectedAt == null ||
        DateTime.now().toUtc().difference(lastConnectedAt) >
            _notificationRecencyWindow) {
      hlog(
        'Skipping push notification: last client activity is older than 30 minutes',
        source: 'RemoteSession',
      );
      return;
    }

    _signalingService.sendServerMessage('push_notification', {
      'apnsToken': apnsToken,
      'title': 'AFK',
      'body': message,
    });

    hlog(
      'Sent agent notification to server: $message',
      source: 'RemoteSession',
    );
  }

  @override
  void dispose() {
    _cliServer.stop();
    super.dispose();
  }

  /// Reconnect to signaling (e.g., after pairing)
  void reconnect() {
    _signalingService.connect();
  }

  // MARK: - SignalingServiceDelegate

  @override
  void onSignalingStateChanged(SignalingConnectionState state) {
    _updateNativeState();
    notifyListeners();
  }

  @override
  void onConnectRequest(String fromDeviceId, Map<String, dynamic> data) async {
    hlog('Connect request from: $fromDeviceId', source: 'RemoteSession');

    // Persist APNs token and last-connected client for push notifications (fire-and-forget)
    final apnsToken = data['apnsToken'] as String?;
    if (apnsToken != null) {
      DeviceStorage.shared.storeApnsToken(fromDeviceId, apnsToken);
    }
    DeviceStorage.shared.setLastConnectedClient(fromDeviceId);
    DeviceStorage.shared.setLastConnectedAt(DateTime.now());

    // Prevent concurrent connection setup - if we're already setting up,
    // ignore this request (client will retry)
    if (_isSettingUpWebRTC) {
      hlog(
        'Already setting up WebRTC, ignoring duplicate connect request',
        source: 'RemoteSession',
      );
      return;
    }

    final generation = _beginNewSessionGeneration();

    // Set flag immediately to block concurrent requests before any await
    _isSettingUpWebRTC = true;

    // Clean up previous session if switching clients or reconnecting
    if (_connectedClientId != null) {
      if (_connectedClientId != fromDeviceId) {
        hlog(
          'Switching from $_connectedClientId to $fromDeviceId',
          source: 'RemoteSession',
        );
      } else {
        hlog(
          'Reconnect from same device, resetting session',
          source: 'RemoteSession',
        );
      }
      await _cleanup();

      if (_isStaleGeneration(generation)) {
        hlog(
          'Connect request became stale during cleanup',
          source: 'RemoteSession',
        );
        return;
      }
    }

    _connectedClientId = fromDeviceId;
    notifyListeners();

    _signalingService.sendConnectAck(fromDeviceId);
    _startWebRTCStreaming(generation);
  }

  @override
  void onPingRequest(String fromDeviceId) {
    hlog('Ping from: $fromDeviceId', source: 'RemoteSession');
    _signalingService.sendPong(fromDeviceId);
  }

  @override
  void onDisconnectRequest(String fromDeviceId) async {
    hlog('Disconnect from: $fromDeviceId', source: 'RemoteSession');

    // Only handle disconnect for the connected device
    if (_connectedClientId != fromDeviceId) {
      hlog(
        'Ignoring disconnect from unrelated device',
        source: 'RemoteSession',
      );
      return;
    }

    // Invalidate all in-flight session work so stale async paths can't mutate state.
    final generation = _beginNewSessionGeneration();

    // Always cleanup, even if we were in the middle of WebRTC setup
    // This ensures state is properly reset for the next connection attempt
    await _cleanup();

    if (_isStaleGeneration(generation)) {
      hlog(
        'Disconnect cleanup became stale, skipping state reset',
        source: 'RemoteSession',
      );
      return;
    }

    _isSettingUpWebRTC = false;
    _connectedClientId = null;
    notifyListeners();
  }

  @override
  void onWebRTCAnswer(String sdp) {
    _webrtcService.setRemoteAnswer(sdp);
  }

  @override
  void onICECandidate(String candidate, String? sdpMid, int sdpMLineIndex) {
    _webrtcService.addIceCandidate(candidate, sdpMid, sdpMLineIndex);
  }

  @override
  void onRenegotiationRequest() {
    _webrtcService.createOffer(iceRestart: true);
  }

  // MARK: - WebRTCServiceDelegate

  @override
  void onWebRTCLocalOffer(RTCSessionDescription offer) {
    _signalingService.sendWebRTCOffer(offer.sdp!);
  }

  @override
  void onWebRTCLocalICECandidate(RTCIceCandidate candidate) {
    _signalingService.sendICECandidate(
      candidate.candidate!,
      candidate.sdpMid,
      candidate.sdpMLineIndex!,
    );
  }

  @override
  void onWebRTCConnectionStateChanged(RTCPeerConnectionState state) async {
    hlog('WebRTC state: $state', source: 'RemoteSession');

    if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
      _isSettingUpWebRTC = false;
      _updateNativeState();
      notifyListeners();
    } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
      // Disconnected is transient — libwebrtc will promote it to Failed if ICE can't recover.
      // During reconnection, OLD peer events can arrive while NEW setup is in progress.
      if (_isSettingUpWebRTC) {
        hlog(
          'Ignoring $state event during setup (from old connection)',
          source: 'RemoteSession',
        );
        return;
      }

      final generation = _beginNewSessionGeneration();
      _isSettingUpWebRTC = false;
      await _cleanup();

      if (_isStaleGeneration(generation)) {
        hlog(
          'WebRTC $state cleanup became stale, skipping state reset',
          source: 'RemoteSession',
        );
        return;
      }

      _connectedClientId = null;
      _updateNativeState();
      notifyListeners();
    } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
      // During reconnection, the OLD peer connection fires 'closed' after we've
      // already started setting up a NEW one. Ignore these stale events.
      if (_isSettingUpWebRTC) {
        hlog(
          'Ignoring closed event during setup (from old connection)',
          source: 'RemoteSession',
        );
        return;
      }

      final generation = _beginNewSessionGeneration();
      await _cleanup();

      if (_isStaleGeneration(generation)) {
        hlog(
          'WebRTC closed cleanup became stale, skipping state reset',
          source: 'RemoteSession',
        );
        return;
      }

      _connectedClientId = null;
      _updateNativeState();
      notifyListeners();
    }
  }

  int _beginNewSessionGeneration() => ++_sessionGeneration;

  bool _isStaleGeneration(int generation) => generation != _sessionGeneration;

  void _updateNativeState() {
    final pairedClients = DeviceStorage.shared.getPairedClients();
    AppHostService.shared.updateState(
      isConnectedToServer:
          _signalingService.connectionState ==
          SignalingConnectionState.connected,
      isStreaming: isStreaming,
      connectedClientCount: isStreaming ? 1 : 0,
      pairedDeviceCount: pairedClients.length,
      pairedDeviceNames: pairedClients
          .map((c) => c.deviceName ?? 'iOS Device')
          .toList(),
      statusMessage: isStreaming ? 'Streaming' : 'Waiting',
    );
  }

  @override
  void onWebRTCDataChannelOpen() {
    hlog('Data channel open', source: 'RemoteSession');
    _sessionStartTime = DateTime.now();
    _checkAccessibilityPermissions();

    WindowManagerService.shared.sendDataChannelMessage = (message) {
      _webrtcService.sendDataChannelMessage(jsonEncode(message));
    };

    WindowManagerService.shared.startMonitoring();
    WindowManagerService.shared.broadcastWindowList();
    _startCursorMonitoring();
  }

  @override
  void onWebRTCDataChannelMessage(String message) {
    _handleMessage(message);
  }

  // MARK: - Private

  Future<void> _startWebRTCStreaming(int generation) async {
    // Wake display before starting screen capture (macOS only)
    await DisplayWakeService.shared.wakeDisplay();
    if (_isStaleGeneration(generation)) return;

    await Future.delayed(const Duration(milliseconds: 500));
    if (_isStaleGeneration(generation)) return;

    final created = await _webrtcService.initializePeerConnection(
      createDataChannel: true,
    );
    if (_isStaleGeneration(generation)) return;

    if (!created) {
      _isSettingUpWebRTC = false;
      return;
    }

    final captureStarted = await _webrtcService.startScreenCapture();
    if (_isStaleGeneration(generation)) return;

    if (!captureStarted) {
      _isSettingUpWebRTC = false;
      return;
    }

    // Notify WindowManagerService which display is being streamed
    // This enables multi-display support (moving windows to streaming display)
    await WindowManagerService.shared.setStreamingDisplayId(
      _webrtcService.streamingSourceId,
    );
    if (_isStaleGeneration(generation)) return;

    await Future.delayed(const Duration(milliseconds: 500));
    if (_isStaleGeneration(generation)) return;

    await _webrtcService.createOffer();
  }

  Future<void> _cleanup() async {
    // Log session duration if we had an active session
    if (_sessionStartTime != null) {
      final duration = DateTime.now().difference(_sessionStartTime!);
      hlog(
        'Session ended after ${_formatDuration(duration)}',
        source: 'RemoteSession',
      );
      _sessionStartTime = null;
    }

    CursorService.shared.onCursorChanged = null;
    CursorService.shared.stopMonitoring();
    WindowManagerService.shared.stopMonitoring();
    WindowManagerService.shared.sendDataChannelMessage = null;
    await _webrtcService.closePeerConnection();

    // Dispose the Linux input handler so the portal session is properly closed
    // and re-initialized on the next connection (fixes stale D-Bus session and
    // double KDE screen-sharing indicator dots).
    if (Platform.isLinux) {
      await LinuxInputHandler.shared.dispose();
    }
  }

  String _formatDuration(Duration d) {
    if (d.inHours > 0) {
      return '${d.inHours}h ${d.inMinutes.remainder(60)}m';
    } else if (d.inMinutes > 0) {
      return '${d.inMinutes}m ${d.inSeconds.remainder(60)}s';
    } else {
      return '${d.inSeconds}s';
    }
  }

  void _startCursorMonitoring() {
    CursorService.shared.onCursorChanged = (cursorData) {
      final message = {
        'type': 'cursor_image',
        'timestamp': DateTime.now().millisecondsSinceEpoch / 1000.0,
        'data': cursorData,
      };
      _webrtcService.sendDataChannelMessage(jsonEncode(message));
    };
    CursorService.shared.startMonitoring();
  }

  Future<void> _checkAccessibilityPermissions() async {
    final hasAccess = await InputService.shared.checkAccessibilityPermissions();
    if (!hasAccess) {
      await InputService.shared.requestAccessibilityPermissions();
    }
  }

  Future<void> _handleMessage(String message) async {
    if (await WindowManagerService.shared.processDataChannelMessage(message)) {
      return;
    }
    await InputService.shared.processDataChannelMessage(message);
  }
}
