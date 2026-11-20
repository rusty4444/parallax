// The Windows build must not depend on the VC++ runtime installed on the
// user's machine. A build from MSVC 14.40+ crashed on a laptop with
// msvcp140.dll 14.36 the moment a video was played: std::mutex is
// constexpr-constructed since 14.40, and the old runtime's lock reads a null
// pointer (seen in a minidump: video_player_win_plugin -> msvcp140 AV).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final cmake = File('windows/CMakeLists.txt').readAsStringSync();

  String standardSettings() {
    final start = cmake.indexOf('function(APPLY_STANDARD_SETTINGS TARGET)');
    final end = cmake.indexOf('endfunction()', start);
    expect(start, isNonNegative);
    expect(end, greaterThan(start));
    return cmake.substring(start, end);
  }

  test('plugins and the runner keep the pre-14.40 std::mutex layout', () {
    // APPLY_STANDARD_SETTINGS is what every plugin target (including
    // video_player_win) and the runner call.
    expect(
      standardSettings(),
      contains('"_DISABLE_CONSTEXPR_MUTEX_CONSTRUCTOR"'),
    );
  });

  test('the MSVC runtime ships next to parallax.exe', () {
    expect(cmake, contains('include(InstallRequiredSystemLibraries)'));
    expect(cmake, contains('set(CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS_SKIP TRUE)'));
    final install = RegExp(
      r'install\(PROGRAMS \$\{CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS\}\s+'
      r'DESTINATION "\$\{INSTALL_BUNDLE_LIB_DIR\}"',
    );
    expect(install.hasMatch(cmake), isTrue);
  });
}
