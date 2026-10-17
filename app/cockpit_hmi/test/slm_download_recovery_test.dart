import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cockpit_hmi/slm_model_store.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  late SlmModelStore store;
  late SlmModelManifest manifest;
  late File destination;
  late File part;
  final bytes = utf8.encode('verified test model bytes');
  final original = utf8.encode('original installed model stays untouched');

  setUp(() async {
    root = await Directory.systemTemp.createTemp('cockpit-download-recovery-');
    store = SlmModelStore(root);
    manifest = SlmModelManifest(
      id: 'download-recovery-fixture',
      label: 'Tiny download integrity fixture',
      source: 'local-test-no-network',
      sourceRevision: 'fixture-only',
      sha256Hex: sha256.convert(bytes).toString(),
      bytes: bytes.length,
    );
    destination = store.modelFile(manifest);
    await destination.parent.create(recursive: true);
    part = File('${destination.path}.part');
    await File('${root.path}/model.litertlm').writeAsBytes(original);
  });

  tearDown(() async {
    expect(await File('${root.path}/model.litertlm').readAsBytes(), original);
    await root.delete(recursive: true);
  });

  test('missing partial starts at zero without publishing a model', () async {
    final state = await store.prepareDownloadPart(manifest);
    expect(state.resumableBytes, 0);
    expect(state.installedFile, isNull);
    expect(state.quarantinedPart, isNull);
    expect(await destination.exists(), false);
  });

  test('incomplete bytes remain available for a valid Range resume', () async {
    final incomplete = bytes.sublist(0, 8);
    await part.writeAsBytes(incomplete);
    final state = await store.prepareDownloadPart(manifest);
    expect(state.resumableBytes, incomplete.length);
    expect(state.installedFile, isNull);
    expect(state.quarantinedPart, isNull);
    expect(await part.readAsBytes(), incomplete);
    expect(await destination.exists(), false);
  });

  test(
    'a complete valid partial is published before any HTTP is needed',
    () async {
      await part.writeAsBytes(bytes);
      final state = await store.prepareDownloadPart(manifest);
      expect(state.resumableBytes, bytes.length);
      expect(state.installedFile?.path, destination.path);
      expect(state.quarantinedPart, isNull);
      expect(await destination.readAsBytes(), bytes);
      expect(await part.exists(), false);
    },
  );

  test(
    'same-length checksum failure is archived and next attempt starts at zero',
    () async {
      final corrupt = List<int>.of(bytes)..[0] ^= 1;
      await part.writeAsBytes(corrupt);
      final rejected = await store.prepareDownloadPart(manifest);
      expect(rejected.resumableBytes, 0);
      expect(rejected.installedFile, isNull);
      expect(await rejected.quarantinedPart!.readAsBytes(), corrupt);
      expect(await part.exists(), false);
      expect(await destination.exists(), false);

      final retry = await store.prepareDownloadPart(manifest);
      expect(retry.resumableBytes, 0);
      expect(retry.quarantinedPart, isNull);
      await part.writeAsBytes(bytes);
      final recovered = await store.prepareDownloadPart(manifest);
      expect(await recovered.installedFile!.readAsBytes(), bytes);
      expect(await rejected.quarantinedPart!.readAsBytes(), corrupt);
    },
  );

  test('oversized rejected attempts retain separate archives', () async {
    final firstBytes = [...bytes, 1];
    final secondBytes = [...bytes, 2, 3];
    await part.writeAsBytes(firstBytes);
    final first = await store.prepareDownloadPart(manifest);
    await part.writeAsBytes(secondBytes);
    final second = await store.prepareDownloadPart(manifest);
    expect(first.resumableBytes, 0);
    expect(second.resumableBytes, 0);
    expect(first.quarantinedPart!.path, isNot(second.quarantinedPart!.path));
    expect(await first.quarantinedPart!.readAsBytes(), firstBytes);
    expect(await second.quarantinedPart!.readAsBytes(), secondBytes);
    expect(await destination.exists(), false);
  });

  test(
    'an installed version wins without replacing it or its remaining partial',
    () async {
      await store.importStream(manifest, Stream.value(bytes));
      final leftover = List<int>.of(bytes)..[0] ^= 1;
      await part.writeAsBytes(leftover);
      final state = await store.prepareDownloadPart(manifest);
      expect(state.installedFile?.path, destination.path);
      expect(await destination.readAsBytes(), bytes);
      expect(await part.readAsBytes(), leftover);
      expect(state.quarantinedPart, isNull);
    },
  );

  test(
    'a corrupted installed file is reported and never replaced from partial',
    () async {
      final corruptedInstalled = List<int>.of(bytes)..[0] ^= 1;
      await destination.writeAsBytes(corruptedInstalled);
      await part.writeAsBytes(bytes);
      await expectLater(
        store.prepareDownloadPart(manifest),
        throwsA(isA<FileSystemException>()),
      );
      expect(await destination.readAsBytes(), corruptedInstalled);
      expect(await part.readAsBytes(), bytes);
    },
  );

  test(
    'recovery waits for an in-flight import and retains its installed file',
    () async {
      final chunks = StreamController<List<int>>();
      final started = Completer<void>();
      final importing = store.importStream(
        manifest,
        chunks.stream,
        onProgress: (_) {
          if (!started.isCompleted) started.complete();
        },
      );
      chunks.add(bytes.sublist(0, 1));
      await started.future;
      await part.writeAsBytes(bytes);
      var recoveryDone = false;
      final recovering = SlmModelStore(Directory('${root.path}/.'))
          .prepareDownloadPart(manifest)
          .then((state) {
            recoveryDone = true;
            return state;
          });
      await Future<void>.value();
      expect(recoveryDone, false);
      chunks.add(bytes.sublist(1));
      await chunks.close();
      final imported = await importing;
      final state = await recovering;
      expect(
        await FileSystemEntity.identical(
          state.installedFile!.path,
          imported.path,
        ),
        true,
      );
      expect(await imported.readAsBytes(), bytes);
      // The completed import already occupied the destination, so no rename
      // consumed or replaced this independent complete download.
      expect(await part.readAsBytes(), bytes);
    },
  );
}
