// 模型設定頁 —— 下載（可續傳）／從檔案匯入／先用模板模式

import 'package:flutter/material.dart';

import 'common.dart';
import 'slm.dart';
import 'slm_model_store.dart';

String modelStatusText(Slm m) {
  switch (m.phase) {
    case SlmPhase.checking:
      return '檢查中…';
    case SlmPhase.missing:
      return '尚未下載（目前用模板措辭）${m.detail.isEmpty ? '' : '\n${m.detail}'}';
    case SlmPhase.downloading:
      return '${(m.progress * 100).toStringAsFixed(1)}%　${m.detail}';
    case SlmPhase.present:
      return '已下載，準備載入';
    case SlmPhase.loading:
      return '載入中…（時間依裝置而異）${m.detail.isEmpty ? '' : '\n${m.detail}'}';
    case SlmPhase.ready:
      return '✅ ${m.selectedModel.label} 就緒・${m.detail}';
    case SlmPhase.error:
      return '⚠️ ${m.detail}\n（目前用模板措辭）';
  }
}

class ModelSetupPage extends StatelessWidget {
  const ModelSetupPage({super.key});

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('端側模型')),
      body: ListenableBuilder(
        listenable: Slm.I,
        builder: (context, _) {
          final m = Slm.I;
          final busy = m.busy;
          return ListView(
            padding: EdgeInsets.all(s.pad),
            children: [
              Text(
                '中控會在平板上離線跑一個小語言模型（Qwen2.5-1.5B，檔案大小依版本而異），'
                '原版可用於措辭；V3 專門解析「不用重講」需求與局部修正，原座艙告知會改用模板。\n'
                '確認、取消與執行結果仍由固定規則處理。\n'
                '模型不包在 APK 裡，第一次要下載一次，之後完全離線。',
                style: TextStyle(
                  fontSize: s.cardBody,
                  color: C.textHigh,
                  height: 1.5,
                ),
              ),
              SizedBox(height: s.gap),
              Text(
                '・首次下載建議用 Wi-Fi，請預留模型與匯入暫存空間\n'
                '・下載中斷了沒關係，再按一次會接著下載\n'
                '・原版與實驗版分開保存，匯入不會取代原版\n'
                '・原座艙模式沒有模型時，以固定模板措辭\n'
                '・「不用重講」需要模型就緒，未就緒時不能解析需求',
                style: TextStyle(
                  fontSize: s.label,
                  color: C.textLow,
                  height: 1.6,
                ),
              ),
              SizedBox(height: s.gap * 1.5),
              Text(
                modelStatusText(m),
                style: TextStyle(
                  fontSize: s.cardBody,
                  color: C.textHigh,
                  height: 1.4,
                ),
              ),
              SizedBox(height: s.gap),
              FutureBuilder<List<SlmModelManifest>>(
                future: m.installedManifests(),
                builder: (context, snapshot) {
                  final versions = snapshot.data;
                  if (snapshot.hasError) {
                    return Text('模型清單讀取失敗：${snapshot.error}');
                  }
                  if (versions == null) return const SizedBox.shrink();
                  return DropdownButtonFormField<String>(
                    key: ValueKey(m.selectedModel.id),
                    initialValue:
                        versions.any((v) => v.id == m.selectedModel.id)
                        ? m.selectedModel.id
                        : null,
                    decoration: const InputDecoration(
                      labelText: '本機模型版本（原版與 V3 分開保存）',
                    ),
                    isExpanded: true,
                    items: [
                      for (final version in versions)
                        DropdownMenuItem(
                          value: version.id,
                          child: Text(
                            version.label,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: busy
                        ? null
                        : (id) async {
                            if (id == null ||
                                id == m.selectedModel.id && m.ready) {
                              return;
                            }
                            try {
                              await m.selectModel(
                                versions.singleWhere(
                                  (version) => version.id == id,
                                ),
                              );
                            } catch (_) {
                              // The shared model status displays the validation error.
                            }
                          },
                  );
                },
              ),
              if (m.phase == SlmPhase.downloading) ...[
                SizedBox(height: s.gap * 0.6),
                LinearProgressIndicator(value: m.progress),
              ],
              SizedBox(height: s.gap * 1.5),
              Wrap(
                spacing: s.gap,
                runSpacing: s.gap,
                children: [
                  if (m.phase == SlmPhase.downloading)
                    OutlinedButton.icon(
                      onPressed: m.cancelDownload,
                      icon: const Icon(Icons.pause),
                      label: const Text('暫停下載'),
                    )
                  else if ((m.phase == SlmPhase.missing ||
                          m.phase == SlmPhase.error) &&
                      m.selectedModel.id == kOriginalSlmManifest.id)
                    FilledButton.icon(
                      onPressed: busy ? null : m.download,
                      icon: const Icon(Icons.download),
                      label: Text(m.progress > 0 ? '繼續下載' : '下載模型（1.6 GB）'),
                    ),
                  if (m.phase == SlmPhase.missing || m.phase == SlmPhase.error)
                    OutlinedButton.icon(
                      onPressed: busy ? null : m.importFile,
                      icon: const Icon(Icons.folder_open),
                      label: const Text('從檔案匯入 .litertlm'),
                    ),
                  if (m.phase == SlmPhase.error)
                    OutlinedButton(
                      onPressed: m.load,
                      child: const Text('重試載入'),
                    ),
                  OutlinedButton.icon(
                    onPressed: busy ? null : m.importExperiment,
                    icon: const Icon(Icons.science_outlined),
                    label: const Text('匯入實驗版本（先選 manifest，再選模型）'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(m.ready ? '完成' : '返回'),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}
