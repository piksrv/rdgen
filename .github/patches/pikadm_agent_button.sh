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
  // Owner 22.11.2026: four compact buttons — install, reinstall, find installed agents, remove.
  Widget button(String label, IconData icon, VoidCallback onPressed) => Padding(
      padding: const EdgeInsets.only(right: 8, top: 6),
      child: OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              textStyle: const TextStyle(fontSize: 13)),
          onPressed: onPressed,
          icon: Icon(icon, size: 16),
          label: Text(label)));
  return Obx(() => Offstage(
      offstage: gFFI.userModel.userName.value.isEmpty,
      child: Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Агент PIKADM'),
            Wrap(children: [
              button('Установить', Icons.download_outlined, () => pikadmInstallAgent('install')),
              button('Переустановить', Icons.refresh, () => pikadmInstallAgent('reinstall')),
              button('Найти установленные', Icons.search, () => pikadmAgentTool('discover')),
              button('Удалить', Icons.delete_outline, () => pikadmAgentTool('remove')),
            ]),
          ]))));
}

bool _pikadmAgentBusy = false;

Future<List<String>?> _pikadmSession() async {
  final apiServer = await bind.mainGetApiServer();
  final token = bind.mainGetLocalOption(key: 'access_token');
  if (apiServer.trim().isEmpty || token.isEmpty) {
    pikadmAgentMessage('Агент PIKADM', 'Войдите в портал PIKADM в этом клиенте.');
    return null;
  }
  return [apiServer, token];
}

// «Найти установленные» and «Удалить»: no invitation; the portal answers the public installer in read-only
// discovery mode or with its own menu, where removal is chosen and confirmed on this computer.
Future<void> pikadmAgentTool(String mode) async {
  if (_pikadmAgentBusy) return;
  _pikadmAgentBusy = true;
  try {
    final session = await _pikadmSession();
    if (session == null) return;
    await _pikadmRunInstall(session[0], session[1], {'mode': mode}, nested: true);
  } catch (e) {
    pikadmAgentMessage('Не удалось запустить PowerShell', '$e');
  } finally {
    _pikadmAgentBusy = false;
  }
}

Future<void> pikadmInstallAgent(String mode) async {
  // One click, one invitation: repeated clicks while the request runs are ignored.
  if (_pikadmAgentBusy) return;
  _pikadmAgentBusy = true;
  final reinstall = mode == 'reinstall';
  try {
    final session = await _pikadmSession();
    if (session == null) return;
    final apiServer = session[0];
    final token = session[1];
    // Owner 22.11.2026: the user chooses what to install; a device without organization names it by INN.
    final check = await _pikadmAgentRequest(apiServer, token, {'check': true});
    if (check == null) return;
    final defaults = check['components'] is Map ? check['components'] as Map : const {};
    var glpi = defaults['glpi'] != false;
    var monitoring = defaults['monitoring'] == true;
    var metrics = defaults['metrics'] == true;
    final innRequired = check['inn_required'] == true;
    final innController = TextEditingController();
    var innError = '';
    gFFI.dialogManager.show((setState, close, context) {
      submit() {
        final inn = innController.text.replaceAll(RegExp(r'\D'), '');
        if (innRequired && inn.length != 10 && inn.length != 12) {
          setState(() => innError = 'ИНН состоит из 10 или 12 цифр');
          return;
        }
        if (reinstall && !glpi && !monitoring) {
          setState(() => innError = 'Для переустановки выберите GLPI или Zabbix');
          return;
        }
        close();
        _pikadmRunInstall(apiServer, token, {
          'mode': mode,
          'glpi': glpi,
          'monitoring': monitoring,
          'metrics': metrics,
          if (innRequired) 'inn': inn,
        });
      }

      Widget box(String title, String hint, bool value, void Function(bool) changed) => CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          controlAffinity: ListTileControlAffinity.leading,
          value: value,
          title: Text(title),
          subtitle: Text(hint),
          onChanged: (v) => setState(() => changed(v == true)));
      return CustomAlertDialog(
        title: Text(reinstall ? 'Переустановка агента PIKADM' : 'Установка агента PIKADM'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(innRequired
              ? 'Устройство ещё не привязано к организации. Укажите ИНН организации, которой принадлежит компьютер.'
              : 'Организация: ${check['organization']}'),
          if (innRequired)
            TextField(
                controller: innController,
                autofocus: true,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                    labelText: 'ИНН организации', errorText: innError.isEmpty ? null : innError)),
          const SizedBox(height: 12),
          Text(reinstall
              ? 'Выбранные агенты будут удалены и поставлены заново (с резервной копией настроек):'
              : 'Агент PIKADM ставится всегда. Дополнительно установить:'),
          box('GLPI Agent', 'инвентаризация оборудования и программ', glpi, (v) => glpi = v),
          box('Zabbix Agent 2 и графики Grafana', 'мониторинг нагрузки и доступности', monitoring,
              (v) => monitoring = v),
          box('Prometheus exporter', 'windows_exporter для Prometheus', metrics, (v) => metrics = v),
          if (!innRequired && innError.isNotEmpty) Text(innError, style: const TextStyle(color: Colors.red)),
        ]),
        actions: [
          dialogButton('Cancel', onPressed: close, isOutline: true),
          dialogButton(reinstall ? 'Переустановить' : 'Установить', onPressed: submit),
        ],
        onSubmit: submit,
        onCancel: close,
      );
    });
  } catch (e) {
    pikadmAgentMessage('Не удалось запустить установку агента', '$e');
  } finally {
    _pikadmAgentBusy = false;
  }
}

// POST to the portal; the answer as a Map, or null after showing what went wrong.
Future<Map?> _pikadmAgentRequest(String apiServer, String token, Map<String, dynamic> body) async {
  final resp = await pikadm_http.post(Uri.parse('$apiServer/api/pikadm/agent-install'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({
        'id': await bind.mainGetMyId(),
        'uuid': await bind.mainGetUuid(),
        ...body,
      }));
  dynamic data;
  try {
    data = jsonDecode(resp.body);
  } catch (_) {
    data = null;
  }
  if (resp.statusCode != 200 || data is! Map) {
    pikadmAgentMessage('Портал не выдал установщик агента', data is Map && data['error'] != null
        ? data['error'].toString()
        : 'Портал ответил HTTP ${resp.statusCode}');
    return null;
  }
  return data;
}

Future<void> _pikadmRunInstall(String apiServer, String token, Map<String, dynamic> choice,
    {bool nested = false}) async {
  if (!nested) {
    if (_pikadmAgentBusy) return;
    _pikadmAgentBusy = true;
  }
  final mode = choice['mode'] ?? 'install';
  try {
    final data = await _pikadmAgentRequest(apiServer, token, choice);
    if (data == null) return;
    final script = data['script'];
    if (script is! String) {
      pikadmAgentMessage('Портал не выдал установщик агента', 'В ответе портала нет скрипта установки.');
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
    pikadmAgentMessage(
        'Агент PIKADM',
        mode == 'discover'
            ? 'Список агентов на этом компьютере открыт в отдельном окне PowerShell.'
            : mode == 'remove'
                ? 'В отдельном окне PowerShell открыто меню установщика: 4 — удалить все агенты, '
                    '5 — удалить определённый. Удаление подтверждается там же.'
                : 'Установщик запущен в отдельном окне PowerShell от имени администратора. '
                    'Дождитесь «PIKADM: готово» — устройство появится в портале с агентом.');
  } catch (e) {
    pikadmAgentMessage('Не удалось запустить PowerShell', '$e');
  } finally {
    if (!nested) _pikadmAgentBusy = false;
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
