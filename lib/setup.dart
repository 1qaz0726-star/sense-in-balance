// 模型設定頁 —— 下載（可續傳）／從檔案匯入／先用模板模式

import 'package:flutter/material.dart';

import 'common.dart';
import 'slm.dart';

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
      return '載入中…（約 10 秒）';
    case SlmPhase.ready:
      return '✅ Qwen2.5-1.5B 就緒・${m.detail}';
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
          final busy = m.phase == SlmPhase.downloading || m.phase == SlmPhase.loading;
          return ListView(
            padding: EdgeInsets.all(s.pad),
            children: [
              Text('中控會在平板上離線跑一個小語言模型（Qwen2.5-1.5B，約 1.6 GB），'
                  '只負責把規則引擎的決策講成一句話。\n'
                  '模型不包在 APK 裡，第一次要下載一次，之後完全離線。',
                  style: TextStyle(fontSize: s.cardBody, color: C.textHigh, height: 1.5)),
              SizedBox(height: s.gap),
              Text('・建議用 Wi-Fi，平板要留 2 GB 以上空間\n'
                  '・下載中斷了沒關係，再按一次會接著下載\n'
                  '・如果裝過 slm_probe 測試 App，可以先把它解除安裝，釋放 1.6 GB\n'
                  '・沒有模型也能用：措辭會改用固定模板，畫面會標示「模板」',
                  style: TextStyle(fontSize: s.label, color: C.textLow, height: 1.6)),
              SizedBox(height: s.gap * 1.5),
              Text(modelStatusText(m),
                  style: TextStyle(fontSize: s.cardBody, color: C.textHigh, height: 1.4)),
              if (m.phase == SlmPhase.downloading) ...[
                SizedBox(height: s.gap * 0.6),
                LinearProgressIndicator(value: m.progress),
              ],
              SizedBox(height: s.gap * 1.5),
              Wrap(spacing: s.gap, runSpacing: s.gap, children: [
                if (m.phase == SlmPhase.downloading)
                  OutlinedButton.icon(
                    onPressed: m.cancelDownload,
                    icon: const Icon(Icons.pause),
                    label: const Text('暫停下載'),
                  )
                else if (m.phase == SlmPhase.missing || m.phase == SlmPhase.error)
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
                  OutlinedButton(onPressed: m.load, child: const Text('重試載入')),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(m.ready ? '完成' : '先用模板模式'),
                ),
              ]),
            ],
          );
        },
      ),
    );
  }
}
