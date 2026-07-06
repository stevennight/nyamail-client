import 'dart:io';

class StartupService {
  const StartupService();

  String get platformLabel {
    if (Platform.isWindows) return 'Windows Run registry';
    if (Platform.isMacOS) return 'macOS LaunchAgent';
    if (Platform.isLinux) return 'XDG autostart';
    return 'Not supported on this platform';
  }

  bool get isSupported {
    return Platform.isWindows || Platform.isMacOS || Platform.isLinux;
  }

  Future<bool> isEnabled() async {
    if (Platform.isWindows) return _isEnabledWindows();
    if (Platform.isMacOS) return _launchAgentFile().exists();
    if (Platform.isLinux) return _linuxDesktopFile().exists();
    return false;
  }

  Future<void> setEnabled(bool enabled) async {
    if (!isSupported) {
      throw const StartupServiceException(
        'Launch at startup is not supported on this platform.',
      );
    }
    if (Platform.isWindows) {
      await _setEnabledWindows(enabled);
      return;
    }
    if (Platform.isMacOS) {
      await _setEnabledMacOS(enabled);
      return;
    }
    if (Platform.isLinux) {
      await _setEnabledLinux(enabled);
    }
  }

  Future<bool> _isEnabledWindows() async {
    final result = await Process.run('reg', [
      'query',
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run',
      '/v',
      'NyaMail',
    ]);
    return result.exitCode == 0 && '${result.stdout}'.contains('NyaMail');
  }

  Future<void> _setEnabledWindows(bool enabled) async {
    final args =
        enabled
            ? [
              'add',
              r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run',
              '/v',
              'NyaMail',
              '/t',
              'REG_SZ',
              '/d',
              '"${Platform.resolvedExecutable}"',
              '/f',
            ]
            : [
              'delete',
              r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run',
              '/v',
              'NyaMail',
              '/f',
            ];
    final result = await Process.run('reg', args);
    if (result.exitCode != 0 && enabled) {
      throw StartupServiceException('${result.stderr}'.trim());
    }
  }

  Future<void> _setEnabledMacOS(bool enabled) async {
    final file = _launchAgentFile();
    if (!enabled) {
      if (await file.exists()) await file.delete();
      return;
    }
    await file.parent.create(recursive: true);
    await file.writeAsString(_macOSLaunchAgent(), flush: true);
  }

  Future<void> _setEnabledLinux(bool enabled) async {
    final file = _linuxDesktopFile();
    if (!enabled) {
      if (await file.exists()) await file.delete();
      return;
    }
    await file.parent.create(recursive: true);
    await file.writeAsString(_linuxDesktopEntry(), flush: true);
  }

  File _launchAgentFile() {
    return File('${_homeDirectory()}/Library/LaunchAgents/app.nyamail.plist');
  }

  File _linuxDesktopFile() {
    final configHome =
        Platform.environment['XDG_CONFIG_HOME'] ??
        '${_homeDirectory()}/.config';
    return File('$configHome/autostart/nyamail.desktop');
  }

  String _homeDirectory() {
    return Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        Directory.current.path;
  }

  String _macOSLaunchAgent() {
    final executable = _xmlEscape(Platform.resolvedExecutable);
    return '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>app.nyamail</string>
  <key>ProgramArguments</key>
  <array>
    <string>$executable</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
</dict>
</plist>
''';
  }

  String _linuxDesktopEntry() {
    final executable = Platform.resolvedExecutable.replaceAll('"', r'\"');
    return '''[Desktop Entry]
Type=Application
Name=NyaMail
Exec="$executable"
Terminal=false
X-GNOME-Autostart-enabled=true
''';
  }

  String _xmlEscape(String value) {
    return value
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;');
  }
}

class StartupServiceException implements Exception {
  const StartupServiceException(this.message);

  final String message;

  @override
  String toString() => message;
}
