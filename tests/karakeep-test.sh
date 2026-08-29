#!/usr/bin/env bash
# Behavior test for the Karakeep quick-add widget: the Qt-free model under
# node, and the karakeep-api helper against isolated fakes. Nothing here
# touches the user's keyring or a real Karakeep server — a fake secret-tool
# earlier in PATH owns a file under this test's temporary directory, and an
# HTTP stub on loopback stands in for the API.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HELPER="$ROOT/karakeep-api"
PY=$(command -v python3)

TMP=$(mktemp -d)
STUB_PID=""
STORE="$TMP/keyring"
LOG="$TMP/requests.log"
REACHED="$TMP/redirect-reached"
RECORD="$TMP/posts.log"
FAKE_KEY=goodkey

cleanup() {
  if [[ -n $STUB_PID ]]; then kill "$STUB_PID" 2>/dev/null || true; fi
  rm -rf "$TMP"
}
trap cleanup EXIT

ok() { echo "ok  $*"; }
fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -x $HELPER ]] || fail "karakeep-api is missing or not executable"

# ---- fakes ------------------------------------------------------------------

mkdir -p "$TMP/bin" "$TMP/empty" "$TMP/home"

# The attribute set is asserted rather than accepted: wrong attributes would
# silently create a second keyring item in production.
cat >"$TMP/bin/secret-tool" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
STORE=${SECRET_TOOL_TEST_STORE:?}
EXPECTED="application org.omarchy.shell.plugin plugin embiem.karakeep service karakeep"
action=${1:-}
shift || true
case $action in
  store)
    label=${1:-}
    shift || true
    [[ $label == "--label=Karakeep API token (embiem.karakeep)" ]] || exit 3
    [[ "$*" == "$EXPECTED" ]] || exit 3
    cat >"$STORE"
    ;;
  lookup)
    [[ "$*" == "$EXPECTED" ]] || exit 3
    [[ -f $STORE ]] || exit 1
    cat "$STORE"
    ;;
  clear)
    [[ "$*" == "$EXPECTED" ]] || exit 3
    rm -f "$STORE"
    ;;
  *) exit 2 ;;
esac
FAKE
chmod 755 "$TMP/bin/secret-tool"

cat >"$TMP/stub.py" <<'STUB'
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOG, REACHED, RECORD = sys.argv[1], sys.argv[2], sys.argv[3]


def note(line):
    with open(LOG, "a") as fh:
        fh.write(line + "\n")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def send(self, code, body, ctype="application/json"):
        raw = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        note("GET " + self.path)
        auth = self.headers.get("Authorization", "")
        if self.path == "/api/v1/redirect-target":
            with open(REACHED, "w") as fh:
                fh.write("reached")
            self.send(200, "{}")
            return
        if self.path == "/api/v1/users/me":
            if auth == "Bearer redirectkey":
                self.send_response(302)
                self.send_header("Location", "/api/v1/redirect-target")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            # Headers announce a chunked body, then the body is malformed. The
            # read fails after open() returned, which is the one transport
            # fault that raises past both urllib handlers.
            if auth == "Bearer truncatekey":
                self.wfile.write(
                    b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nZZZZ\r\nnope\r\n"
                )
                self.wfile.flush()
                self.close_connection = True
                return
            if auth == "Bearer scopekey":
                self.send(403, "API key is missing required scope: users:read", "text/plain")
                return
            if auth == "Bearer goodkey":
                self.send(200, json.dumps({
                    "id": "u1", "name": "Test", "email": "t@example.com",
                    "image": None, "localUser": True,
                }))
                return
            self.send(401, "Unauthorized", "text/plain")
            return
        self.send(404, json.dumps({"code": "NOT_FOUND", "message": "no route"}))

    def do_POST(self):
        note("POST " + self.path)
        raw = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        with open(RECORD, "a") as fh:
            fh.write(json.dumps({
                "path": self.path,
                "auth": self.headers.get("Authorization", ""),
                "ctype": self.headers.get("Content-Type", ""),
                "accept": self.headers.get("Accept", ""),
                "body": raw.decode("utf-8", "replace"),
            }) + "\n")
        if self.path != "/api/v1/bookmarks":
            self.send(404, json.dumps({"code": "NOT_FOUND", "message": "no route"}))
            return
        if self.headers.get("Authorization", "") == "Bearer scopekey":
            self.send(403, "secret detail: API key is missing required scope: bookmarks:readwrite", "text/plain")
            return
        if self.headers.get("Authorization", "") != "Bearer goodkey":
            self.send(401, "Unauthorized", "text/plain")
            return
        try:
            payload = json.loads(raw)
        except Exception:
            payload = None
        if isinstance(payload, dict) and len(payload) == 2:
            if payload.get("type") == "link" and isinstance(payload.get("url"), str):
                if payload["url"] == "https://existing.example":
                    self.send(200, json.dumps({"id": "bk_existing"}))
                    return
                if payload["url"] != "https://reject.example":
                    self.send(201, json.dumps({"id": "bk_123"}))
                    return
            elif payload.get("type") == "text" and isinstance(payload.get("text"), str):
                self.send(201, json.dumps({"id": "bk_123"}))
                return
        # Deliberately token- and note-shaped text: the helper must answer with
        # its own fixed string instead of forwarding this.
        self.send(400, json.dumps({
            "code": "BAD_REQUEST",
            "message": "rejected goodkey while saving buy milk",
        }))


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(sys.argv[4], "w") as fh:
    fh.write(str(server.server_address[1]))
server.serve_forever()
STUB

"$PY" "$TMP/stub.py" "$LOG" "$REACHED" "$RECORD" "$TMP/port" >/dev/null 2>"$TMP/stub.err" &
STUB_PID=$!
PORT=""
for _ in $(seq 1 50); do
  if [[ -s $TMP/port ]]; then
    PORT=$(<"$TMP/port")
    break
  fi
  sleep 0.1
done
[[ $PORT =~ ^[0-9]+$ ]] || fail "HTTP stub did not report a port"
ORIGIN="http://127.0.0.1:$PORT"

# ---- helpers ----------------------------------------------------------------

jget() {
  "$PY" -c 'import json,sys
d = json.loads(sys.stdin.read())
v = d.get(sys.argv[1])
print("" if v is None else (json.dumps(v) if isinstance(v, (dict, list)) else str(v)))' "$1"
}

HOUT=""
HERR=""
HRC=0
HELPER_EXTRA_ENV=()

# Every helper invocation is held to the same contract, however it was spawned:
# operational and API failures are results, not exit codes (QML reads one
# channel), and neither stream may carry the credential or the header built
# from it.
assert_result_contract() {
  local label=$1
  [[ $HRC -eq 0 ]] || fail "$label exited $HRC instead of returning a result"
  [[ $HOUT != *"$FAKE_KEY"* ]] || fail "$label leaked the API key on stdout"
  [[ $HERR != *"$FAKE_KEY"* ]] || fail "$label leaked the API key on stderr"
  [[ $HOUT != *Bearer* ]] || fail "$label leaked an Authorization header on stdout"
  [[ $HERR != *Bearer* ]] || fail "$label leaked an Authorization header on stderr"
  [[ -z $HERR ]] || fail "$label wrote to stderr instead of returning a result"
}

run_helper() {
  local action=$1 input=${2-}
  set +e
  printf '%s\n' "$input" |
    env PATH="$TMP/bin:/usr/bin:/bin" SECRET_TOOL_TEST_STORE="$STORE" HOME="$TMP/home" \
      "${HELPER_EXTRA_ENV[@]}" "$HELPER" "$action" >"$TMP/out" 2>"$TMP/err"
  HRC=$?
  set -e
  HOUT=$(<"$TMP/out")
  HERR=$(<"$TMP/err")
  assert_result_contract "$action"
}

field() { printf '%s' "$HOUT" | jget "$1"; }

requests() { [[ -f $LOG ]] && wc -l <"$LOG" || echo 0; }

expect_no_request() {
  local before=$1
  [[ $(requests) -eq $before ]] || fail "$2"
}

expect_error() {
  [[ $(field ok) == False ]] || fail "$2 (expected a failure result)"
  [[ $(field error) == "$1" ]] || fail "$2 (got: $(field error))"
}

# ---- model ------------------------------------------------------------------

cat >"$TMP/model-test.js" <<'MODEL'
const assert = require("assert")
const M = require(process.argv[2])

const labels = []
function t(label, fn) {
  fn()
  labels.push(label)
}

t("looksLikeUrl accepts complete http and https bookmark targets", () => {
  assert.strictEqual(M.looksLikeUrl("https://example.com/article"), true)
  assert.strictEqual(M.looksLikeUrl("http://192.168.1.10:8080/x"), true)
  assert.strictEqual(M.looksLikeUrl("  https://example.com  "), true)
})

t("looksLikeUrl rejects phrases, bare hosts and blanks", () => {
  assert.strictEqual(M.looksLikeUrl("read https://example.com later"), false)
  assert.strictEqual(M.looksLikeUrl("example.com"), false)
  assert.strictEqual(M.looksLikeUrl("buy milk"), false)
  assert.strictEqual(M.looksLikeUrl("   "), false)
  assert.strictEqual(M.looksLikeUrl(null), false)
})

t("bookmarkPayload matches Karakeep's link and text shapes", () => {
  assert.deepStrictEqual(M.bookmarkPayload(" https://example.com/a "), {
    type: "link", url: "https://example.com/a",
  })
  assert.deepStrictEqual(M.bookmarkPayload("  buy milk  "), {
    type: "text", text: "buy milk",
  })
  assert.deepStrictEqual(M.bookmarkPayload("check https://example.com"), {
    type: "text", text: "check https://example.com",
  })
})

t("bookmarkPayload treats blank input as no entry", () => {
  assert.strictEqual(M.bookmarkPayload("   "), null)
  assert.strictEqual(M.bookmarkPayload(""), null)
  assert.strictEqual(M.bookmarkPayload(null), null)
})

t("previewUrl percent-encodes the server-returned id", () => {
  assert.strictEqual(
    M.previewUrl("https://cloud.karakeep.app//", "bk 1/2"),
    "https://cloud.karakeep.app/dashboard/preview/bk%201%2F2")
  assert.strictEqual(M.previewUrl("", "bk_1"), "")
  assert.strictEqual(M.previewUrl("https://cloud.karakeep.app", ""), "")
})

t("apiKeysUrl links only complete addresses", () => {
  assert.strictEqual(M.apiKeysUrl("https://keep.example//"),
    "https://keep.example/settings/api-keys")
  assert.strictEqual(M.apiKeysUrl("  http://127.0.0.1:3000  "),
    "http://127.0.0.1:3000/settings/api-keys")
  assert.strictEqual(M.apiKeysUrl("keep.example"), "")
  assert.strictEqual(M.apiKeysUrl("https://"), "")
  assert.strictEqual(M.apiKeysUrl(""), "")
  assert.strictEqual(M.apiKeysUrl(null), "")
})

t("parseResult reads status, created and duplicate results", () => {
  const status = M.parseResult('{"ok":true,"configured":true,"serverUrl":"https://cloud.karakeep.app"}')
  assert.strictEqual(status.ok, true)
  assert.strictEqual(status.configured, true)
  assert.strictEqual(status.serverUrl, "https://cloud.karakeep.app")
  assert.strictEqual(status.id, "")

  const created = M.parseResult('{"ok":true,"id":"bk_123","existing":false}')
  assert.strictEqual(created.id, "bk_123")
  assert.strictEqual(created.existing, false)

  const duplicate = M.parseResult('{"ok":true,"id":"bk_existing","existing":true}')
  assert.strictEqual(duplicate.existing, true)
})

t("parseResult turns unreadable output into a failure", () => {
  const broken = M.parseResult("secret-tool: no such thing")
  assert.strictEqual(broken.ok, false)
  assert.strictEqual(broken.error, "Karakeep returned an unreadable response.")
  assert.strictEqual(broken.configured, false)
})

t("parseResult carries no credential or server-controlled extra fields", () => {
  const parsed = M.parseResult(JSON.stringify({
    ok: true, configured: true, serverUrl: "https://x", id: "bk_1", existing: false,
    apiKey: "leaked", email: "t@example.com", name: "Test", message: "server text",
  }))
  assert.deepStrictEqual(Object.keys(parsed).sort(),
    ["configured", "error", "existing", "id", "ok", "serverUrl"])
  assert.strictEqual(parsed.apiKey, undefined)
  assert.strictEqual(parsed.email, undefined)
  assert.strictEqual(parsed.message, undefined)
})

labels.forEach((label) => console.log("ok  " + label))
MODEL

node "$TMP/model-test.js" "$ROOT/Model.js" || fail "model assertions"

# ---- helper -----------------------------------------------------------------

run_helper status
expect_error "Credential unavailable. Unlock Secret Service or reconnect." \
  "status without a stored credential"
[[ $(field configured) != True ]] || fail "status claimed a credential it does not have"
ok "status without a stored credential fails closed"

before=$(requests)
run_helper login "{\"serverUrl\":\"$ORIGIN\",\"apiKey\":\"badkey\"}"
expect_error "Karakeep rejected that API key." "login with an invalid key"
[[ ! -f $STORE ]] || fail "a rejected key was written to the keyring"
[[ $(requests) -gt $before ]] || fail "login never validated against the server"
ok "invalid login is rejected and stores nothing"

run_helper login "{\"serverUrl\":\"$ORIGIN\",\"apiKey\":\"scopekey\"}"
expect_error "That API key is missing the users:read scope. Add it in Karakeep under Settings > API Keys." \
  "login with a key missing a scope"
[[ ! -f $STORE ]] || fail "a scope-rejected key was written to the keyring"
ok "a missing scope is named on login"

# The trailing /api/v1/ proves the helper stores an origin, not a base URL.
run_helper login "{\"serverUrl\":\"http://127.0.0.1:$PORT/api/v1/\",\"apiKey\":\"$FAKE_KEY\"}"
[[ $(field ok) == True ]] || fail "valid login failed: $(field error)"
[[ $(field configured) == True ]] || fail "valid login did not report a configured connection"
[[ $(field serverUrl) == "$ORIGIN" ]] || fail "login returned $(field serverUrl) instead of $ORIGIN"
[[ -f $STORE ]] || fail "valid login stored no keyring item"
[[ $(<"$STORE") == "{\"serverUrl\":\"$ORIGIN\",\"apiKey\":\"$FAKE_KEY\"}" ]] ||
  fail "the stored secret is not the expected compact connection JSON"
ok "valid login canonicalizes the origin and stores one compact secret"

run_helper status
[[ $(field ok) == True ]] || fail "status failed with a stored credential: $(field error)"
[[ $(field configured) == True ]] || fail "status did not report the stored connection"
[[ $(field serverUrl) == "$ORIGIN" ]] || fail "status returned the wrong server URL"
[[ $HOUT != *apiKey* ]] || fail "status returned an apiKey field"
ok "status returns only the canonical server URL and configured flag"

for bad in \
  'not json at all' \
  '{"serverUrl":"http://example.com","apiKey":"goodkey"}' \
  "{\"serverUrl\":\"$ORIGIN\",\"apiKey\":\"bad key with space\"}" \
  "{\"serverUrl\":\"$ORIGIN\"}" \
  "{\"serverUrl\":\"$ORIGIN\",\"apiKey\":\"$FAKE_KEY\",\"extra\":1}"; do
  printf '%s' "$bad" >"$STORE"
  before=$(requests)
  run_helper status
  expect_error "Credential unavailable. Unlock Secret Service or reconnect." \
    "status with malformed stored data"
  expect_no_request "$before" "status sent a request with malformed stored data"
  run_helper add '{"type":"text","text":"buy milk"}'
  expect_error "Credential unavailable. Unlock Secret Service or reconnect." \
    "add with malformed stored data"
  expect_no_request "$before" "add sent a request with malformed stored data"
done

# A keyring item is arbitrary bytes, so an undecodable secret must fail closed
# rather than raise out of the locale decode and abandon the result channel.
printf '\xff\xfe{"serverUrl":"x"}' >"$STORE"
before=$(requests)
run_helper status
expect_error "Credential unavailable. Unlock Secret Service or reconnect." \
  "status with an undecodable stored secret"
expect_no_request "$before" "status sent a request with an undecodable stored secret"
ok "malformed, non-HTTPS and invalid stored credentials fail closed"

printf '%s' "{\"serverUrl\":\"$ORIGIN\",\"apiKey\":\"$FAKE_KEY\"}" >"$STORE"

: >"$RECORD"
run_helper add '{"type":"text","text":"buy milk"}'
[[ $(field ok) == True ]] || fail "text add failed: $(field error)"
[[ $(field id) == bk_123 ]] || fail "text add returned id $(field id)"
[[ $(field existing) == False ]] || fail "a created entry was reported as existing"

run_helper add '{"type":"link","url":"https://example.com/article"}'
[[ $(field ok) == True ]] || fail "link add failed: $(field error)"
[[ $(field id) == bk_123 ]] || fail "link add returned id $(field id)"

run_helper add '{"type":"link","url":"https://existing.example"}'
[[ $(field ok) == True ]] || fail "duplicate link add failed: $(field error)"
[[ $(field id) == bk_existing ]] || fail "duplicate add returned id $(field id)"
[[ $(field existing) == True ]] || fail "a duplicate link was not reported as existing"

"$PY" - "$RECORD" <<'CHECK' || fail "add requests did not carry the exact expected bodies and headers"
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
want = [
    '{"type":"text","text":"buy milk"}',
    '{"type":"link","url":"https://example.com/article"}',
    '{"type":"link","url":"https://existing.example"}',
]
assert len(rows) == 3, rows
for row, body in zip(rows, want):
    assert row["path"] == "/api/v1/bookmarks", row["path"]
    assert row["auth"] == "Bearer goodkey", "wrong bearer header"
    assert row["ctype"] == "application/json", row["ctype"]
    assert row["accept"] == "application/json", row["accept"]
    assert row["body"] == body, (row["body"], body)
CHECK
ok "text and link adds send exact bodies with the bearer header"

run_helper add '{"type":"link","url":"https://reject.example"}'
expect_error "Karakeep rejected that entry." "an API 400"
[[ $HOUT != *"buy milk"* ]] || fail "the API's rejection message was forwarded"

printf '%s' "{\"serverUrl\":\"$ORIGIN\",\"apiKey\":\"stalekey\"}" >"$STORE"
run_helper add '{"type":"text","text":"buy milk"}'
expect_error "Karakeep rejected the stored API key. Reconnect to update it." "an API 401 on add"
ok "API 400 and 401 return fixed text instead of server-controlled detail"

printf '%s' "{\"serverUrl\":\"$ORIGIN\",\"apiKey\":\"scopekey\"}" >"$STORE"
run_helper add '{"type":"text","text":"buy milk"}'
expect_error "The stored API key is missing the bookmarks:readwrite scope. Add it in Karakeep, then reconnect." \
  "an API 403 naming a scope on add"
[[ $HOUT != *"secret detail"* ]] || fail "text around the scope name was forwarded"
ok "a missing scope is named on add without leaking the rest of the body"

before=$(requests)
run_helper login "{\"serverUrl\":\"$ORIGIN\",\"apiKey\":\"redirectkey\"}"
expect_error "Karakeep redirected the API request. Use the final HTTPS server address." \
  "a redirected validation request"
[[ ! -f $REACHED ]] || fail "the redirect destination was reached"
[[ $(requests) -gt $before ]] || fail "the redirect case never reached the stub"
ok "a redirect is rejected and its destination is never reached"

run_helper login "{\"serverUrl\":\"$ORIGIN\",\"apiKey\":\"truncatekey\"}"
expect_error "Could not securely reach $ORIGIN." "an interrupted response body"
ok "an interrupted response body returns a fixed error, not a traceback"

while IFS='|' read -r candidate expected; do
  [[ -n $expected ]] || continue
  before=$(requests)
  run_helper login "{\"serverUrl\":\"$candidate\",\"apiKey\":\"$FAKE_KEY\"}"
  expect_error "$expected" "login with server address '$candidate'"
  expect_no_request "$before" "login contacted a server for '$candidate'"
done <<ORIGINS
http://karakeep.lan|Karakeep API keys require HTTPS. Configure TLS on the self-hosted server.
http://192.168.1.10:3000|Karakeep API keys require HTTPS. Configure TLS on the self-hosted server.
https://user:pw@example.com|Enter a valid Karakeep server address.
https://example.com/?token=x|Enter a valid Karakeep server address.
https://example.com/#frag|Enter a valid Karakeep server address.
https://example.com/other/path|Enter a valid Karakeep server address.
https://exa mple.com|Enter a valid Karakeep server address.
https://example.com:99999|Enter a valid Karakeep server address.
https://example.com:0|Enter a valid Karakeep server address.
|Enter your Karakeep server address.
ORIGINS
ok "unsafe and malformed server addresses are refused before any request"

# The .invalid TLD never resolves, so the fixed transport error names the
# origin the helper actually built.
run_helper login "{\"serverUrl\":\"karakeep.invalid\",\"apiKey\":\"$FAKE_KEY\"}"
[[ $(field ok) == False ]] || fail "an unresolvable bare host appeared to connect"
[[ $(field error) == *"https://karakeep.invalid"* ]] ||
  fail "a bare host was not upgraded to HTTPS: $(field error)"
ok "a bare host is upgraded to HTTPS"

before=$(requests)
run_helper login "{\"serverUrl\":\"https://127.0.0.1:$PORT\",\"apiKey\":\"$FAKE_KEY\"}"
[[ $(field ok) == False ]] || fail "HTTPS against an HTTP-only server appeared to succeed"
case $(field error) in
"TLS verification failed for https://127.0.0.1:$PORT.") ;;
"Could not securely reach https://127.0.0.1:$PORT.") ;;
*) fail "HTTPS transport failure returned: $(field error)" ;;
esac
ok "a failed TLS handshake returns a fixed error with no exception detail"

# 192.0.2.9 is RFC 5737 unroutable: reaching the origin proves the bearer token
# never went to the proxy urllib would otherwise honour for a loopback origin.
before=$(requests)
HELPER_EXTRA_ENV=(http_proxy=http://192.0.2.9:8080 https_proxy=http://192.0.2.9:8080
  HTTP_PROXY=http://192.0.2.9:8080 ALL_PROXY=http://192.0.2.9:8080)
run_helper login "{\"serverUrl\":\"$ORIGIN\",\"apiKey\":\"$FAKE_KEY\"}"
HELPER_EXTRA_ENV=()
[[ $(field ok) == True ]] || fail "a configured proxy diverted the request: $(field error)"
[[ $(requests) -gt $before ]] || fail "the request did not reach the origin directly"
ok "an environment proxy never carries the credential"

printf '%s' "{\"serverUrl\":\"$ORIGIN\",\"apiKey\":\"$FAKE_KEY\"}" >"$STORE"
run_helper clear
[[ $(field ok) == True ]] || fail "clear failed: $(field error)"
[[ $(field configured) == False ]] || fail "clear still reports a configured connection"
[[ ! -f $STORE ]] || fail "clear left the keyring item in place"
run_helper status
expect_error "Credential unavailable. Unlock Secret Service or reconnect." "status after clear"
before=$(requests)
run_helper add '{"type":"text","text":"buy milk"}'
expect_error "Credential unavailable. Unlock Secret Service or reconnect." "add after clear"
expect_no_request "$before" "add contacted the server after clear"
ok "clear removes the credential and later actions fail closed"

run_no_secret_tool() {
  set +e
  printf '%s\n' "${2-}" |
    env -i PATH="$TMP/empty" HOME="$TMP/home" "$PY" "$HELPER" "$1" \
      >"$TMP/out" 2>"$TMP/err"
  HRC=$?
  set -e
  HOUT=$(<"$TMP/out")
  HERR=$(<"$TMP/err")
  assert_result_contract "$1 with no secret-tool"
}

# Validation still succeeds against the stub, but there is nowhere safe to put
# the credential, so login must report a storage failure rather than fall back.
run_no_secret_tool login "{\"serverUrl\":\"$ORIGIN\",\"apiKey\":\"$FAKE_KEY\"}"
expect_error "Could not store the API key. Unlock Secret Service and try again." \
  "login with no secret-tool present"

before=$(requests)
run_no_secret_tool add '{"type":"text","text":"buy milk"}'
expect_error "Credential unavailable. Unlock Secret Service or reconnect." \
  "add with no secret-tool present"
run_no_secret_tool clear
expect_error "Could not remove the API key. Unlock Secret Service and try again." \
  "clear with no secret-tool present"
expect_no_request "$before" "an action reached the server with no secret-tool present"
[[ -z $(find "$TMP/home" -type f -print -quit) ]] ||
  fail "a plaintext credential file was written as a fallback"
ok "with no secret-tool the helper fails closed and writes no plaintext"

# latin-1 header encoding would otherwise raise UnicodeEncodeError out of
# http.client as a traceback on stderr, which assert_result_contract catches.
printf '%s' "{\"serverUrl\":\"$ORIGIN\",\"apiKey\":\"$FAKE_KEY\"}" >"$STORE"
before=$(requests)
run_helper login "{\"serverUrl\":\"$ORIGIN\",\"apiKey\":\"ak1_\\u20ac\"}"
expect_error "Enter a valid Karakeep API key." "a non-ASCII API key"
expect_no_request "$before" "a non-ASCII API key reached the server"
ok "a non-ASCII API key is rejected before any request"

run_argv() {
  set +e
  env PATH="$TMP/bin:/usr/bin:/bin" SECRET_TOOL_TEST_STORE="$STORE" HOME="$TMP/home" \
    "$HELPER" "$@" >"$TMP/out" 2>"$TMP/err" </dev/null
  HRC=$?
  set -e
  HOUT=$(<"$TMP/out")
}

# QML reads stdout as the whole result, so a malformed invocation must never
# pair a nonzero exit with a parseable result — or a zero exit with none.
before=$(requests)
for bad in "an unknown action:bogus" "a surplus argument:status extra" "a missing action:"; do
  run_argv ${bad#*:}
  [[ $HRC -ne 0 ]] || fail "${bad%%:*} exited 0 instead of failing loudly"
  [[ -z $HOUT ]] || fail "${bad%%:*} wrote a result to stdout"
done
expect_no_request "$before" "a malformed invocation contacted the server"
ok "a malformed invocation fails loudly with no result on stdout"

echo "karakeep tests passed"
