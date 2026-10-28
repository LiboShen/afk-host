/// Manages WebRTC peer connection, screen capture, and data channel.
/// Handles SDP offer/answer exchange and ICE candidates via delegate callbacks.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'device_storage.dart';
import 'linux/linux_input_handler.dart';
import 'log_service.dart';

/// Delegate for WebRTC events
abstract class WebRTCServiceDelegate {
  void onWebRTCLocalOffer(RTCSessionDescription offer);
  void onWebRTCLocalICECandidate(RTCIceCandidate candidate);
  void onWebRTCConnectionStateChanged(RTCPeerConnectionState state);
  void onWebRTCDataChannelOpen();
  void onWebRTCDataChannelMessage(String message);
}

class WebRTCService {
  WebRTCServiceDelegate? delegate;

  RTCPeerConnection? _peerConnection;
  RTCDataChannel? _dataChannel;
  MediaStream? _localStream;
  bool _isCapturingScreen = false;

  RTCPeerConnectionState _connectionState = RTCPeerConnectionState.RTCPeerConnectionStateNew;

  /// The source ID of the display currently being streamed.
  /// This is the platform's native display identifier (CGDirectDisplayID on macOS,
  /// HMONITOR on Windows) serialized as a string by flutter_webrtc.
  String? _streamingSourceId;

  /// Get the streaming display source ID (null if not capturing).
  String? get streamingSourceId => _streamingSourceId;

  // Configuration
  static const _iceServers = [
    {'urls': 'stun:stun.l.google.com:19302'},
  ];

  static const _configuration = {
    'iceServers': _iceServers,
    'sdpSemantics': 'unified-plan',
  };

  static const _offerConstraints = {
    'mandatory': {
      'OfferToReceiveAudio': false,
      'OfferToReceiveVideo': false,
    },
  };

  RTCPeerConnectionState get connectionState => _connectionState;
  bool get isConnected => _connectionState == RTCPeerConnectionState.RTCPeerConnectionStateConnected;

  /// Create peer connection and set up event handlers
  /// Set createDataChannel to false to defer data channel creation (for correct SDP ordering)
  Future<bool> initializePeerConnection({bool createDataChannel = true}) async {
    if (_peerConnection != null) {
      hlog('Peer connection already exists, cleaning up first', source: 'WebRTC');
      await closePeerConnection();
    }

    try {
      // Create peer connection using the flutter_webrtc helper
      _peerConnection = await createPeerConnection(_configuration);

      // Set up event handlers
      _peerConnection!.onIceCandidate = (candidate) {
        delegate?.onWebRTCLocalICECandidate(candidate);
      };

      _peerConnection!.onConnectionState = (state) {
        hlog('Connection state: $state', source: 'WebRTC');
        _connectionState = state;
        delegate?.onWebRTCConnectionStateChanged(state);
      };

      _peerConnection!.onIceConnectionState = (state) {};
      _peerConnection!.onIceGatheringState = (state) {};
      _peerConnection!.onSignalingState = (state) {};
      _peerConnection!.onTrack = (event) {};
      _peerConnection!.onRenegotiationNeeded = () {};

      // Optionally create data channel (can be deferred to control SDP ordering)
      if (createDataChannel) {
        await _initializeDataChannel();
      }

      hlog('Peer connection created successfully', source: 'WebRTC');
      return true;
    } catch (e) {
      hlog('Failed to create peer connection: $e', source: 'WebRTC');
      return false;
    }
  }

  /// Create data channel for input events (public method for deferred creation)
  Future<void> createDataChannel() async {
    await _initializeDataChannel();
  }

  /// Start screen capture and add to peer connection
  Future<bool> startScreenCapture() async {
    if (_peerConnection == null) {
      hlog('No peer connection available', source: 'WebRTC');
      return false;
    }

    // Guard against concurrent screen capture calls - the native WebRTC code
    // crashes if desktopCapturer.getSources() is called concurrently
    if (_isCapturingScreen) {
      hlog('Screen capture already in progress, skipping', source: 'WebRTC');
      return false;
    }
    _isCapturingScreen = true;

    // Log platform and session information for diagnostics
    if (Platform.isLinux) {
      final sessionType = Platform.environment['XDG_SESSION_TYPE'] ?? 'unknown';
      final desktop = Platform.environment['XDG_CURRENT_DESKTOP'] ?? 'unknown';
      hlog('Linux capture attempt: session=$sessionType, desktop=$desktop', source: 'WebRTC');

      // Start the portal session so NotifyPointerMotionAbsolute has a stream node.
      await LinuxInputHandler.shared.initialize();
    }

    try {
      // Get available screen sources
      hlog('Calling desktopCapturer.getSources()...', source: 'WebRTC');
      final sources = await desktopCapturer.getSources(
        types: [SourceType.Screen],
      );
      hlog('desktopCapturer.getSources() returned ${sources.length} source(s)', source: 'WebRTC');

      if (sources.isEmpty) {
        hlog('No screen sources available', source: 'WebRTC');
        return false;
      }

      // Log all available sources
      for (var i = 0; i < sources.length; i++) {
        final s = sources[i];
        hlog('  Source $i: name="${s.name}", id="${s.id}"', source: 'WebRTC');
      }

      // Use the first (main) screen
      final source = sources.first;
      _streamingSourceId = source.id;
      hlog('Selected screen: ${source.name} (id: ${source.id})', source: 'WebRTC');

      // Start screen capture with constraints
      hlog('Calling getDisplayMedia() with sourceId=${source.id}...', source: 'WebRTC');
      _localStream = await navigator.mediaDevices.getDisplayMedia({
        'video': {
          'deviceId': {'exact': source.id},
          'frameRate': {'ideal': 30, 'max': 30},
        },
        'audio': false,
      });
      hlog('getDisplayMedia() succeeded, stream acquired', source: 'WebRTC');

      // Add video track to peer connection
      final videoTracks = _localStream!.getVideoTracks();
      hlog('Stream has ${videoTracks.length} video track(s)', source: 'WebRTC');

      if (videoTracks.isEmpty) {
        hlog('No video tracks in captured stream', source: 'WebRTC');
        return false;
      }

      final videoTrack = videoTracks.first;
      hlog('Video track: id=${videoTrack.id}, label="${videoTrack.label}", enabled=${videoTrack.enabled}', source: 'WebRTC');

      // Ensure the track is enabled
      videoTrack.enabled = true;

      // Add track to peer connection (creates transceiver implicitly)
      final sender = await _peerConnection!.addTrack(videoTrack, _localStream!);
      await _applyEncodingParams(sender);
      await _applyCodecPreferences();

      hlog('Screen capture started, track added to peer connection', source: 'WebRTC');
      return true;
    } catch (e, stackTrace) {
      hlog('Failed to start screen capture: $e', source: 'WebRTC');
      hlog('Stack trace: $stackTrace', source: 'WebRTC');

      // Additional context for Linux debugging
      if (Platform.isLinux) {
        final sessionType = Platform.environment['XDG_SESSION_TYPE'] ?? 'unknown';
        hlog('Capture failed on Linux $sessionType session', source: 'WebRTC');
        hlog('Known issue: flutter_webrtc may not support PipeWire/Wayland - see issue #1542', source: 'WebRTC');
      }

      return false;
    } finally {
      _isCapturingScreen = false;
    }
  }

  /// Create and send SDP offer
  Future<void> createOffer({bool iceRestart = false}) async {
    if (_peerConnection == null) {
      hlog('No peer connection for creating offer', source: 'WebRTC');
      return;
    }

    try {

      final constraints = Map<String, dynamic>.from(_offerConstraints);
      if (iceRestart) {
        constraints['mandatory'] = {
          ...(constraints['mandatory'] as Map<String, dynamic>? ?? {}),
          'IceRestart': true,
        };
      }

      final offer = await _peerConnection!.createOffer(constraints);
      await _peerConnection!.setLocalDescription(offer);

      hlog('Local offer created', source: 'WebRTC');

      delegate?.onWebRTCLocalOffer(offer);
    } catch (e) {
      hlog('Failed to create offer: $e', source: 'WebRTC');
    }
  }

  /// Set remote SDP answer
  Future<void> setRemoteAnswer(String sdp) async {
    if (_peerConnection == null) {
      hlog('No peer connection for setting answer', source: 'WebRTC');
      return;
    }

    try {
      final answer = RTCSessionDescription(sdp, 'answer');
      await _peerConnection!.setRemoteDescription(answer);
      
      // Log the negotiated video codec
      final codec = _extractNegotiatedVideoCodec(sdp);
      hlog('Negotiated codec: $codec', source: 'WebRTC');
    } catch (e) {
      hlog('Failed to set remote answer: $e', source: 'WebRTC');
    }
  }

  /// Extract the first video codec from SDP answer (the negotiated one)
  String _extractNegotiatedVideoCodec(String sdp) {
    final lines = sdp.split('\n');
    String? firstPayloadType;
    
    // Find the m=video line to get the first payload type (the selected one)
    for (final line in lines) {
      if (line.startsWith('m=video')) {
        // Format: m=video 9 UDP/TLS/RTP/SAVPF 96 97 98 ...
        final parts = line.split(' ');
        if (parts.length > 3) {
          firstPayloadType = parts[3]; // First codec payload type
        }
        break;
      }
    }
    
    if (firstPayloadType == null) return 'unknown';
    
    // Find the rtpmap for this payload type
    for (final line in lines) {
      if (line.startsWith('a=rtpmap:$firstPayloadType ')) {
        // Format: a=rtpmap:96 VP9/90000
        final match = RegExp(r'a=rtpmap:\d+ (\w+)/').firstMatch(line);
        if (match != null) {
          return match.group(1) ?? 'unknown';
        }
      }
    }
    
    return 'unknown';
  }

  /// Add remote ICE candidate
  Future<void> addIceCandidate(String candidate, String? sdpMid, int sdpMLineIndex) async {
    if (_peerConnection == null) {
      hlog('No peer connection for adding ICE candidate', source: 'WebRTC');
      return;
    }

    try {
      final iceCandidate = RTCIceCandidate(candidate, sdpMid, sdpMLineIndex);
      await _peerConnection!.addCandidate(iceCandidate);
    } catch (e) {
      hlog('Failed to add ICE candidate: $e', source: 'WebRTC');
    }
  }

  /// Send message over data channel
  void sendDataChannelMessage(String message) {
    if (_dataChannel == null || _dataChannel!.state != RTCDataChannelState.RTCDataChannelOpen) {
      hlog('Data channel not open', source: 'WebRTC');
      return;
    }

    _dataChannel!.send(RTCDataChannelMessage(message));
  }

  /// Close peer connection and clean up resources
  Future<void> closePeerConnection() async {
    hlog('Closing peer connection', source: 'WebRTC');

    // Reset capture flag and streaming display ID
    _isCapturingScreen = false;
    _streamingSourceId = null;

    // Stop screen capture
    _localStream?.getTracks().forEach((track) {
      track.stop();
    });
    await _localStream?.dispose();
    _localStream = null;

    // Close data channel
    await _dataChannel?.close();
    _dataChannel = null;

    // Close peer connection
    await _peerConnection?.close();
    _peerConnection = null;

    _connectionState = RTCPeerConnectionState.RTCPeerConnectionStateClosed;

    hlog('Cleanup complete', source: 'WebRTC');
  }

  // MARK: - Private Methods

  Future<void> _applyEncodingParams(RTCRtpSender sender) async {
    try {
      final parameters = sender.parameters;
      if (parameters.encodings != null && parameters.encodings!.isNotEmpty) {
        final scaleFactor = DeviceStorage.shared.getStreamQuality();
        parameters.encodings![0].maxBitrate = 8000000;
        parameters.encodings![0].scaleResolutionDownBy = scaleFactor;
        await sender.setParameters(parameters);
        hlog('Encoding: scaleResolutionDownBy=$scaleFactor', source: 'WebRTC');
      }
    } catch (e) {
      hlog('Failed to set encoding parameters: $e', source: 'WebRTC');
    }
  }

  Future<void> _applyCodecPreferences() async {
    final transceivers = await _peerConnection!.getTransceivers();
    for (final transceiver in transceivers) {
      if (transceiver.sender.track?.kind == 'video') {
        try {
          final capabilities = await getRtpSenderCapabilities('video');
          final codecs = capabilities.codecs ?? [];
          final List<RTCRtpCodecCapability> ordered = [];
          for (var c in codecs) {
            if (c.mimeType.toLowerCase().contains('vp9')) {
              ordered.add(c);
              break;
            }
          }
          for (var c in codecs) {
            if (c.mimeType.toLowerCase().contains('h264')) ordered.add(c);
          }
          for (var c in codecs) {
            if (!ordered.contains(c)) ordered.add(c);
          }
          if (ordered.isNotEmpty) await transceiver.setCodecPreferences(ordered);
        } catch (e) {
          hlog('Failed to set codec preferences: $e', source: 'WebRTC');
        }
      }
    }
  }

  Future<void> _initializeDataChannel() async {
    if (_peerConnection == null) return;

    final config = RTCDataChannelInit()
      ..ordered = true
      ..maxRetransmits = 3;

    _dataChannel = await _peerConnection!.createDataChannel('input', config);

    _dataChannel!.onDataChannelState = (state) {
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        delegate?.onWebRTCDataChannelOpen();
      }
    };

    _dataChannel!.onMessage = (message) {
      if (message.type == MessageType.text) {
        delegate?.onWebRTCDataChannelMessage(message.text);
      }
    };

    hlog('Data channel created', source: 'WebRTC');
  }
}
