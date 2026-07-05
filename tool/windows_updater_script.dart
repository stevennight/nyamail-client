import 'dart:io';

import 'package:nyamail/src/release/windows_updater.dart';

void main(List<String> args) {
  final options = _parseArgs(args);
  final zipPath = options['zip'];
  final installRoot = options['install-root'];
  final currentExe = options['current-exe'];
  if (zipPath == null || installRoot == null || currentExe == null) {
    stderr.writeln(
      'Usage: dart run tool/windows_updater_script.dart '
      '--zip <path> --install-root <path> --current-exe <path>',
    );
    exitCode = 64;
    return;
  }

  stdout.write(
    windowsUpdaterScript(
      zipPath: zipPath,
      installRoot: installRoot,
      currentExe: currentExe,
    ),
  );
}

Map<String, String> _parseArgs(List<String> args) {
  final values = <String, String>{};
  for (var index = 0; index < args.length; index += 1) {
    final arg = args[index];
    if (!arg.startsWith('--')) continue;
    final key = arg.substring(2);
    if (index + 1 >= args.length || args[index + 1].startsWith('--')) {
      stderr.writeln('Missing value for --$key');
      exitCode = 64;
      return values;
    }
    values[key] = args[index + 1];
    index += 1;
  }
  return values;
}
