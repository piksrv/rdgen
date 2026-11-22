#!/usr/bin/env bash
# PIKADM: «Установить PIKADM Agent» in Settings → Account of the desktop client (Windows, signed in).
# The client asks the portal (POST <api-server>/api/pikadm/agent-install, login token as Bearer) for a
# one-time agent invitation for this device and runs the returned PowerShell script elevated (UAC).
# Nothing is built in: no token, no rights; the portal decides (pikadm-unified #1112). Run from the RustDesk root.
set -euo pipefail

page=flutter/lib/desktop/pages/desktop_setting_page.dart

perl -0pi -e "s/_Card\(title: 'Account', children: \[accountAction\(\), useInfo\(\)\]\)/_Card(title: 'Account', children: [accountAction(), useInfo(), pikadmAgentAction()])/" "$page"
perl -0pi -e "s/(import 'dart:io';\r?\n)/\$1import 'package:flutter_hbb\/utils\/http_service.dart' as pikadm_http;\n/" "$page"
cat >> "$page" <<'EOF'

// PIKADM: install the PIKADM agent on this computer (see .github/patches/pikadm_agent_button.sh in rdgen).
Widget pikadmAgentAction() {
  if (!Platform.isWindows) return const SizedBox.shrink();
  return Obx(() => Offstage(
      offstage: gFFI.userModel.userName.value.isEmpty,
      child: _Button('Установить PIKADM Agent', () => pikadmInstallAgent())));
}

bool _pikadmAgentBusy = false;

Future<void> pikadmInstallAgent() async {
  // One click, one invitation: repeated clicks while the request runs are ignored.
  if (_pikadmAgentBusy) return;
  _pikadmAgentBusy = true;
  try {
    final apiServer = await bind.mainGetApiServer();
    final token = bind.mainGetLocalOption(key: 'access_token');
    if (apiServer.trim().isEmpty || token.isEmpty) {
      pikadmAgentMessage('Установка агента PIKADM', 'Войдите в портал PIKADM в этом клиенте.');
      return;
    }
    final resp = await pikadm_http.post(Uri.parse('$apiServer/api/pikadm/agent-install'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: jsonEncode({
          'id': await bind.mainGetMyId(),
          'uuid': await bind.mainGetUuid(),
        }));
    final data = jsonDecode(resp.body);
    final script = data is Map ? data['script'] : null;
    if (resp.statusCode != 200 || script is! String) {
      pikadmAgentMessage('Портал не выдал установщик агента', data is Map && data['error'] != null
          ? data['error'].toString()
          : 'Портал ответил HTTP ${resp.statusCode}');
      return;
    }
    final dir = await Directory.systemTemp.createTemp('pikadm-agent-');
    final file = File('${dir.path}\\install-agent.ps1');
    // UTF-8 with BOM: Windows PowerShell 5.1 reads a file without it in the ANSI code page.
    await file.writeAsBytes([0xEF, 0xBB, 0xBF, ...utf8.encode(script)], flush: true);
    // The elevated PowerShell gets «& '<path>'» as -EncodedCommand (UTF-16LE base64): no quotes cross the
    // Windows command line, so a path is never mangled (22.11.2026: the -File '\"path\"' form started nothing).
    final inner = "& '${file.path.replaceAll("'", "''")}'";
    final encoded = base64.encode([for (final unit in inner.codeUnits) ...[unit & 0xff, unit >> 8]]);
    final result = await Process.run('powershell.exe', [
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-WindowStyle',
      'Hidden',
      '-Command',
      "Start-Process -FilePath powershell.exe -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -NoExit -EncodedCommand $encoded' -ErrorAction Stop",
    ]);
    if (result.exitCode != 0) {
      final detail = '${result.stderr}'.trim();
      pikadmAgentMessage('Установщик агента не запущен',
          detail.contains('cancel') || detail.contains('отмен')
              ? 'Запуск от имени администратора отменён. Нажмите кнопку ещё раз и разрешите запуск.'
              : 'PowerShell: ${detail.length > 400 ? detail.substring(0, 400) : detail}');
      return;
    }
    pikadmAgentMessage('Установка агента PIKADM',
        'Установщик запущен в отдельном окне PowerShell от имени администратора. '
        'Дождитесь «PIKADM: готово» — устройство появится в портале с агентом.');
  } catch (e) {
    pikadmAgentMessage('Не удалось запустить установку агента', '$e');
  } finally {
    _pikadmAgentBusy = false;
  }
}

// A dialog, not a toast: the owner pressed the button and saw nothing (22.11.2026).
void pikadmAgentMessage(String title, String text) {
  gFFI.dialogManager.show((setState, close, context) => CustomAlertDialog(
        title: Text(title),
        content: SelectableText(text),
        actions: [dialogButton('OK', onPressed: close)],
        onSubmit: close,
        onCancel: close,
      ));
}
EOF

fail=0
grep -q "useInfo(), pikadmAgentAction()" "$page" || { echo "desktop_setting_page.dart: Account card not patched"; fail=1; }
grep -q "http_service.dart' as pikadm_http;" "$page" || { echo "desktop_setting_page.dart: import not added"; fail=1; }
[ "$fail" -eq 0 ] || exit 1
git --no-pager diff --stat -- "$page"
