import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// Model identity is independent of the inference engine's active-model cache.
/// A manifest identifies exact bytes; a display name or extension is not proof.
class SlmModelManifest {
  const SlmModelManifest({
    required this.id,
    required this.label,
    required this.source,
    required this.sourceRevision,
    required this.sha256Hex,
    required this.bytes,
  });

  final String id;
  final String label;
  final String source;
  final String sourceRevision;
  final String sha256Hex;
  final int bytes;

  factory SlmModelManifest.fromJson(Map<String, dynamic> json) {
    const keys = {
      'schema_version',
      'id',
      'label',
      'source',
      'source_revision',
      'sha256',
      'bytes',
      'model_type',
      'file_type',
      'format',
    };
    if (json.length != keys.length ||
        !json.keys.every(keys.contains) ||
        json['schema_version'] != 1 ||
        json['model_type'] != 'qwen' ||
        json['file_type'] != 'task' ||
        json['format'] != 'litertlm') {
      throw const FormatException(
        '只接受 version 1 的 Qwen / task / litertlm manifest',
      );
    }
    for (final key in ['id', 'label', 'source', 'source_revision', 'sha256']) {
      if (json[key] is! String || (json[key] as String).trim().isEmpty) {
        throw FormatException('manifest 缺少 $key');
      }
    }
    if (json['bytes'] is! int ||
        (json['bytes'] as int) <= 0 ||
        !RegExp(r'^[a-z0-9][a-z0-9_-]{0,79}$').hasMatch(json['id'] as String) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(json['sha256'] as String) ||
        RegExp(r'^0+$').hasMatch(json['sha256'] as String)) {
      throw const FormatException('manifest 的 ID、大小或 SHA256 不合法');
    }
    final manifest = SlmModelManifest(
      id: json['id'] as String,
      label: json['label'] as String,
      source: json['source'] as String,
      sourceRevision: json['source_revision'] as String,
      sha256Hex: json['sha256'] as String,
      bytes: json['bytes'] as int,
    );
    if (manifest.id == kOriginalSlmManifest.id &&
        jsonEncode(manifest.toJson()) !=
            jsonEncode(kOriginalSlmManifest.toJson())) {
      throw const FormatException('原版模型的 manifest 不得被重新定義');
    }
    if (manifest.id == kCabinV3SlmManifest.id &&
        jsonEncode(manifest.toJson()) !=
            jsonEncode(kCabinV3SlmManifest.toJson())) {
      throw const FormatException('內建 V3 模型的 manifest 不得被重新定義');
    }
    return manifest;
  }

  Map<String, dynamic> toJson() => {
    'schema_version': 1,
    'id': id,
    'label': label,
    'source': source,
    'source_revision': sourceRevision,
    'sha256': sha256Hex,
    'bytes': bytes,
    'model_type': 'qwen',
    'file_type': 'task',
    'format': 'litertlm',
  };
}

const kOriginalSlmManifest = SlmModelManifest(
  id: 'qwen25-15b-original-q8',
  label: '原版 Qwen2.5-1.5B Q8',
  source:
      'https://huggingface.co/litert-community/Qwen2.5-1.5B-Instruct/resolve/'
      '19edb84c69a0212f29a6ef17ba0d6f278b6a1614/'
      'Qwen2.5-1.5B-Instruct_multi-prefill-seq_q8_ekv4096.litertlm',
  sourceRevision: '19edb84c69a0212f29a6ef17ba0d6f278b6a1614',
  sha256Hex: 'faa60663b333290c1496c499828b21d3e3254a788cacd8cce917ce0f761a2dc9',
  bytes: 1597931520,
);

/// Local, trained repair parser. These exact bytes remain separate from base.
const kCabinV3SlmManifest = SlmModelManifest(
  id: 'qwen25-15b-v3-clean-q8-c2048',
  label: 'V3 實驗 Qwen2.5-1.5B Q8 / 2048',
  source:
      'Qwen/Qwen2.5-1.5B-Instruct + clean V3 LoRA; local litert-torch0.9.4 conversion',
  sourceRevision:
      'cabin-v3-clean-android-user;adapter_sha256=3477069956dda08ddfe3b5110f96834a6b0ab4d5528899d0ad010f6798efa42a',
  sha256Hex: 'abc57627d87b529328541e5a2194209fab641f3aa17de3c2a31376cc39de9702',
  bytes: 1823647040,
);

/// A complete verified download is published locally; incomplete bytes can
/// resume, while rejected bytes remain in a separate inspection directory.
class SlmDownloadPartState {
  const SlmDownloadPartState({
    required this.resumableBytes,
    this.installedFile,
    this.quarantinedPart,
  });

  final int resumableBytes;
  final File? installedFile;
  final File? quarantinedPart;
}

/// No method replaces an installed file. Failed candidates leave existing
/// versions intact, and the original keeps its pre-existing Android path.
class SlmModelStore {
  SlmModelStore(this.root);
  final Directory root;

  // Stores created by different callers still share the same version lock.
  // Resolve aliases before choosing the key; a second Store(root/.) must not
  // bypass identity reservation while the first one is importing bytes.
  static final Map<String, Future<void>> _versionQueues = {};

  Future<T> _withVersionLock<T>(
    SlmModelManifest manifest,
    Future<T> Function() operation,
  ) async {
    SlmModelManifest.fromJson(manifest.toJson());
    await root.create(recursive: true);
    final canonical = await root.resolveSymbolicLinks();
    final key =
        '${Platform.isWindows ? canonical.toLowerCase() : canonical}'
        '/${manifest.id}';
    final previous = _versionQueues[key];
    final completed = Completer<void>();
    _versionQueues[key] = completed.future;
    try {
      await previous;
      final directory = Directory('${root.path}/models/${manifest.id}');
      await directory.create(recursive: true);
      // The queue handles every current App caller in this isolate. The OS
      // lock also coordinates cooperating processes. POSIX locks are process
      // scoped: future background isolates must route writes through this
      // owner isolate instead of assuming a second isolate has its own lock.
      final lock = await File(
        '${directory.path}/.slot.lock',
      ).open(mode: FileMode.append);
      try {
        await lock.lock(FileLock.blockingExclusive);
        try {
          return await operation();
        } finally {
          await lock.unlock();
        }
      } finally {
        await lock.close();
      }
    } finally {
      completed.complete();
      if (identical(_versionQueues[key], completed.future)) {
        _versionQueues.remove(key);
      }
    }
  }

  File modelFile(SlmModelManifest manifest) {
    // Validate even manifests constructed programmatically.
    SlmModelManifest.fromJson(manifest.toJson());
    if (manifest.id == kOriginalSlmManifest.id) {
      return File('${root.path}/model.litertlm');
    }
    return File('${root.path}/models/${manifest.id}/${manifest.id}.litertlm');
  }

  File _manifestFile(SlmModelManifest manifest) =>
      File('${root.path}/models/${manifest.id}/manifest.json');

  Future<void> verify(File file, SlmModelManifest manifest) async {
    SlmModelManifest.fromJson(manifest.toJson());
    if (!await file.exists() || await file.length() != manifest.bytes) {
      throw FileSystemException(
        '模型大小不符（應為 ${manifest.bytes} bytes）',
        file.path,
      );
    }
    final actual = (await sha256.bind(file.openRead()).first).toString();
    if (actual != manifest.sha256Hex) {
      throw FileSystemException('模型 SHA256 不符，未載入且保留既有版本', file.path);
    }
  }

  Future<void> register(SlmModelManifest manifest) =>
      _withVersionLock(manifest, () => _registerLocked(manifest));

  /// Recover only the version's download .part file. Publishing uses the same
  /// lock as imports, so a concurrent import cannot be replaced by a rename.
  /// No HTTP request is needed for a complete, correctly hashed .part file.
  Future<SlmDownloadPartState> prepareDownloadPart(SlmModelManifest manifest) =>
      _withVersionLock(manifest, () async {
        final destination = modelFile(manifest);
        if (await destination.exists()) {
          await verify(destination, manifest);
          return SlmDownloadPartState(
            resumableBytes: manifest.bytes,
            installedFile: destination,
          );
        }
        final part = File('${destination.path}.part');
        if (!await part.exists()) {
          return const SlmDownloadPartState(resumableBytes: 0);
        }
        final length = await part.length();
        if (length < manifest.bytes) {
          return SlmDownloadPartState(resumableBytes: length);
        }
        if (length == manifest.bytes) {
          // I/O failures propagate unchanged. Only an actual size/hash
          // mismatch quarantines bytes; a failed read is not a bad checksum.
          final actual = (await sha256.bind(part.openRead()).first).toString();
          if (actual == manifest.sha256Hex) {
            await _registerLocked(manifest);
            final installed = await part.rename(destination.path);
            return SlmDownloadPartState(
              resumableBytes: manifest.bytes,
              installedFile: installed,
            );
          }
        }
        // createTemp reserves a unique directory. A prior rejected download
        // is never overwritten, even when attempts share a clock tick.
        final archive = await part.parent.createTemp('rejected-download-');
        final rejected = await part.rename(
          '${archive.path}/${part.uri.pathSegments.last}',
        );
        return SlmDownloadPartState(
          resumableBytes: 0,
          quarantinedPart: rejected,
        );
      });

  Future<void> _registerLocked(SlmModelManifest manifest) async {
    final file = _manifestFile(manifest);
    SlmModelManifest.fromJson(manifest.toJson());
    if (await file.exists()) {
      final previous = SlmModelManifest.fromJson(
        jsonDecode(await file.readAsString()) as Map<String, dynamic>,
      );
      if (jsonEncode(previous.toJson()) != jsonEncode(manifest.toJson())) {
        throw StateError('同一模型 ID 不得對應不同檔案；請建立新的版本 ID');
      }
      return;
    }
    // Publish a complete manifest atomically, so readers cannot observe a
    // partially written JSON document. createTemp supplies unique names even
    // when several operations start within the same clock tick.
    final temporary = await file.parent.createTemp('.manifest-');
    final candidate = File('${temporary.path}/manifest.json');
    try {
      await candidate.writeAsString(jsonEncode(manifest.toJson()), flush: true);
      if (await file.exists()) {
        throw StateError('版本已被建立，未覆寫既有 manifest');
      }
      await candidate.rename(file.path);
    } finally {
      if (await candidate.exists()) await candidate.delete();
      await temporary.delete();
    }
  }

  Future<List<SlmModelManifest>> manifests() async {
    final result = <SlmModelManifest>[kOriginalSlmManifest];
    final directory = Directory('${root.path}/models');
    if (!await directory.exists()) return result;
    await for (final entry in directory.list(followLinks: false)) {
      if (entry is! Directory) continue;
      final file = File('${entry.path}/manifest.json');
      if (!await file.exists()) continue;
      final manifest = SlmModelManifest.fromJson(
        jsonDecode(await file.readAsString()) as Map<String, dynamic>,
      );
      if (manifest.id != kOriginalSlmManifest.id) result.add(manifest);
    }
    return result;
  }

  Future<File> importStream(
    SlmModelManifest manifest,
    Stream<List<int>> stream, {
    void Function(int bytes)? onProgress,
  }) => _withVersionLock(
    manifest,
    () => _importLocked(manifest, stream, onProgress: onProgress),
  );

  Future<File> _importLocked(
    SlmModelManifest manifest,
    Stream<List<int>> stream, {
    void Function(int bytes)? onProgress,
  }) async {
    await _registerLocked(manifest);
    final destination = modelFile(manifest);
    if (await destination.exists()) {
      await verify(destination, manifest);
      return destination;
    }
    await destination.parent.create(recursive: true);
    final temporary = await destination.parent.createTemp('.import-');
    final candidate = File('${temporary.path}/model.litertlm');
    IOSink? sink = candidate.openWrite();
    var count = 0;
    try {
      await for (final chunk in stream) {
        count += chunk.length;
        if (count > manifest.bytes) {
          throw const FormatException('匯入超過 manifest 大小');
        }
        sink.add(chunk);
        onProgress?.call(count);
      }
      await sink.flush();
      await sink.close();
      sink = null;
      await verify(candidate, manifest);
      if (await destination.exists()) {
        // Preserve a version installed while this candidate was being copied.
        await verify(destination, manifest);
        await candidate.delete();
        return destination;
      }
      return await candidate.rename(destination.path);
    } finally {
      await sink?.close();
      if (await candidate.exists()) await candidate.delete();
      await temporary.delete();
    }
  }
}
