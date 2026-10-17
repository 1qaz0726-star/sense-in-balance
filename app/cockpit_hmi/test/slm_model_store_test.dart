import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cockpit_hmi/slm_model_store.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  late SlmModelStore store;
  final originalBytes = utf8.encode('existing original remains untouched');
  final candidate = utf8.encode('new student format bytes');

  SlmModelManifest manifest(List<int> content, {String id = 'student-v3'}) =>
      SlmModelManifest(
        id: id,
        label: 'Experimental student',
        source: 'local-conversion',
        sourceRevision: 'converter-commit-and-merge-sha',
        sha256Hex: sha256.convert(content).toString(),
        bytes: content.length,
      );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('cockpit-model-slots-');
    store = SlmModelStore(root);
    await File('${root.path}/model.litertlm').writeAsBytes(originalBytes);
  });
  tearDown(() async => root.delete(recursive: true));

  test('original identity is revision pinned and preserves legacy path', () {
    expect(
      kOriginalSlmManifest.source,
      contains(kOriginalSlmManifest.sourceRevision),
    );
    expect(kOriginalSlmManifest.source, isNot(contains('/main/')));
    expect(kOriginalSlmManifest.bytes, 1597931520);
    expect(
      store.modelFile(kOriginalSlmManifest).path,
      '${root.path}/model.litertlm',
    );
  });

  test('built-in V3 cannot be rebound to another file or label', () {
    expect(
      SlmModelManifest.fromJson(kCabinV3SlmManifest.toJson()).sha256Hex,
      kCabinV3SlmManifest.sha256Hex,
    );
    for (final key in ['sha256', 'bytes', 'label', 'source_revision']) {
      final rebound = kCabinV3SlmManifest.toJson();
      rebound[key] = key == 'bytes'
          ? 32
          : (key == 'sha256' ? 'a' * 64 : 'other');
      expect(() => SlmModelManifest.fromJson(rebound), throwsFormatException);
    }
  });

  test(
    'versioned import verifies bytes/SHA and keeps original and sibling versions',
    () async {
      final v3 = manifest(candidate);
      final v4 = manifest(utf8.encode('other student'), id: 'student-v4');
      final file = await store.importStream(v3, Stream.value(candidate));
      final other = await store.importStream(
        v4,
        Stream.value(utf8.encode('other student')),
      );
      expect(await file.readAsBytes(), candidate);
      expect(await other.readAsString(), 'other student');
      expect(
        await File('${root.path}/model.litertlm').readAsBytes(),
        originalBytes,
      );
      expect(file.path, contains('/student-v3/student-v3.litertlm'));
      expect(
        (await store.manifests()).map((m) => m.id),
        containsAll([kOriginalSlmManifest.id, 'student-v3', 'student-v4']),
      );
    },
  );

  test(
    'equal-length corrupted import fails SHA and never installs candidate',
    () async {
      final m = manifest(candidate);
      final corrupt = List<int>.of(candidate)..[0] ^= 1;
      await expectLater(
        store.importStream(m, Stream.value(corrupt)),
        throwsA(isA<FileSystemException>()),
      );
      expect(await store.modelFile(m).exists(), false);
      expect(
        await File('${root.path}/model.litertlm').readAsBytes(),
        originalBytes,
      );
    },
  );

  test('truncated/oversized streams cannot be accepted as a model', () async {
    final m = manifest(candidate);
    await expectLater(
      store.importStream(m, Stream.value(candidate.sublist(1))),
      throwsA(isA<FileSystemException>()),
    );
    await expectLater(
      store.importStream(m, Stream.value([...candidate, 0])),
      throwsFormatException,
    );
    expect(await store.modelFile(m).exists(), false);
  });

  test('existing version cannot be rebound or overwritten', () async {
    final m = manifest(candidate);
    final file = await store.importStream(m, Stream.value(candidate));
    final replacement = manifest(utf8.encode('replacement'), id: m.id);
    await expectLater(
      store.importStream(replacement, Stream.value(utf8.encode('replacement'))),
      throwsStateError,
    );
    expect(await file.readAsBytes(), candidate);
    // Re-importing identical verified bytes is idempotent.
    expect((await store.importStream(m, const Stream.empty())).path, file.path);
  });

  test(
    'concurrent registration across store instances reserves one identity',
    () async {
      final a = manifest(candidate);
      final b = manifest(utf8.encode('different candidate'), id: a.id);
      final alias = SlmModelStore(Directory('${root.path}/.'));
      Future<Object?> outcome(Future<void> work) async {
        try {
          await work;
          return null;
        } catch (error) {
          return error;
        }
      }

      final results = await Future.wait([
        outcome(store.register(a)),
        outcome(alias.register(b)),
      ]);
      expect(results.where((result) => result == null), hasLength(1));
      expect(results.whereType<StateError>(), hasLength(1));
      final registered = (await store.manifests()).singleWhere(
        (item) => item.id == a.id,
      );
      final winner = results.first == null ? a : b;
      expect(registered.toJson(), winner.toJson());
      expect(
        await File('${root.path}/model.litertlm').readAsBytes(),
        originalBytes,
      );
    },
  );

  test(
    'simultaneous identical imports consume one stream and share one slot',
    () async {
      final m = manifest(candidate);
      var streamsConsumed = 0;
      final files = await Future.wait(
        List.generate(12, (index) {
          final anotherStore = SlmModelStore(Directory('${root.path}/.'));
          final stream = Stream.value(candidate).map((bytes) {
            streamsConsumed++;
            return bytes;
          });
          return anotherStore.importStream(m, stream);
        }),
      );
      expect(streamsConsumed, 1);
      expect(files.map((file) => file.path).toSet(), hasLength(1));
      expect(await files.first.readAsBytes(), candidate);
      final leftovers = await files.first.parent.list().toList();
      expect(
        leftovers.whereType<Directory>().where(
          (dir) =>
              dir.path.contains('.import-') || dir.path.contains('.manifest-'),
        ),
        isEmpty,
      );
    },
  );

  test(
    'conflicting import waits for in-flight reservation and cannot replace it',
    () async {
      final a = manifest(candidate);
      final replacementBytes = utf8.encode('replacement while busy');
      final b = manifest(replacementBytes, id: a.id);
      final stream = StreamController<List<int>>();
      final started = Completer<void>();
      final first = store.importStream(
        a,
        stream.stream,
        onProgress: (_) {
          if (!started.isCompleted) started.complete();
        },
      );
      stream.add(candidate.sublist(0, 1));
      await started.future;
      var secondCompleted = false;
      final second = SlmModelStore(Directory('${root.path}/.'))
          .importStream(b, Stream.value(replacementBytes))
          .then<Object?>(
            (file) {
              secondCompleted = true;
              return file;
            },
            onError: (Object error) {
              secondCompleted = true;
              return error;
            },
          );
      await Future<void>.value();
      expect(secondCompleted, false);
      stream.add(candidate.sublist(1));
      await stream.close();
      final installed = await first;
      expect(await second, isA<StateError>());
      expect(await installed.readAsBytes(), candidate);
      final registered = (await store.manifests()).singleWhere(
        (item) => item.id == a.id,
      );
      expect(registered.sha256Hex, a.sha256Hex);
      expect(
        await File('${root.path}/model.litertlm').readAsBytes(),
        originalBytes,
      );
    },
  );

  test(
    'failed concurrent import releases slot lock for a valid retry',
    () async {
      final m = manifest(candidate);
      final corrupt = List<int>.of(candidate)..[0] ^= 1;
      final stream = StreamController<List<int>>();
      final started = Completer<void>();
      final bad = store.importStream(
        m,
        stream.stream,
        onProgress: (_) {
          if (!started.isCompleted) started.complete();
        },
      );
      final rejected = expectLater(bad, throwsA(isA<FileSystemException>()));
      stream.add(corrupt.sublist(0, 1));
      await started.future;
      final good = SlmModelStore(
        Directory('${root.path}/.'),
      ).importStream(m, Stream.value(candidate));
      stream.add(corrupt.sublist(1));
      await stream.close();
      await rejected;
      expect(await (await good).readAsBytes(), candidate);
    },
  );

  test(
    'already-installed corruption is detected and never silently replaced',
    () async {
      final m = manifest(candidate);
      final file = await store.importStream(m, Stream.value(candidate));
      final corrupt = List<int>.of(candidate)..[0] ^= 1;
      await file.writeAsBytes(corrupt);
      await expectLater(
        store.verify(file, m),
        throwsA(isA<FileSystemException>()),
      );
      await expectLater(
        store.importStream(m, Stream.value(candidate)),
        throwsA(isA<FileSystemException>()),
      );
      expect(await file.readAsBytes(), corrupt);
    },
  );

  test(
    'manifest rejects traversal, missing hash, incorrect engine type, and original redefinition',
    () {
      final valid = manifest(candidate).toJson();
      for (final invalid in [
        {...valid, 'id': '../model'},
        {...valid, 'sha256': ''},
        {...valid, 'sha256': '0' * 64},
        {...valid, 'bytes': -1},
        {...valid, 'model_type': 'gemmaIt'},
        {...valid, 'file_type': 'binary'},
        {...valid, 'format': 'gguf'},
        {...valid, 'path': '../../model.litertlm'},
        {...valid, 'id': kOriginalSlmManifest.id},
      ]) {
        expect(() => SlmModelManifest.fromJson(invalid), throwsFormatException);
      }
    },
  );
}
