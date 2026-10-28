/// Settings view for AFK Host.
/// Sidebar layout with General, Support, About sections.
/// Pairing is inline within the General section.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import '../theme/app_theme.dart';
import '../services/auto_update_service.dart';
import '../services/device_storage.dart';
import '../services/launch_at_login_service.dart';
import '../services/log_service.dart';
import '../services/pairing_service.dart';

class SettingsView extends StatefulWidget {
  final PairingService pairingService;
  final VoidCallback onPairingSuccess;

  const SettingsView({
    super.key,
    required this.pairingService,
    required this.onPairingSuccess,
  });

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  int _selectedIndex = 0;
  final _sections = const ['General', 'CLI', 'Support', 'About'];

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        // Sidebar
        _Sidebar(
          sections: _sections,
          selectedIndex: _selectedIndex,
          onSelect: (i) => setState(() => _selectedIndex = i),
        ),
        // Divider
        Container(width: 1, color: AppColors.separator),
        // Content
        Expanded(
          child: _buildContent(),
        ),
      ],
    );
  }

  Widget _buildContent() {
    switch (_selectedIndex) {
      case 0:
        return _GeneralSection(
          pairingService: widget.pairingService,
          onPairingSuccess: widget.onPairingSuccess,
        );
      case 1:
        return const _CliSection();
      case 2:
        return const _SupportSection();
      case 3:
        return const _AboutSection();
      default:
        return const SizedBox.shrink();
    }
  }
}

// ─────────────────────────────────────────────────────────────
// Sidebar
// ─────────────────────────────────────────────────────────────

class _Sidebar extends StatelessWidget {
  final List<String> sections;
  final int selectedIndex;
  final ValueChanged<int> onSelect;

  const _Sidebar({
    required this.sections,
    required this.selectedIndex,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 160,
      padding: const EdgeInsets.fromLTRB(12, 48, 12, 12), // Top padding for title bar
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < sections.length; i++)
            _SidebarItem(
              label: sections[i],
              icon: _iconFor(i),
              isSelected: i == selectedIndex,
              onTap: () => onSelect(i),
            ),
        ],
      ),
    );
  }

  IconData _iconFor(int index) {
    switch (index) {
      case 0: return Icons.devices;
      case 1: return Icons.terminal;
      case 2: return Icons.build_outlined;
      case 3: return Icons.info_outline;
      default: return Icons.circle;
    }
  }
}

class _SidebarItem extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool isSelected;
  final VoidCallback onTap;

  const _SidebarItem({
    required this.label,
    required this.icon,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        margin: const EdgeInsets.only(bottom: 2),
        decoration: BoxDecoration(
          color: isSelected ? AppColors.accent.withValues(alpha: 0.15) : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 16,
              color: isSelected ? AppColors.accent : AppColors.textSecondary,
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                color: isSelected ? AppColors.textPrimary : AppColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// General Section
// ─────────────────────────────────────────────────────────────

class _GeneralSection extends StatefulWidget {
  final PairingService pairingService;
  final VoidCallback onPairingSuccess;

  const _GeneralSection({
    required this.pairingService,
    required this.onPairingSuccess,
  });

  @override
  State<_GeneralSection> createState() => _GeneralSectionState();
}

class _GeneralSectionState extends State<_GeneralSection> {
  bool _isPairing = false;
  PairingState _pairingState = PairingState.idle;
  StreamSubscription<PairingState>? _subscription;
  bool _launchAtLoginSupported = false;
  bool _launchAtLogin = false;
  bool _responsiveStreaming = false;

  @override
  void initState() {
    super.initState();
    _loadLaunchAtLoginState();
    _loadStreamQuality();
  }

  Future<void> _loadLaunchAtLoginState() async {
    final supported = await LaunchAtLoginService.shared.isSupported();
    final enabled = supported ? await LaunchAtLoginService.shared.isEnabled() : false;
    if (mounted) {
      setState(() {
        _launchAtLoginSupported = supported;
        _launchAtLogin = enabled;
      });
    }
  }

  Future<void> _setLaunchAtLogin(bool enabled) async {
    final success = await LaunchAtLoginService.shared.setEnabled(enabled);
    if (success && mounted) {
      setState(() => _launchAtLogin = enabled);
    }
  }

  void _loadStreamQuality() {
    setState(() {
      _responsiveStreaming = DeviceStorage.shared.isResponsiveStreaming;
    });
  }

  Future<void> _setStreamQuality(bool responsive) async {
    await DeviceStorage.shared.setStreamQuality(responsive ? 2.0 : 1.0);
    setState(() => _responsiveStreaming = responsive);
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final clients = DeviceStorage.shared.getPairedClients();

    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 48, 24, 24), // Top padding for title bar
      children: [
        // Startup section (only shown if supported)
        if (_launchAtLoginSupported) ...[
          _SectionHeader(title: 'Startup'),
          const SizedBox(height: 8),
          _Card(
            children: [
              _CardRow(
                label: 'Launch at Login',
                trailing: Transform.scale(
                  scale: 0.7,
                  child: Switch.adaptive(
                    value: _launchAtLogin,
                    onChanged: _setLaunchAtLogin,
                    activeTrackColor: AppColors.accent,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
        ],
        // Streaming section
        _SectionHeader(title: 'Streaming'),
        const SizedBox(height: 8),
        _Card(
          children: [
            _CardRow(
              label: 'Responsive Mode',
              trailing: Transform.scale(
                scale: 0.7,
                child: Switch.adaptive(
                  value: _responsiveStreaming,
                  onChanged: _setStreamQuality,
                  activeTrackColor: AppColors.accent,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            _responsiveStreaming
                ? 'Streams at half resolution for faster response. Recommended for Retina displays.'
                : 'Full resolution for maximum sharpness. May be slower on some connections.',
            style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
          ),
        ),
        const SizedBox(height: 24),
        // Paired Devices section
        _SectionHeader(title: 'Paired Devices'),
        const SizedBox(height: 8),
        _Card(
          children: [
            // Status row
            _CardRow(
              label: 'Status',
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _StatusDot(isActive: clients.isNotEmpty),
                  const SizedBox(width: 6),
                  Text(
                    clients.isNotEmpty
                        ? '${clients.length} device${clients.length == 1 ? '' : 's'} paired'
                        : 'Not Paired',
                    style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
                  ),
                ],
              ),
            ),
            // Device list
            for (final client in clients) ...[
              const _CardDivider(),
              _DeviceRow(
                name: client.deviceName ?? 'iOS Device',
                date: client.pairedAt,
                onRemove: () => _removeDevice(client),
              ),
            ],
            // Pair button or pairing UI
            const _CardDivider(),
            if (_isPairing)
              _PairingContent(
                state: _pairingState,
                code: widget.pairingService.currentCode ?? '',
                error: widget.pairingService.errorMessage,
                onCancel: _cancelPairing,
                onRetry: _startPairing,
              )
            else
              _CardRow(
                onTap: _startPairing,
                child: const Text(
                  'Pair New Device...',
                  style: TextStyle(fontSize: 13, color: AppColors.accent),
                ),
              ),
          ],
        ),
      ],
    );
  }

  void _startPairing() {
    setState(() {
      _isPairing = true;
      _pairingState = PairingState.generating;
    });
    
    _subscription?.cancel();
    _subscription = widget.pairingService.startPairing().listen((state) {
      setState(() => _pairingState = state);
      
      if (state == PairingState.success) {
        widget.onPairingSuccess();
        // Auto-close pairing after short delay
        Future.delayed(const Duration(seconds: 1), () {
          if (mounted) {
            setState(() => _isPairing = false);
            widget.pairingService.reset();
          }
        });
      }
    });
  }

  void _cancelPairing() {
    _subscription?.cancel();
    widget.pairingService.cancelPairing();
    setState(() => _isPairing = false);
  }

  void _removeDevice(PairedClient client) async {
    await DeviceStorage.shared.clearPairedClients();
    setState(() {});
  }
}

class _PairingContent extends StatelessWidget {
  final PairingState state;
  final String code;
  final String? error;
  final VoidCallback onCancel;
  final VoidCallback onRetry;

  const _PairingContent({
    required this.state,
    required this.code,
    required this.error,
    required this.onCancel,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Column(
        children: [
          _buildContent(),
          const SizedBox(height: 16),
          _buildActions(),
        ],
      ),
    );
  }

  Widget _buildContent() {
    switch (state) {
      case PairingState.idle:
      case PairingState.generating:
        return const Column(
          children: [
            SizedBox(
              width: 20, height: 20,
              child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.textSecondary),
            ),
            SizedBox(height: 12),
            Text('Generating code...', style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
          ],
        );

      case PairingState.waitingForClient:
        final first = code.length >= 3 ? code.substring(0, 3) : code;
        final second = code.length >= 6 ? code.substring(3, 6) : '';
        return Column(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              decoration: BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(first, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold, letterSpacing: 2)),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8),
                    child: Text('–', style: TextStyle(fontSize: 28, color: AppColors.textSecondary)),
                  ),
                  Text(second, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold, letterSpacing: 2)),
                ],
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Enter this code on your iPhone',
              style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
            ),
          ],
        );

      case PairingState.success:
        return const Column(
          children: [
            Icon(Icons.check_circle, size: 32, color: AppColors.success),
            SizedBox(height: 8),
            Text('Paired!', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
          ],
        );

      case PairingState.error:
      case PairingState.timeout:
        return Column(
          children: [
            Icon(
              state == PairingState.timeout ? Icons.schedule : Icons.warning_amber_rounded,
              size: 32,
              color: state == PairingState.timeout ? AppColors.textSecondary : AppColors.warning,
            ),
            const SizedBox(height: 8),
            Text(
              state == PairingState.timeout ? 'Timed out' : (error ?? 'Failed'),
              style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
            ),
          ],
        );
    }
  }

  Widget _buildActions() {
    switch (state) {
      case PairingState.idle:
      case PairingState.generating:
      case PairingState.waitingForClient:
        return TextButton(onPressed: onCancel, child: const Text('Cancel'));
      case PairingState.success:
        return const SizedBox.shrink();
      case PairingState.error:
      case PairingState.timeout:
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TextButton(onPressed: onCancel, child: const Text('Cancel')),
            const SizedBox(width: 8),
            ElevatedButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        );
    }
  }
}

class _DeviceRow extends StatelessWidget {
  final String name;
  final DateTime date;
  final VoidCallback onRemove;

  const _DeviceRow({
    required this.name,
    required this.date,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: const TextStyle(fontSize: 13)),
                const SizedBox(height: 2),
                Text(
                  'Paired ${_formatDate(date)}',
                  style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
          GestureDetector(
            onTap: onRemove,
            child: const Icon(Icons.delete_outline, size: 16, color: AppColors.destructive),
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime date) {
    final months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${months[date.month - 1]} ${date.day}, ${date.year}';
  }
}

// ─────────────────────────────────────────────────────────────
// CLI Section
// ─────────────────────────────────────────────────────────────

class _CliSection extends StatefulWidget {
  const _CliSection();

  @override
  State<_CliSection> createState() => _CliSectionState();
}

class _CliSectionState extends State<_CliSection> {
  bool _isInstalled = false;
  String? _error;
  String? _command; // Command to show user for manual installation

  static const _channel = MethodChannel('app.afkdev.app_host');
  static const _cliTarget = '/usr/local/bin/afk';

  @override
  void initState() {
    super.initState();
    _refreshStatus();
  }

  // On Linux, find the CLI script bundled alongside the executable.
  // In a release bundle: <bundle>/cli/afk
  // In dev (flutter run): <project>/cli/afk
  String? _findLinuxCliSource() {
    final execDir = File(Platform.resolvedExecutable).parent;
    final candidates = [
      '${execDir.path}/cli/afk',
      '${execDir.parent.path}/cli/afk',
    ];
    for (final p in candidates) {
      if (File(p).existsSync()) return p;
    }
    return null;
  }

  bool _isCliInstalledLinux() {
    final link = File(_cliTarget);
    return link.existsSync();
  }

  Future<void> _refreshStatus() async {
    if (Platform.isLinux) {
      if (mounted) {
        setState(() {
          _isInstalled = _isCliInstalledLinux();
          if (_isInstalled) {
            _error = null;
            _command = null;
          }
        });
      }
      return;
    }
    try {
      final result = await _channel.invokeMethod<bool>('isCliInstalled');
      if (mounted) {
        setState(() {
          _isInstalled = result ?? false;
          if (_isInstalled) {
            _error = null;
            _command = null;
          }
        });
      }
    } catch (_) {}
  }

  Future<void> _install() async {
    if (Platform.isLinux) {
      if (_isCliInstalledLinux()) {
        if (mounted) setState(() { _isInstalled = true; _error = null; _command = null; });
        return;
      }
      final source = _findLinuxCliSource();
      if (source == null) {
        if (mounted) setState(() => _error = 'CLI not found in app bundle.');
        return;
      }
      try {
        await Link(_cliTarget).create(source);
        if (mounted) setState(() { _isInstalled = true; _error = null; _command = null; });
      } on FileSystemException {
        // Likely permission denied — show manual command
        if (mounted) {
          setState(() {
            _error = 'Permission denied. Run this command in Terminal:';
            _command = 'sudo ln -sf $source $_cliTarget';
          });
        }
      }
      return;
    }

    try {
      final alreadyInstalled = await _channel.invokeMethod<bool>('isCliInstalled') ?? false;
      if (alreadyInstalled) {
        if (mounted) setState(() { _isInstalled = true; _error = null; _command = null; });
        return;
      }
      final dynamic rawResult = await _channel.invokeMethod('installCLI');
      if (!mounted) return;
      final result = rawResult as Map<Object?, Object?>?;
      final success = result?['success'] as bool? ?? false;
      if (success) {
        setState(() { _isInstalled = true; _error = null; _command = null; });
      } else {
        final errorType = result?['errorType'] as String?;
        setState(() {
          _error = errorType == 'permission'
              ? 'Permission denied. Run this command in Terminal:'
              : result?['error'] as String? ?? 'Installation failed';
          _command = result?['command'] as String?;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _uninstall() async {
    if (Platform.isLinux) {
      try {
        await File(_cliTarget).delete();
        if (mounted) setState(() { _isInstalled = false; _error = null; _command = null; });
      } on FileSystemException {
        if (mounted) {
          setState(() {
            _error = 'Permission denied. Run this command in Terminal:';
            _command = 'sudo rm $_cliTarget';
          });
        }
      }
      return;
    }

    try {
      final dynamic rawResult = await _channel.invokeMethod('uninstallCLI');
      if (!mounted) return;
      final result = rawResult as Map<Object?, Object?>?;
      final success = result?['success'] as bool? ?? false;
      if (success) {
        setState(() { _isInstalled = false; _error = null; _command = null; });
      } else {
        final errorType = result?['errorType'] as String?;
        setState(() {
          _error = errorType == 'permission'
              ? 'Permission denied. Run this command in Terminal:'
              : result?['error'] as String? ?? 'Uninstall failed';
          _command = result?['command'] as String?;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  void _copyCommand() {
    if (_command != null) {
      Clipboard.setData(ClipboardData(text: _command!));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
      children: [
        // Installation
        _SectionHeader(title: 'Command Line Tool'),
        const SizedBox(height: 8),
        _Card(
          children: [
            _CardRow(
              label: 'Status',
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _StatusDot(isActive: _isInstalled),
                  const SizedBox(width: 6),
                  Text(
                    _isInstalled ? 'Installed' : 'Not Installed',
                    style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
                  ),
                ],
              ),
            ),
            const _CardDivider(),
            _CardRow(
              child: _isInstalled
                  ? OutlinedButton(
                      onPressed: _uninstall,
                      child: const Text('Uninstall'),
                    )
                  : ElevatedButton(
                      onPressed: _install,
                      style: ElevatedButton.styleFrom(backgroundColor: AppColors.accent),
                      child: const Text('Install'),
                    ),
            ),
          ],
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              _error!,
              style: const TextStyle(fontSize: 11, color: AppColors.destructive),
            ),
          ),
        ],
        if (_command != null) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.groupedBackground,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.separator),
            ),
            child: Row(
              children: [
                Expanded(
                  child: SelectableText(
                    _command!,
                    style: const TextStyle(
                      fontSize: 12,
                      fontFamily: 'monospace',
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.copy, size: 16),
                  onPressed: _copyCommand,
                  tooltip: 'Copy to clipboard',
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              'After running the command, click Install again to verify.',
              style: TextStyle(fontSize: 11, color: AppColors.textSecondary.withValues(alpha: 0.8)),
            ),
          ),
        ],
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            _isInstalled
                ? 'The afk command is available at /usr/local/bin/afk.'
                : 'Installs the afk command to /usr/local/bin so you can use it from any terminal.',
            style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
          ),
        ),

        const SizedBox(height: 28),

        // Getting Started
        _SectionHeader(title: 'Getting Started'),
        const SizedBox(height: 8),
        _Card(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Connect with your coding agent',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'The AFK CLI lets your coding agent (like Claude Code) send push notifications to your phone when it needs attention.',
                    style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Run this command in your terminal:',
                    style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppColors.background,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: AppColors.separator),
                    ),
                    child: SelectableText(
                      'afk setup',
                      style: TextStyle(
                        fontSize: 13,
                        fontFamily: 'SF Mono',
                        fontFamilyFallback: const ['Menlo', 'monospace'],
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'This walks you through connecting AFK to your agent\'s hook system. '
                    'Once set up, you\'ll get a notification on your phone whenever the agent needs your input.',
                    style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────
// Support Section
// ─────────────────────────────────────────────────────────────

class _SupportSection extends StatefulWidget {
  const _SupportSection();

  @override
  State<_SupportSection> createState() => _SupportSectionState();
}

class _SupportSectionState extends State<_SupportSection> {
  bool _copied = false;
  int _logSize = 0;

  @override
  void initState() {
    super.initState();
    _refreshLogSize();
  }

  Future<void> _refreshLogSize() async {
    final size = await LogService.shared.getLogSize();
    if (mounted) setState(() => _logSize = size);
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) {
      return '$bytes B';
    } else if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    } else {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
      children: [
        _SectionHeader(title: 'Diagnostic Logs'),
        const SizedBox(height: 8),
        _Card(
          children: [
            _CardRow(
              label: 'Log Size',
              trailing: Text(
                _formatBytes(_logSize),
                style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
              ),
            ),
            const _CardDivider(),
            _CardRow(
              child: Row(
                children: [
                  OutlinedButton(
                    onPressed: _copyLogs,
                    child: Text(_copied ? 'Copied!' : 'Copy Logs'),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: _clearLogs,
                    child: const Text('Clear'),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        const Text(
          'Copy logs to share with the developer for troubleshooting.',
          style: TextStyle(fontSize: 11, color: AppColors.textSecondary),
        ),

        const SizedBox(height: 28),

        // Feedback
        _SectionHeader(title: 'Feedback'),
        const SizedBox(height: 8),
        _Card(
          children: [
            _CardRow(
              onTap: () => launchUrl(Uri.parse('https://app.youform.com/forms/t3xgvtxk')),
              child: const Row(
                children: [
                  Icon(Icons.feedback_outlined, size: 16, color: AppColors.accent),
                  SizedBox(width: 8),
                  Text(
                    'Send Feedback',
                    style: TextStyle(fontSize: 13, color: AppColors.accent),
                  ),
                  Spacer(),
                  Icon(Icons.open_in_new, size: 14, color: AppColors.textSecondary),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            'Report bugs, request features, or share your thoughts.',
            style: TextStyle(fontSize: 11, color: AppColors.textSecondary),
          ),
        ),
      ],
    );
  }

  Future<void> _copyLogs() async {
    await LogService.shared.copyToClipboard();
    setState(() => _copied = true);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  Future<void> _clearLogs() async {
    await LogService.shared.clearLogs();
    await Future.delayed(const Duration(milliseconds: 500));
    _refreshLogSize();
  }
}

// ─────────────────────────────────────────────────────────────
// About Section
// ─────────────────────────────────────────────────────────────

class _AboutSection extends StatefulWidget {
  const _AboutSection();

  @override
  State<_AboutSection> createState() => _AboutSectionState();
}

class _AboutSectionState extends State<_AboutSection> {
  bool _checking = false;
  String _version = '';

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    final info = await PackageInfo.fromPlatform();
    if (mounted) {
      setState(() => _version = 'Version ${info.version} (${info.buildNumber})');
    }
  }

  Future<void> _checkForUpdates() async {
    setState(() => _checking = true);
    await AutoUpdateService.shared.checkForUpdates();
    // Small delay to show feedback
    await Future.delayed(const Duration(milliseconds: 500));
    if (mounted) setState(() => _checking = false);
  }

  @override
  Widget build(BuildContext context) {
    final showUpdateButton = AutoUpdateService.shared.isSupported;

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // App icon
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Image.asset(
              'assets/app_icon.png',
              width: 64,
              height: 64,
            ),
          ),
          const SizedBox(height: 16),
          const Text('AFK Host', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(_version, style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
          const SizedBox(height: 4),
          const Text('Remote desktop for mobile', style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
          const SizedBox(height: 20),
          if (showUpdateButton)
            OutlinedButton(
              onPressed: _checking ? null : _checkForUpdates,
              child: _checking
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Check for Updates...'),
            ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// Shared Widgets
// ─────────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Text(
      title.toUpperCase(),
      style: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w500,
        color: AppColors.textSecondary,
        letterSpacing: 0.5,
      ),
    );
  }
}

class _Card extends StatelessWidget {
  final List<Widget> children;
  const _Card({required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.groupedBackground,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(children: children),
    );
  }
}

class _CardRow extends StatelessWidget {
  final String? label;
  final Widget? trailing;
  final Widget? child;
  final VoidCallback? onTap;

  const _CardRow({this.label, this.trailing, this.child, this.onTap});

  @override
  Widget build(BuildContext context) {
    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: child ?? Row(
        children: [
          if (label != null) Text(label!, style: const TextStyle(fontSize: 13)),
          const Spacer(),
          if (trailing != null) trailing!,
        ],
      ),
    );

    if (onTap != null) {
      return GestureDetector(onTap: onTap, behavior: HitTestBehavior.opaque, child: content);
    }
    return content;
  }
}

class _CardDivider extends StatelessWidget {
  const _CardDivider();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.only(left: 12),
      child: Divider(height: 1, thickness: 0.5),
    );
  }
}

class _StatusDot extends StatelessWidget {
  final bool isActive;
  const _StatusDot({required this.isActive});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: isActive ? AppColors.success : AppColors.textSecondary,
      ),
    );
  }
}
