/// Input service for injecting mouse and keyboard events via native platform code.
/// Uses method channels on macOS/Windows, and xdg-desktop-portal on Linux.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'log_service.dart';

// Linux input handler - only actually used when Platform.isLinux
import 'linux/linux_input_handler.dart';

/// Input service that handles mouse/keyboard injection via platform channels.
class InputService {
  static const _channel = MethodChannel('app.afkdev.input_injection');

  // Singleton instance
  static final InputService shared = InputService._();

  InputService._();

  // Callback for sending data channel messages back to client
  void Function(Map<String, dynamic>)? sendDataChannelMessage;

  // Rate limiting: max events per second
  static const _maxEventsPerSecond = 120;
  final List<DateTime> _eventTimestamps = [];

  // Max paste text length to prevent abuse
  static const _maxPasteLength = 4096;

  /// Check rate limit. Returns true if the event should be allowed.
  bool _checkRateLimit() {
    final now = DateTime.now();
    final cutoff = now.subtract(const Duration(seconds: 1));
    _eventTimestamps.removeWhere((t) => t.isBefore(cutoff));

    if (_eventTimestamps.length >= _maxEventsPerSecond) {
      hlog('Rate limit exceeded ($_maxEventsPerSecond events/s)', source: 'Input');
      return false;
    }
    _eventTimestamps.add(now);
    return true;
  }

  /// Process incoming data channel message containing input events.
  /// Returns true if the message was handled.
  Future<bool> processDataChannelMessage(String message) async {
    if (!_checkRateLimit()) return false;

    try {
      final json = jsonDecode(message) as Map<String, dynamic>;
      final type = json['type'] as String?;
      final data = json['data'] as Map<String, dynamic>? ?? {};

      if (type == null) {
        hlog('Message missing type field', source: 'Input');
        return false;
      }

      return await processInputEvent(type: type, data: data);
    } catch (e) {
      hlog('Failed to parse message: $e', source: 'Input');
      return false;
    }
  }

  /// Process input event with type and data dictionary.
  Future<bool> processInputEvent({
    required String type,
    required Map<String, dynamic> data,
  }) async {
    switch (type) {
      case 'cursor_button':
        final x = (data['x'] as num?)?.toDouble();
        final y = (data['y'] as num?)?.toDouble();
        final button = data['button'] as String?;
        final action = data['action'] as String?;
        if (x == null || y == null || button == null || action == null) {
          hlog('Invalid cursor_button data format', source: 'Input');
          return false;
        }
        return await processCursorButton(
          x: x,
          y: y,
          button: button,
          action: action,
        );

      case 'cursor_move':
        final x = (data['x'] as num?)?.toDouble();
        final y = (data['y'] as num?)?.toDouble();
        if (x == null || y == null) {
          hlog('Invalid cursor_move data format', source: 'Input');
          return false;
        }
        return await mouseMove(x: x, y: y);

      case 'cursor_scroll':
        final x = (data['x'] as num?)?.toDouble();
        final y = (data['y'] as num?)?.toDouble();
        final deltaX = (data['deltaX'] as num?)?.toDouble();
        final deltaY = (data['deltaY'] as num?)?.toDouble();
        if (x == null || y == null || deltaX == null || deltaY == null) {
          hlog('Invalid cursor_scroll data format', source: 'Input');
          return false;
        }
        return await scroll(x: x, y: y, deltaX: deltaX, deltaY: deltaY);

      case 'key_input':
        final keyCode = data['keyCode'] as int?;
        final keyType = data['type'] as String?;
        final character = data['character'] as String?;
        if (keyCode == null || keyType == null) {
          hlog('Invalid key_input data format', source: 'Input');
          return false;
        }
        return await processKeyInput(
          keyCode: keyCode,
          type: keyType,
          character: character,
        );

      case 'voice_input':
        final text = data['text'] as String?;
        if (text == null || text.isEmpty) {
          hlog('Invalid voice_input data format', source: 'Input');
          return false;
        }
        if (text.length > _maxPasteLength) {
          hlog('voice_input text too long (${text.length} > $_maxPasteLength)', source: 'Input');
          return false;
        }
        return await pasteText(text);

      case 'clipboard_paste':
        final text = data['text'] as String?;
        if (text == null || text.isEmpty) {
          hlog('Invalid clipboard_paste data format', source: 'Input');
          return false;
        }
        if (text.length > _maxPasteLength) {
          hlog('clipboard_paste text too long (${text.length} > $_maxPasteLength)', source: 'Input');
          return false;
        }
        return await pasteText(text);

      // Legacy message types for backwards compatibility
      case 'input_touch':
        final x = (data['x'] as num?)?.toDouble();
        final y = (data['y'] as num?)?.toDouble();
        final touchType = data['type'] as String?;
        if (x == null || y == null || touchType == null) {
          hlog('Invalid input_touch data format', source: 'Input');
          return false;
        }
        return await processTouchInput(x: x, y: y, type: touchType);

      case 'input_scroll':
        final x = (data['x'] as num?)?.toDouble();
        final y = (data['y'] as num?)?.toDouble();
        final deltaX = (data['deltaX'] as num?)?.toDouble();
        final deltaY = (data['deltaY'] as num?)?.toDouble();
        if (x == null || y == null || deltaX == null || deltaY == null) {
          hlog('Invalid input_scroll data format', source: 'Input');
          return false;
        }
        return await scroll(x: x, y: y, deltaX: deltaX, deltaY: deltaY);

      default:
        hlog('Unknown input event type: $type', source: 'Input');
        return false;
    }
  }

  /// Process cursor button input (used by cursor_button message type).
  Future<bool> processCursorButton({
    required double x,
    required double y,
    required String button,
    required String action,
  }) async {
    switch (button) {
      case 'left':
        switch (action) {
          case 'down':
            return await mouseDown(x: x, y: y, button: 0);
          case 'up':
            return await mouseUp(x: x, y: y, button: 0);
          case 'double_click':
            return await doubleClick(x: x, y: y);
          default:
            hlog('Unknown left button action: $action', source: 'Input');
            return false;
        }
      case 'right':
        switch (action) {
          case 'down':
            return await mouseDown(x: x, y: y, button: 1);
          case 'up':
            return await mouseUp(x: x, y: y, button: 1);
          default:
            hlog('Unknown right button action: $action', source: 'Input');
            return false;
        }
      default:
        hlog('Unknown button: $button', source: 'Input');
        return false;
    }
  }

  /// Process legacy touch input format.
  Future<bool> processTouchInput({
    required double x,
    required double y,
    required String type,
  }) async {
    switch (type) {
      case 'down':
        return await mouseDown(x: x, y: y, button: 0);
      case 'up':
        return await mouseUp(x: x, y: y, button: 0);
      case 'move':
        return await mouseMove(x: x, y: y);
      case 'double_click':
        return await doubleClick(x: x, y: y);
      case 'right_down':
        return await mouseDown(x: x, y: y, button: 1);
      case 'right_up':
        return await mouseUp(x: x, y: y, button: 1);
      default:
        hlog('Unknown touch type: $type', source: 'Input');
        return false;
    }
  }

  /// Process key input with X11 keysym code.
  Future<bool> processKeyInput({
    required int keyCode,
    required String type,
    String? character,
  }) async {
    switch (type) {
      case 'down':
        return await keyDown(keyCode: keyCode);
      case 'up':
        return await keyUp(keyCode: keyCode);
      case 'press':
        return await keyPress(keyCode: keyCode, character: character);
      default:
        hlog('Unknown key type: $type', source: 'Input');
        return false;
    }
  }

  // ============ Platform Channel Methods ============

  /// Move mouse to position (normalized 0-1 coordinates).
  Future<bool> mouseMove({required double x, required double y}) async {
    if (!Platform.isMacOS && !Platform.isWindows && !Platform.isLinux) {
      hlog('Input injection not supported on this platform', source: 'Input');
      return false;
    }

    // Use Linux handler on Linux
    if (Platform.isLinux) {
      return await LinuxInputHandler.shared.mouseMove(x: x, y: y);
    }

    try {
      final result = await _channel.invokeMethod<bool>('mouseMove', {
        'x': x,
        'y': y,
      });
      return result ?? false;
    } on PlatformException catch (e) {
      hlog('mouseMove failed: ${e.message}', source: 'Input');
      return false;
    }
  }

  /// Mouse button down (button: 0=left, 1=right, 2=middle).
  Future<bool> mouseDown({
    required double x,
    required double y,
    required int button,
  }) async {
    if (!Platform.isMacOS && !Platform.isWindows && !Platform.isLinux) {
      hlog('Input injection not supported on this platform', source: 'Input');
      return false;
    }

    // Use Linux handler on Linux
    if (Platform.isLinux) {
      return await LinuxInputHandler.shared.mouseDown(x: x, y: y, button: button);
    }

    try {
      final result = await _channel.invokeMethod<bool>('mouseDown', {
        'x': x,
        'y': y,
        'button': button,
      });
      return result ?? false;
    } on PlatformException catch (e) {
      hlog('mouseDown failed: ${e.message}', source: 'Input');
      return false;
    }
  }

  /// Mouse button up (button: 0=left, 1=right, 2=middle).
  Future<bool> mouseUp({
    required double x,
    required double y,
    required int button,
  }) async {
    if (!Platform.isMacOS && !Platform.isWindows && !Platform.isLinux) {
      hlog('Input injection not supported on this platform', source: 'Input');
      return false;
    }

    // Use Linux handler on Linux
    if (Platform.isLinux) {
      return await LinuxInputHandler.shared.mouseUp(x: x, y: y, button: button);
    }

    try {
      final result = await _channel.invokeMethod<bool>('mouseUp', {
        'x': x,
        'y': y,
        'button': button,
      });
      return result ?? false;
    } on PlatformException catch (e) {
      hlog('mouseUp failed: ${e.message}', source: 'Input');
      return false;
    }
  }

  /// Double-click at position.
  Future<bool> doubleClick({required double x, required double y}) async {
    if (!Platform.isMacOS && !Platform.isWindows && !Platform.isLinux) {
      hlog('Input injection not supported on this platform', source: 'Input');
      return false;
    }

    // Use Linux handler on Linux
    if (Platform.isLinux) {
      return await LinuxInputHandler.shared.doubleClick(x: x, y: y);
    }

    try {
      final result = await _channel.invokeMethod<bool>('doubleClick', {
        'x': x,
        'y': y,
      });
      return result ?? false;
    } on PlatformException catch (e) {
      hlog('doubleClick failed: ${e.message}', source: 'Input');
      return false;
    }
  }

  /// Scroll at position.
  Future<bool> scroll({
    required double x,
    required double y,
    required double deltaX,
    required double deltaY,
  }) async {
    if (!Platform.isMacOS && !Platform.isWindows && !Platform.isLinux) {
      hlog('Input injection not supported on this platform', source: 'Input');
      return false;
    }

    // Use Linux handler on Linux
    if (Platform.isLinux) {
      return await LinuxInputHandler.shared.scroll(x: x, y: y, deltaX: deltaX, deltaY: deltaY);
    }

    try {
      final result = await _channel.invokeMethod<bool>('scroll', {
        'x': x,
        'y': y,
        'deltaX': deltaX,
        'deltaY': deltaY,
      });
      return result ?? false;
    } on PlatformException catch (e) {
      hlog('scroll failed: ${e.message}', source: 'Input');
      return false;
    }
  }

  /// Key down (X11 keysym code).
  Future<bool> keyDown({required int keyCode}) async {
    if (!Platform.isMacOS && !Platform.isWindows && !Platform.isLinux) {
      hlog('Input injection not supported on this platform', source: 'Input');
      return false;
    }

    // Use Linux handler on Linux
    if (Platform.isLinux) {
      return await LinuxInputHandler.shared.keyDown(keyCode: keyCode);
    }

    try {
      final result = await _channel.invokeMethod<bool>('keyDown', {
        'keyCode': keyCode,
      });
      return result ?? false;
    } on PlatformException catch (e) {
      hlog('keyDown failed: ${e.message}', source: 'Input');
      return false;
    }
  }

  /// Key up (X11 keysym code).
  Future<bool> keyUp({required int keyCode}) async {
    if (!Platform.isMacOS && !Platform.isWindows && !Platform.isLinux) {
      hlog('Input injection not supported on this platform', source: 'Input');
      return false;
    }

    // Use Linux handler on Linux
    if (Platform.isLinux) {
      return await LinuxInputHandler.shared.keyUp(keyCode: keyCode);
    }

    try {
      final result = await _channel.invokeMethod<bool>('keyUp', {
        'keyCode': keyCode,
      });
      return result ?? false;
    } on PlatformException catch (e) {
      hlog('keyUp failed: ${e.message}', source: 'Input');
      return false;
    }
  }

  /// Key press (down + up, with optional character for Unicode override).
  Future<bool> keyPress({required int keyCode, String? character}) async {
    if (!Platform.isMacOS && !Platform.isWindows && !Platform.isLinux) {
      hlog('Input injection not supported on this platform', source: 'Input');
      return false;
    }

    // Use Linux handler on Linux
    if (Platform.isLinux) {
      return await LinuxInputHandler.shared.keyPress(keyCode: keyCode, character: character);
    }

    try {
      final result = await _channel.invokeMethod<bool>('keyPress', {
        'keyCode': keyCode,
        if (character != null) 'character': character,
      });
      return result ?? false;
    } on PlatformException catch (e) {
      hlog('keyPress failed: ${e.message}', source: 'Input');
      return false;
    }
  }

  /// Paste text via clipboard and Cmd+V.
  Future<bool> pasteText(String text) async {
    if (!Platform.isMacOS && !Platform.isWindows && !Platform.isLinux) {
      hlog('Input injection not supported on this platform', source: 'Input');
      return false;
    }

    // Use Linux handler on Linux
    if (Platform.isLinux) {
      return await LinuxInputHandler.shared.pasteText(text);
    }

    try {
      final result = await _channel.invokeMethod<bool>('pasteText', {
        'text': text,
      });
      return result ?? false;
    } on PlatformException catch (e) {
      hlog('pasteText failed: ${e.message}', source: 'Input');
      return false;
    }
  }

  /// Check if accessibility permissions are granted (macOS only).
  Future<bool> checkAccessibilityPermissions() async {
    if (!Platform.isMacOS) {
      return true; // Other platforms don't need explicit accessibility permission
    }

    try {
      final result = await _channel.invokeMethod<bool>('checkAccessibility');
      return result ?? false;
    } on PlatformException catch (e) {
      hlog('checkAccessibility failed: ${e.message}', source: 'Input');
      return false;
    }
  }

  /// Request accessibility permissions (macOS only, opens System Preferences).
  Future<void> requestAccessibilityPermissions() async {
    if (!Platform.isMacOS) return;

    try {
      await _channel.invokeMethod<void>('requestAccessibility');
    } on PlatformException catch (e) {
      hlog('requestAccessibility failed: ${e.message}', source: 'Input');
    }
  }
}
