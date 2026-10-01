import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

const _excludedDirectories = {
  '.git',
  '.dart_tool',
  '.pub-cache',
  '.pub',
  '.fvm',
  'build',
  'node_modules',
};

/// A missing or ambiguous server prevents an automatic scan.
final class ServerDiscoveryException implements Exception {
  ServerDiscoveryException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Finds the enclosing server, or the unique server in the enclosing project.
///
/// Git roots and Dart workspaces bound project searches. Without either marker,
/// sibling Dart packages identify a project root. Filesystem roots, the user's
/// home, and the system temporary directory are never searched as projects.
Directory discoverServer(Directory startingDirectory) {
  final start = Directory(startingDirectory.resolveSymbolicLinksSync());
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  final boundaries = {
    if (home != null) p.normalize(p.absolute(home)),
    p.normalize(Directory.systemTemp.resolveSymbolicLinksSync()),
  };
  final pubspecs = <String, Map?>{};

  Map? pubspec(Directory directory) => pubspecs.putIfAbsent(directory.path, () {
    final file = File(p.join(directory.path, 'pubspec.yaml'));
    if (!file.existsSync()) return null;
    try {
      final document = loadYaml(file.readAsStringSync());
      return document is Map ? document : null;
    } on YamlException catch (error) {
      throw ServerDiscoveryException('Cannot read ${file.path}: $error');
    }
  });

  bool isServer(Directory directory) {
    final dependencies = pubspec(directory)?['dependencies'];
    return dependencies is Map && dependencies.containsKey('serverpod');
  }

  List<Directory> children(Directory directory) {
    final result = directory
        .listSync(followLinks: false)
        .whereType<Directory>()
        .where(
          (child) => !_excludedDirectories.contains(p.basename(child.path)),
        )
        .toList();
    result.sort((a, b) => a.path.compareTo(b.path));
    return result;
  }

  Directory? project;
  Directory? package;
  final ancestors = <Directory>[];
  for (var directory = start; ; directory = directory.parent) {
    if (directory.parent.path == directory.path ||
        boundaries.contains(directory.path)) {
      break;
    }
    ancestors.add(directory);
    final spec = pubspec(directory);
    // Being inside a server is unambiguous even when its project has siblings.
    if (isServer(directory)) return directory;
    if (spec != null) package ??= directory;
    if (FileSystemEntity.typeSync(p.join(directory.path, '.git')) !=
            FileSystemEntityType.notFound ||
        spec?['workspace'] is List) {
      project = directory;
      break;
    }
  }

  if (project == null && package != null) {
    final parent = package.parent;
    project =
        ancestors.any((directory) => directory.path == parent.path) &&
            children(parent).any(isServer)
        ? parent
        : package;
  }
  if (project == null) {
    for (final directory in ancestors) {
      if (children(directory).any(isServer)) {
        project = directory;
        break;
      }
    }
  }

  final servers = <Directory>[];
  void search(Directory directory) {
    if (isServer(directory)) servers.add(directory);
    for (final child in children(directory)) {
      search(child);
    }
  }

  // A directory with no project marker can itself contain nested packages.
  // Never fall back to recursively searching a filesystem/home/temp root.
  if (ancestors.isNotEmpty) search(project ?? start);
  if (servers.length == 1) return servers.single;
  if (servers.isEmpty) {
    throw ServerDiscoveryException(
      'No Serverpod server found in ${project?.path ?? start.path}. '
      'Use --root=/path/to/server. Server packages must declare serverpod '
      'under dependencies in pubspec.yaml.',
    );
  }
  servers.sort((a, b) => a.path.compareTo(b.path));
  throw ServerDiscoveryException(
    'Multiple Serverpod servers found:\n'
    '${servers.map((server) => '  ${server.path}').join('\n')}\n'
    'Choose one with --root=/path/to/server.',
  );
}

/// Explicit roots and positional paths bypass server discovery.
Directory resolveScanRoot({
  required Directory currentDirectory,
  String? explicitRoot,
  bool hasPaths = false,
}) {
  if (explicitRoot != null) {
    final directory = Directory(
      p.normalize(p.join(currentDirectory.path, explicitRoot)),
    );
    if (explicitRoot.isEmpty || !directory.existsSync()) {
      throw ServerDiscoveryException(
        '--root must name an existing directory: $explicitRoot',
      );
    }
    return directory;
  }
  return hasPaths ? currentDirectory : discoverServer(currentDirectory);
}
