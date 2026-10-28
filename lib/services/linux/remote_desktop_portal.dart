/// RemoteDesktop portal service for Linux input injection.
/// Uses xdg-desktop-portal via D-Bus to inject mouse and keyboard events.
///
/// The RemoteDesktop portal provides a secure way to inject input on Wayland
/// by requiring user permission via a system dialog.
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:dbus/dbus.dart';

import '../log_service.dart';

/// Portal session state
enum PortalSessionState {
  disconnected,
  creatingSession,
  selectingDevices,
  starting,
  active,
  error,
}

/// RemoteDesktop portal service for Linux input injection
class RemoteDesktopPortal {
  // Singleton instance
  static final RemoteDesktopPortal shared = RemoteDesktopPortal._();

  RemoteDesktopPortal._();

  // D-Bus client
  DBusClient? _client;

  // Portal objects
  DBusRemoteObject? _portal;

  // Session state
  PortalSessionState _state = PortalSessionState.disconnected;
  PortalSessionState get state => _state;

  // Session handle (D-Bus object path)
  DBusObjectPath? _sessionHandle;

  // Stream node ID from ScreenCast portal Start response
  int? _streamNodeId;

  // Whether we have a valid stream for absolute positioning
  bool get hasStream => _streamNodeId != null;

  // Screen size for coordinate conversion
  Size? _screenSize;



  // Request counter for unique request handles
  int _requestCounter = 0;

  // Sender name (used for request paths)
  String? _senderName;

  /// Initialize the portal connection
  Future<bool> initialize() async {
    if (_client != null) {
      hlog('Already initialized', source: 'Portal');
      return true;
    }

    if (!Platform.isLinux) {
      hlog('Portal only available on Linux', source: 'Portal');
      return false;
    }

    try {
      hlog('Connecting to session D-Bus...', source: 'Portal');
      _client = DBusClient.session();

      // Ping the D-Bus daemon to ensure connection is established
      // This triggers the Hello method and assigns our unique name
      final dbusObject = DBusRemoteObject(
        _client!,
        name: 'org.freedesktop.DBus',
        path: DBusObjectPath('/org/freedesktop/DBus'),
      );
      
      // Call GetId to verify connection is working
      try {
        await dbusObject.callMethod(
          'org.freedesktop.DBus',
          'GetId',
          [],
          replySignature: DBusSignature('s'),
        );
        hlog('D-Bus connection established', source: 'Portal');
      } catch (e) {
        hlog('D-Bus ping failed: $e', source: 'Portal');
      }

      _portal = DBusRemoteObject(
        _client!,
        name: 'org.freedesktop.portal.Desktop',
        path: DBusObjectPath('/org/freedesktop/portal/desktop'),
      );

      // Check if RemoteDesktop portal is available
      final version = await _getPortalVersion();
      hlog('RemoteDesktop portal version: $version', source: 'Portal');

      if (version == 0) {
        hlog('RemoteDesktop portal not available', source: 'Portal');
        return false;
      }

      // Now get our unique name for request paths (connection is established)
      final uniqueName = _client!.uniqueName;
      hlog('D-Bus unique name: "$uniqueName" (length: ${uniqueName.length})', source: 'Portal');
      
      if (uniqueName.isEmpty || uniqueName.length < 2) {
        hlog('D-Bus unique name is invalid, using fallback', source: 'Portal');
        _senderName = 'afk_${DateTime.now().millisecondsSinceEpoch}';
      } else {
        // Remove leading ':' and replace '.' with '_'
        // Unique name format is like ":1.123"
        _senderName = uniqueName.startsWith(':') 
            ? uniqueName.substring(1).replaceAll('.', '_')
            : uniqueName.replaceAll('.', '_');
      }
      hlog('D-Bus sender: $_senderName', source: 'Portal');

      return true;
    } catch (e, stackTrace) {
      hlog('Failed to initialize portal: $e', source: 'Portal');
      hlog('Stack trace: $stackTrace', source: 'Portal');
      _client?.close();
      _client = null;
      return false;
    }
  }

  /// Get the RemoteDesktop portal version
  Future<int> _getPortalVersion() async {
    try {
      final result = await _portal!.getProperty(
        'org.freedesktop.portal.RemoteDesktop',
        'version',
        signature: DBusSignature('u'),
      );
      return result.asUint32();
    } catch (e) {
      hlog('Failed to get portal version: $e', source: 'Portal');
      return 0;
    }
  }

  /// Start a new RemoteDesktop session
  /// This will show a permission dialog to the user on first run
  Future<bool> startSession() async {
    if (_state == PortalSessionState.active) {
      hlog('Session already active', source: 'Portal');
      return true;
    }

    if (_client == null) {
      final initialized = await initialize();
      if (!initialized) return false;
    }

    try {
      _state = PortalSessionState.creatingSession;

      // Step 1: Create session
      hlog('Creating RemoteDesktop session...', source: 'Portal');
      final sessionCreated = await _createSession();
      if (!sessionCreated) {
        _state = PortalSessionState.error;
        return false;
      }

      // Step 2: Select devices (keyboard + pointer)
      _state = PortalSessionState.selectingDevices;
      hlog('Selecting input devices...', source: 'Portal');
      final devicesSelected = await _selectDevices();
      if (!devicesSelected) {
        _state = PortalSessionState.error;
        return false;
      }

      // Step 2.5: Select ScreenCast sources (to get stream for absolute positioning)
      hlog('Selecting screen sources for absolute positioning...', source: 'Portal');
      final sourcesSelected = await _selectScreenCastSources();
      if (!sourcesSelected) {
        hlog('ScreenCast sources not selected, will use relative motion', source: 'Portal');
        // Continue anyway - we'll fall back to relative motion
      }

      // Step 3: Start the session (shows permission dialog if needed)
      _state = PortalSessionState.starting;
      hlog('Starting session (may show permission dialog)...', source: 'Portal');
      final started = await _startSession();
      if (!started) {
        _state = PortalSessionState.error;
        return false;
      }

      _state = PortalSessionState.active;
      hlog('RemoteDesktop session active', source: 'Portal');
      return true;
    } catch (e) {
      hlog('Failed to start session: $e', source: 'Portal');
      _state = PortalSessionState.error;
      return false;
    }
  }

  /// Wait for Response signal on a request
  Future<(int, Map<String, DBusValue>)> _waitForResponse(
    DBusObjectPath requestPath, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final completer = Completer<(int, Map<String, DBusValue>)>();

    // Subscribe to all signals and filter for Response
    final signalStream = DBusSignalStream(
      _client!,
      sender: 'org.freedesktop.portal.Desktop',
      interface: 'org.freedesktop.portal.Request',
      name: 'Response',
      path: requestPath,
    );

    StreamSubscription? subscription;
    Timer? timeoutTimer;

    subscription = signalStream.listen((signal) {
      timeoutTimer?.cancel();
      subscription?.cancel();

      if (signal.values.length >= 2) {
        final response = signal.values[0].asUint32();
        final results = signal.values[1].asStringVariantDict();
        completer.complete((response, results));
      } else {
        completer.complete((1, <String, DBusValue>{})); // Error response
      }
    });

    timeoutTimer = Timer(timeout, () {
      subscription?.cancel();
      if (!completer.isCompleted) {
        hlog('Response timeout for $requestPath', source: 'Portal');
        completer.complete((2, <String, DBusValue>{})); // Timeout response
      }
    });

    return completer.future;
  }

  /// Generate a unique request token
  String _generateRequestToken() {
    _requestCounter++;
    return 'afk_${DateTime.now().millisecondsSinceEpoch}_$_requestCounter';
  }

  /// Get request path for a token
  DBusObjectPath _getRequestPath(String token) {
    return DBusObjectPath('/org/freedesktop/portal/desktop/request/$_senderName/$token');
  }

  /// Create a new portal session
  Future<bool> _createSession() async {
    final token = _generateRequestToken();
    final sessionToken = 'afk_session_${DateTime.now().millisecondsSinceEpoch}';
    final requestPath = _getRequestPath(token);

    // Start listening for response before making the call
    final responseFuture = _waitForResponse(requestPath, timeout: const Duration(seconds: 10));

    try {
      final result = await _portal!.callMethod(
        'org.freedesktop.portal.RemoteDesktop',
        'CreateSession',
        [
          DBusDict.stringVariant({
            'handle_token': DBusString(token),
            'session_handle_token': DBusString(sessionToken),
          }),
        ],
        replySignature: DBusSignature('o'),
      );

      hlog('CreateSession called, request: ${result.values.first.asObjectPath()}', source: 'Portal');

      // Wait for response
      final (response, results) = await responseFuture;

      if (response == 0) {
        final sessionHandle = results['session_handle'];
        if (sessionHandle != null) {
          _sessionHandle = DBusObjectPath(sessionHandle.asString());
          hlog('Session created: $_sessionHandle', source: 'Portal');
          return true;
        } else {
          // Workaround: construct session handle ourselves if not returned
          _sessionHandle = DBusObjectPath('/org/freedesktop/portal/desktop/session/$_senderName/$sessionToken');
          hlog('Session created (constructed): $_sessionHandle', source: 'Portal');
          return true;
        }
      } else if (response == 2) {
        // Timeout - try constructing session handle anyway (workaround for buggy portal)
        hlog('CreateSession timed out, trying constructed session handle...', source: 'Portal');
        _sessionHandle = DBusObjectPath('/org/freedesktop/portal/desktop/session/$_senderName/$sessionToken');
        return true;
      } else {
        hlog('CreateSession failed with response: $response', source: 'Portal');
        return false;
      }
    } catch (e) {
      hlog('CreateSession error: $e', source: 'Portal');
      return false;
    }
  }

  /// Select input devices (keyboard + pointer)
  Future<bool> _selectDevices() async {
    if (_sessionHandle == null) {
      hlog('No session handle', source: 'Portal');
      return false;
    }

    final token = _generateRequestToken();
    final requestPath = _getRequestPath(token);

    final responseFuture = _waitForResponse(requestPath, timeout: const Duration(seconds: 10));

    try {
      // Device types: 1 = keyboard, 2 = pointer, 4 = touchscreen
      const deviceTypes = 1 | 2; // keyboard + pointer

      await _portal!.callMethod(
        'org.freedesktop.portal.RemoteDesktop',
        'SelectDevices',
        [
          _sessionHandle!,
          DBusDict.stringVariant({
            'handle_token': DBusString(token),
            'types': DBusUint32(deviceTypes),
          }),
        ],
        replySignature: DBusSignature('o'),
      );

      final (response, _) = await responseFuture;

      if (response == 0 || response == 2) {
        hlog('Devices selected (response: $response)', source: 'Portal');
        return true;
      } else {
        hlog('SelectDevices failed with response: $response', source: 'Portal');
        return false;
      }
    } catch (e) {
      hlog('SelectDevices error: $e', source: 'Portal');
      return false;
    }
  }

  /// Select ScreenCast sources (to get stream for absolute positioning)
  Future<bool> _selectScreenCastSources() async {
    if (_sessionHandle == null) {
      hlog('No session handle', source: 'Portal');
      return false;
    }

    final token = _generateRequestToken();
    final requestPath = _getRequestPath(token);

    final responseFuture = _waitForResponse(requestPath, timeout: const Duration(seconds: 30));

    try {
      // Source types: 1 = monitor, 2 = window, 4 = virtual
      const sourceTypes = 1; // Just monitor for now

      await _portal!.callMethod(
        'org.freedesktop.portal.ScreenCast',
        'SelectSources',
        [
          _sessionHandle!,
          DBusDict.stringVariant({
            'handle_token': DBusString(token),
            'types': DBusUint32(sourceTypes),
            'multiple': DBusBoolean(false), // Single source
          }),
        ],
        replySignature: DBusSignature('o'),
      );

      final (response, _) = await responseFuture;

      if (response == 0 || response == 2) {
        hlog('ScreenCast sources selected (response: $response)', source: 'Portal');
        return true;
      } else {
        hlog('SelectSources failed with response: $response', source: 'Portal');
        return false;
      }
    } catch (e) {
      hlog('SelectSources error: $e', source: 'Portal');
      return false;
    }
  }

  /// Start the session (shows permission dialog)
  Future<bool> _startSession() async {
    if (_sessionHandle == null) {
      hlog('No session handle', source: 'Portal');
      return false;
    }

    final token = _generateRequestToken();
    final requestPath = _getRequestPath(token);

    final responseFuture = _waitForResponse(requestPath, timeout: const Duration(seconds: 30));

    try {
      await _portal!.callMethod(
        'org.freedesktop.portal.RemoteDesktop',
        'Start',
        [
          _sessionHandle!,
          const DBusString(''), // parent_window (empty = no parent)
          DBusDict.stringVariant({
            'handle_token': DBusString(token),
          }),
        ],
        replySignature: DBusSignature('o'),
      );

      final (response, results) = await responseFuture;

      if (response == 0) {
        hlog('Session started successfully', source: 'Portal');

        // Extract stream node ID for absolute positioning
        _extractSessionInfo(results);

        return true;
      } else if (response == 1) {
        hlog('User cancelled the permission dialog', source: 'Portal');
        return false;
      } else if (response == 2) {
        // Timeout - the portal may have crashed, try anyway
        hlog('Start timed out, attempting to proceed anyway...', source: 'Portal');
        return true;
      } else {
        hlog('Start failed with response: $response', source: 'Portal');
        return false;
      }
    } catch (e) {
      hlog('Start error: $e', source: 'Portal');
      return false;
    }
  }

  /// Extract stream node ID from Start response
  void _extractSessionInfo(Map<String, DBusValue> results) {
    // Extract stream node ID for absolute positioning
    try {
      final streams = results['streams'];
      if (streams == null) {
        hlog('No streams in response', source: 'Portal');
        return;
      }

      // streams is an array of (node_id, properties)
      // Format: a(ua{sv})
      final streamArray = streams.asArray();
      if (streamArray.isEmpty) {
        hlog('Empty streams array', source: 'Portal');
        return;
      }

      // Get first stream
      final firstStream = streamArray.first.asStruct();
      if (firstStream.isNotEmpty) {
        _streamNodeId = firstStream[0].asUint32();
        hlog('Got stream node ID: $_streamNodeId', source: 'Portal');

        // Try to get stream properties (size, etc.)
        if (firstStream.length > 1) {
          final props = firstStream[1].asStringVariantDict();
          final size = props['size'];
          if (size != null) {
            final sizeStruct = size.asStruct();
            final width = sizeStruct[0].asInt32();
            final height = sizeStruct[1].asInt32();
            _screenSize = Size(width.toDouble(), height.toDouble());
            hlog('Stream size: ${_screenSize!.width}x${_screenSize!.height}', source: 'Portal');
          }
        }
      }
    } catch (e) {
      hlog('Failed to extract stream node ID: $e', source: 'Portal');
    }
  }

  // ============ Input Methods ============

  /// Set screen size for coordinate conversion
  void setScreenSize(Size size) {
    _screenSize = size;
    hlog('Screen size set to: ${size.width}x${size.height}', source: 'Portal');
  }

  /// Move pointer to normalized position (0-1 coordinates).
  /// Uses NotifyPointerMotionAbsolute with the portal stream node.
  Future<bool> notifyPointerMotionAbsolute(double x, double y) async {
    if (_state != PortalSessionState.active ||
        _sessionHandle == null ||
        _streamNodeId == null) {
      return false;
    }

    final w = _screenSize?.width ?? 1920;
    final h = _screenSize?.height ?? 1080;

    try {
      await _portal!.callMethod(
        'org.freedesktop.portal.RemoteDesktop',
        'NotifyPointerMotionAbsolute',
        [
          _sessionHandle!,
          DBusDict.stringVariant({}),
          DBusUint32(_streamNodeId!),
          DBusDouble(x * w),
          DBusDouble(y * h),
        ],
        replySignature: DBusSignature(''),
      );
      return true;
    } catch (e) {
      hlog('NotifyPointerMotionAbsolute failed: $e', source: 'Portal');
      return false;
    }
  }

  /// Notify pointer button press/release
  /// button: Linux button code (BTN_LEFT=272, BTN_RIGHT=273, BTN_MIDDLE=274)
  /// state: 0=released, 1=pressed
  Future<bool> notifyPointerButton(int button, int state) async {
    if (_state != PortalSessionState.active || _sessionHandle == null) {
      return false;
    }

    try {
      await _portal!.callMethod(
        'org.freedesktop.portal.RemoteDesktop',
        'NotifyPointerButton',
        [
          _sessionHandle!,
          DBusDict.stringVariant({}), // options
          DBusInt32(button),
          DBusUint32(state),
        ],
        replySignature: DBusSignature(''),
      );
      return true;
    } catch (e) {
      hlog('NotifyPointerButton failed: $e', source: 'Portal');
      return false;
    }
  }

  /// Notify pointer axis (scroll)
  Future<bool> notifyPointerAxis(double dx, double dy) async {
    if (_state != PortalSessionState.active || _sessionHandle == null) {
      return false;
    }

    try {
      await _portal!.callMethod(
        'org.freedesktop.portal.RemoteDesktop',
        'NotifyPointerAxis',
        [
          _sessionHandle!,
          DBusDict.stringVariant({
            'finish': DBusBoolean(true),
          }),
          DBusDouble(dx),
          DBusDouble(dy),
        ],
        replySignature: DBusSignature(''),
      );
      return true;
    } catch (e) {
      hlog('NotifyPointerAxis failed: $e', source: 'Portal');
      return false;
    }
  }

  /// Notify keyboard key press/release using keycode
  /// keycode: Linux evdev keycode
  /// state: 0=released, 1=pressed
  Future<bool> notifyKeyboardKeycode(int keycode, int state) async {
    if (_state != PortalSessionState.active || _sessionHandle == null) {
      return false;
    }

    try {
      await _portal!.callMethod(
        'org.freedesktop.portal.RemoteDesktop',
        'NotifyKeyboardKeycode',
        [
          _sessionHandle!,
          DBusDict.stringVariant({}), // options
          DBusInt32(keycode),
          DBusUint32(state),
        ],
        replySignature: DBusSignature(''),
      );
      return true;
    } catch (e) {
      hlog('NotifyKeyboardKeycode failed: $e', source: 'Portal');
      return false;
    }
  }

  /// Notify keyboard key press/release using keysym (X11)
  /// keysym: X11 keysym code
  /// state: 0=released, 1=pressed
  Future<bool> notifyKeyboardKeysym(int keysym, int state) async {
    if (_state != PortalSessionState.active || _sessionHandle == null) {
      return false;
    }

    try {
      await _portal!.callMethod(
        'org.freedesktop.portal.RemoteDesktop',
        'NotifyKeyboardKeysym',
        [
          _sessionHandle!,
          DBusDict.stringVariant({}), // options
          DBusInt32(keysym),
          DBusUint32(state),
        ],
        replySignature: DBusSignature(''),
      );
      return true;
    } catch (e) {
      hlog('NotifyKeyboardKeysym failed: $e', source: 'Portal');
      return false;
    }
  }

  /// Stop the session and cleanup
  Future<void> stopSession() async {
    hlog('Stopping RemoteDesktop session...', source: 'Portal');

    // Explicitly close the D-Bus session so KDE removes its screen-sharing
    // indicator immediately rather than waiting for connection drop detection.
    if (_sessionHandle != null && _client != null) {
      try {
        final sessionObj = DBusRemoteObject(
          _client!,
          name: 'org.freedesktop.portal.Desktop',
          path: _sessionHandle!,
        );
        await sessionObj.callMethod(
          'org.freedesktop.portal.Session',
          'Close',
          [],
          replySignature: DBusSignature(''),
        );
        hlog('Session closed on portal', source: 'Portal');
      } catch (e) {
        hlog('Session close error (ignored): $e', source: 'Portal');
      }
    }

    _sessionHandle = null;
    _state = PortalSessionState.disconnected;
    _streamNodeId = null;
    _screenSize = null;

    hlog('Session stopped', source: 'Portal');
  }

  /// Cleanup and close connection
  Future<void> dispose() async {
    await stopSession();

    _client?.close();
    _client = null;
    _portal = null;

    hlog('Portal disposed', source: 'Portal');
  }
}

// Linux button codes (from linux/input-event-codes.h)
class LinuxButtonCode {
  static const int left = 0x110;   // BTN_LEFT (272)
  static const int right = 0x111;  // BTN_RIGHT (273)
  static const int middle = 0x112; // BTN_MIDDLE (274)

  /// Convert button index (0=left, 1=right, 2=middle) to Linux code
  static int fromIndex(int index) {
    switch (index) {
      case 0:
        return left;
      case 1:
        return right;
      case 2:
        return middle;
      default:
        return left;
    }
  }
}
