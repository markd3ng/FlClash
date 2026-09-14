import 'dart:io';
import 'package:setup_hooks/src/build.dart';
import 'package:setup_hooks/src/target.dart';
import 'package:test/test.dart';

void main() {
  bool goAvailable;
  try {
    goAvailable = Process.runSync('go', ['version']).exitCode == 0;
  } on ProcessException {
    goAvailable = false;
  }
  test(
    'real Go build caches, detects new source files and excludes build trees from hook dependencies',
    () async {
      final root = Directory.systemTemp.createTempSync('flclash-go-build-');
      addTearDown(() => root.deleteSync(recursive: true));
      final core = Directory('${root.path}/core')..createSync();
      File('${root.path}/pubspec.yaml').writeAsStringSync('name: fixture\n');
      File(
        '${core.path}/go.mod',
      ).writeAsStringSync('module example.invalid/fixture\n\ngo 1.23\n');
      File(
        '${core.path}/main.go',
      ).writeAsStringSync('package main\nfunc main() {}\n');
      final request = BuildRequest(
        rootDir: root.path,
        target: Target.macosArm64,
        includeHelper: false,
      );
      final first = await buildPlatform(request);
      expect(first.rebuilt, isTrue);
      expect(File(first.outputs.single).existsSync(), isTrue);
      expect(first.inputs, contains(core.path));
      expect(first.inputs, isNot(contains(root.path)));
      expect(first.inputs, isNot(contains('${root.path}/.dart_tool')));
      expect((await buildPlatform(request)).rebuilt, isFalse);
      final added = File('${core.path}/extra.go')
        ..writeAsStringSync('package main\nconst extra = 1\n');
      final changed = await buildPlatform(request);
      expect(changed.rebuilt, isTrue);
      expect(changed.inputs, contains(added.path));
      File(changed.outputs.single).deleteSync();
      expect((await buildPlatform(request)).rebuilt, isTrue);
    },
    skip: !goAvailable,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
