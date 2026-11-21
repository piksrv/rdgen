#!/usr/bin/env bash
# PIKADM: heartbeat and sysinfo carry the portal login token (Authorization: Bearer), so the portal can
# tell a current client from an old one (pikadm-unified #636). Run from the RustDesk source root.
#
# The login token lives in the user's LocalConfig (GUI process). An installed client sends heartbeat
# from the service process, which has its own LocalConfig, so a login/logout also writes the token to
# the shared Config option "pikadm-access-token" over IPC. A missing or expired token falls back to the
# portal's unauthenticated presence path: nothing breaks for clients that are not signed in.
set -euo pipefail

sync=src/hbbs_http/sync.rs
ui=src/ui_interface.rs
account=src/hbbs_http/account.rs

perl -0pi -e 's/crate::post_request\(url\.replace\("heartbeat", "sysinfo"\), (v(?:\.to_string\(\))?), ""\)/crate::post_request(url.replace("heartbeat", "sysinfo"), $1, &pikadm_auth_header())/; s/crate::post_request\(url\.clone\(\), v\.to_string\(\), ""\)/crate::post_request(url.clone(), v.to_string(), &pikadm_auth_header())/' "$sync"
cat >> "$sync" <<'EOF'

// PIKADM: portal login token for heartbeat/sysinfo (see .github/patches/pikadm_token_heartbeat.sh in rdgen).
fn pikadm_auth_header() -> String {
    let mut token = LocalConfig::get_option("access_token");
    if token.is_empty() {
        token = Config::get_option("pikadm-access-token");
    }
    if token.is_empty() || token.contains(['\r', '\n']) {
        String::new()
    } else {
        format!("Authorization: Bearer {}", token)
    }
}
EOF

# Windows runners check sources out with CRLF: the patterns accept both line endings.
perl -0pi -e 's/(pub fn set_local_option\(key: String, value: String\) \{\r?\n)([ \t]*)(LocalConfig::set_option\(key\.clone\(\), value(?:\.clone\(\))?\);)/$1$2if key == "access_token" {\n$2    set_option("pikadm-access-token".to_owned(), value.clone());\n$2}\n$2$3/' "$ui"

perl -0pi -e 's/("access_token"\.to_owned\(\),\r?\n\s*auth_body\.access_token\.clone\(\),\r?\n([ \t]*)\);\r?\n)/$1$2crate::ui_interface::set_option("pikadm-access-token".to_owned(), auth_body.access_token.clone());\n/' "$account"

fail=0
[ "$(grep -c 'pikadm_auth_header()' "$sync")" -eq 3 ] || { echo "sync.rs: heartbeat/sysinfo calls not patched"; fail=1; }
grep -q '"pikadm-access-token".to_owned(), value.clone()' "$ui" || { echo "ui_interface.rs: set_local_option not patched"; fail=1; }
grep -q '"pikadm-access-token".to_owned(), auth_body.access_token.clone()' "$account" || { echo "account.rs: OIDC login not patched"; fail=1; }
[ "$fail" -eq 0 ] || exit 1
git --no-pager diff --stat -- "$sync" "$ui" "$account"
