// Explicit live-model evaluation, excluded from the ordinary unit-test suite.
// This checks semantic patches, not usability, S9 performance, or ASR quality.
import 'dart:convert';
import 'dart:io';

import 'package:cockpit_hmi/repair_parser.dart';
import 'package:cockpit_hmi/repair_remote_model.dart';
import 'package:cockpit_hmi/repair_task.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('固定題目真正Qwen解析；保存每題輸出、不把完成評測當成全對', () async {
    const url = String.fromEnvironment('REPAIR_EVAL_URL');
    const output = String.fromEnvironment('REPAIR_EVAL_OUTPUT');
    const guarded = bool.fromEnvironment(
      'REPAIR_EVAL_GUARD',
      defaultValue: true,
    );
    if (url.isEmpty || output.isEmpty) {
      fail(
        'Specify REPAIR_EVAL_URL and REPAIR_EVAL_OUTPUT; this is a manual live-model run.',
      );
    }
    final dataset =
        jsonDecode(
              File('../../research/repair_eval_cases.json').readAsStringSync(),
            )
            as Map;
    final model = RemoteRepairModel(Uri.parse(url));
    addTearDown(model.dispose);
    await model.boot();
    expect(model.ready, true, reason: 'Exact Qwen alias must be available.');
    final rows = <Map<String, dynamic>>[];
    Map<String, dynamic>? trace;
    final parser = RepairParser(
      model.generate,
      semanticGuard: guarded,
      onTrace: (value) => trace = value,
    );
    for (final group in ['development', 'holdout']) {
      for (final value in dataset[group] as List) {
        final c = value as Map;
        final original = Map<String, dynamic>.from(
          c['pending'] as Map? ?? dataset['default_pending'] as Map,
        );
        final pending = {
          for (final e in original.entries)
            CabinSetting.values.byName(e.key): RequestedChange.values.byName(
              e.value,
            ),
        };
        trace = null;
        final watch = Stopwatch()..start();
        Map<String, String>? actual;
        String? clarification;
        String? error;
        try {
          final result = await parser.call(
            c['text'] as String,
            RepairSnapshot(taskId: 'evaluation', pending: pending),
          );
          actual = {
            for (final e in result.changes.entries) e.key.name: e.value.name,
          };
          clarification = result.clarification;
        } catch (e) {
          error = e.toString();
        }
        final expected = Map<String, dynamic>.from(
          c['expected_changes'] as Map,
        );
        final exact =
            actual != null &&
            actual.length == expected.length &&
            expected.entries.every((e) => actual![e.key] == e.value) &&
            ((c['expect_clarification'] == true)
                ? clarification != null && clarification.isNotEmpty
                : clarification == null);
        final row = <String, dynamic>{
          'id': c['id'],
          'group': group,
          'input': c['text'],
          'pending': original,
          'expected_changes': expected,
          'expect_clarification': c['expect_clarification'] == true,
          'actual_changes': actual,
          'clarification': clarification,
          'exact': exact,
          'elapsed_ms': watch.elapsedMilliseconds,
          'error': error,
          'trace': trace,
        };
        rows.add(row);
        // Save incrementally: a transport failure never turns missing cases into success.
        File(output).parent.createSync(recursive: true);
        File(output).writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert({
            'model': model.model,
            'backend': 'PC GGUF Q8 / localhost',
            'dataset':
                'Published fixed 8 development + 12 holdout cases; not an independent unseen sample',
            'semantic_guard': guarded,
            'cases_completed': rows.length,
            'exact_count': rows.where((r) => r['exact'] == true).length,
            'system_prompt': kRepairSystemPrompt,
            'rows': rows,
          }),
        );
        stdout.writeln(
          'LIVE_QWEN ${c['id']}: ${exact ? 'exact' : 'review'} (${watch.elapsedMilliseconds} ms)',
        );
      }
    }
    expect(rows.length, 20);
  }, timeout: const Timeout(Duration(minutes: 5)));
}
