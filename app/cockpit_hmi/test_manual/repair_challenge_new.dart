// Developer-authored exploration, excluded from the normal unit-test suite.
// Expectations are stored before the run; failures never revise the reference.
import 'dart:convert';
import 'dart:io';

import 'package:cockpit_hmi/repair_parser.dart';
import 'package:cockpit_hmi/repair_remote_model.dart';
import 'package:cockpit_hmi/repair_task.dart';
import 'package:flutter_test/flutter_test.dart';

bool _sameMap(Map? actual, Map expected) =>
    actual != null &&
    actual.length == expected.length &&
    expected.entries.every((entry) => actual[entry.key] == entry.value);

void main() {
  test('開發者新挑戰：只跑一次，保留guard與Qwen原輸出和失敗', () async {
    const url = String.fromEnvironment('REPAIR_CHALLENGE_URL');
    const output = String.fromEnvironment('REPAIR_CHALLENGE_OUTPUT');
    const expectedSha = String.fromEnvironment(
      'REPAIR_CHALLENGE_EXPECTED_SHA256',
    );
    if (url.isEmpty || output.isEmpty || expectedSha.isEmpty) {
      fail(
        'Set REPAIR_CHALLENGE_URL, REPAIR_CHALLENGE_OUTPUT and the pre-run expectation SHA256.',
      );
    }
    final endpoint = Uri.parse(url);
    expect(
      const {'127.0.0.1', 'localhost', '::1'}.contains(endpoint.host),
      isTrue,
    );
    const datasetPath = 'test_manual/repair_challenge_new_cases.json';
    final dataset = jsonDecode(File(datasetPath).readAsStringSync()) as Map;
    final model = RemoteRepairModel(endpoint);
    addTearDown(model.dispose);
    await model.boot();
    expect(
      model.ready,
      isTrue,
      reason: 'Exact Qwen2.5-1.5B-Instruct alias required.',
    );
    Map<String, dynamic>? trace;
    final parser = RepairParser(
      model.generate,
      semanticGuard: true,
      onTrace: (value) => trace = value,
    );
    final rows = <Map<String, dynamic>>[];
    void save() {
      final destination = File(output);
      destination.parent.createSync(recursive: true);
      destination.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert({
          'name': '開發者撰寫的新挑戰集',
          'run_finished_at_utc': DateTime.now().toUtc().toIso8601String(),
          'model': model.model,
          'backend': 'PC GGUF Q8 / localhost existing server',
          'semantic_guard': true,
          'limitations':
              'Developer-authored after reading the fixed cases and current parser; not independent human validation or population accuracy. One run, typed text, no actuator/ASR/S9/user study. Clarification checks presence, not question quality.',
          'expected_dataset_path': datasetPath,
          'expected_dataset_sha256_before_run': expectedSha,
          'expectations': dataset,
          'system_prompt': kRepairSystemPrompt,
          'cases_completed': rows.length,
          'exact_contract_cases': rows
              .where((row) => row['exact'] == true)
              .length,
          'qwen_path_cases': rows.where((row) => row['path'] == 'qwen').length,
          'deterministic_clarification_cases': rows
              .where((row) => row['path'] == 'deterministic_clarification')
              .length,
          'rows': rows,
        }),
      );
    }

    for (final entry in dataset['cases'] as List) {
      final c = entry as Map;
      final original = Map<String, dynamic>.from(c['pending'] as Map);
      final pending = {
        for (final entry in original.entries)
          CabinSetting.values.byName(entry.key): RequestedChange.values.byName(
            entry.value as String,
          ),
      };
      trace = null;
      Map<String, String>? actual;
      Map<String, dynamic>? projected;
      String? clarification;
      String? error;
      final watch = Stopwatch()..start();
      try {
        final patch = await parser.call(
          c['text'] as String,
          RepairSnapshot(
            taskId: 'challenge_${c['id']}',
            pending: pending,
            unresolvedText: c['unresolved_text'] as String?,
            clarification: c['clarification'] as String?,
          ),
        );
        actual = {
          for (final item in patch.changes.entries)
            item.key.name: item.value.name,
        };
        clarification = patch.clarification;
        projected = Map<String, dynamic>.of(original);
        for (final item in actual.entries) {
          if (item.value == 'remove') {
            projected.remove(item.key);
          } else {
            projected[item.key] = item.value;
          }
        }
      } catch (e) {
        error = e.toString();
      }
      final questionPresent =
          clarification != null && clarification.trim().isNotEmpty;
      final exact =
          _sameMap(actual, c['expected_changes'] as Map) &&
          questionPresent == (c['expect_clarification'] == true) &&
          _sameMap(projected, c['expected_pending'] as Map) &&
          error == null;
      rows.add({
        'id': c['id'],
        'category': c['category'],
        'input': c['text'],
        'pending': original,
        'unresolved_text': c['unresolved_text'],
        'previous_clarification': c['clarification'],
        'expected_changes': c['expected_changes'],
        'expected_pending': c['expected_pending'],
        'expect_clarification': c['expect_clarification'],
        'predeclared_ambiguity': c['predeclared_ambiguity'],
        'expectation_reason': c['expectation_reason'],
        'actual_changes': actual,
        'projected_pending': projected,
        'clarification': clarification,
        'raw': trace?['raw'],
        'path': trace?['path'],
        'trace': trace,
        'exact': exact,
        'elapsed_ms': watch.elapsedMilliseconds,
        'error': error,
      });
      save();
      stdout.writeln(
        'NEW_CHALLENGE ${c['id']}: ${exact ? 'exact' : 'review'} path=${trace?['path']} ${watch.elapsedMilliseconds} ms',
      );
    }
    expect(rows.length, 16);
    // The test confirms complete recording, deliberately not 16 successes.
  }, timeout: const Timeout(Duration(minutes: 9)));
}
