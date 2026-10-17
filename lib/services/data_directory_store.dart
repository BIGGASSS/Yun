import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

/// The startup migration's commit record, independent of platform preferences.
abstract interface class DataDirectoryStore {
  /// Returns null only if no configuration exists. Existing malformed or
  /// unreadable content must not be treated as a first launch.
  Future<String?> read();

  /// Completes only after committing the entire value. On failure the previous
  /// value must remain intact; observable controller state changes only after
  /// this future succeeds.
  Future<void> write(String value);
}

/// A standalone configuration in system application support, never relocated
/// with the managed data. Readers see either the old or the new complete value.
/// Writes flush a unique same-directory temporary file before atomic rename;
/// they never delete the previous configuration first. Process termination is
/// recoverable, but directory fsync and full power-loss durability are not
/// portable guarantees of dart:io. Startup still requires a single app process.
final class FileDataDirectoryStore implements DataDirectoryStore {
  FileDataDirectoryStore({
    Future<Directory> Function()? applicationSupportDirectory,
  }) : _applicationSupportDirectory =
           applicationSupportDirectory ?? getApplicationSupportDirectory;

  static const fileName = '.yun-data-config.json';
  final Future<Directory> Function() _applicationSupportDirectory;

  Future<File> _file() async {
    final root = await _applicationSupportDirectory();
    await root.create(recursive: true);
    return File(p.join(root.path, fileName));
  }

  @override
  Future<String?> read() async {
    final file = await _file();
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.file) {
      throw FileSystemException(
        'Configuration is not a regular file',
        file.path,
      );
    }
    // Preserve even empty/malformed content. type() also reports notFound for
    // permission/IO errors, so only an actual missing-file read is first launch.
    try {
      return await file.readAsString();
    } on PathNotFoundException {
      if (type == FileSystemEntityType.notFound) return null;
      rethrow;
    }
  }

  @override
  Future<void> write(String value) async {
    final file = await _file();
    final temporary = File('${file.path}-${const Uuid().v4()}.tmp');
    // Exclusive creation ensures cleanup cannot remove another writer's file.
    await temporary.create(exclusive: true);
    var installed = false;
    try {
      await temporary.writeAsString(value, flush: true);
      await temporary.rename(file.path);
      installed = true;
    } finally {
      if (!installed) {
        try {
          await temporary.delete();
        } on FileSystemException {
          // Keep the original write failure. A leftover reserved temp is inert;
          // never sweep other writes' (or interrupted processes') temp files.
        }
      }
      // Nothing fallible may run after successful rename: a reported failure
      // would make migration roll back a configuration that already committed.
    }
  }
}
