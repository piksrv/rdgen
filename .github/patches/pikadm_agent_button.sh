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

Future<void> pikadmInstallAgent() async {
  try {
    final apiServer = await bind.mainGetApiServer();
    final token = bind.mainGetLocalOption(key: 'access_token');
    if (apiServer.trim().isEmpty || token.isEmpty) {
      showToast('Войдите в портал PIKADM');
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
      showToast(data is Map && data['error'] != null
          ? data['error'].toString()
          : 'Портал ответил HTTP ${resp.statusCode}');
      return;
    }
    final dir = await Directory.systemTemp.createTemp('pikadm-agent-');
    final file = File('${dir.path}\\install-agent.ps1');
    // UTF-8 with BOM: Windows PowerShell 5.1 reads a file without it in the ANSI code page.
    await file.writeAsBytes([0xEF, 0xBB, 0xBF, ...utf8.encode(script)], flush: true);
    await Process.start('powershell.exe', [
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      "Start-Process powershell.exe -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-File','\"${file.path}\"'",
    ]);
    showToast('Подтвердите запуск установщика агента PIKADM (UAC)');
  } catch (e) {
    showToast('Не удалось запустить установку агента: $e');
  }
}
EOF

fail=0
grep -q "useInfo(), pikadmAgentAction()" "$page" || { echo "desktop_setting_page.dart: Account card not patched"; fail=1; }
grep -q "http_service.dart' as pikadm_http;" "$page" || { echo "desktop_setting_page.dart: import not added"; fail=1; }
[ "$fail" -eq 0 ] || exit 1
git --no-pager diff --stat -- "$page"
