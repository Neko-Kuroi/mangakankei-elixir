#!/bin/bash
# /thumbnail が外部ホストへ内部トークンを送らず、HTML も素通ししないことの実地検証。
# 事前に閲覧側(:8001)を次の環境変数つきで起動しておくこと:
#   PLATFORM_BASE_URL=http://127.0.0.1:8000   （外部ホスト役の :9100 とは別にする）
#   MANGA_INTERNAL_TOKEN=SECRET-INTERNAL-TOKEN
#   MANGA_URL_ALLOW_HOSTS=127.0.0.1           （:9100 を「許可された外部ホスト」にするため）
# 外部ホスト役の小さなサーバー(:9100)はこのスクリプトが起動・停止する。
V=http://127.0.0.1:8001
EXT=http://127.0.0.1:9100
LOG=$(mktemp)
PASS=0; FAIL=0
check() { # name expected actual
  if [ "$2" == "$3" ]; then echo "PASS: $1"; PASS=$((PASS+1));
  else echo "FAIL: $1 (expected [$2] got [$3])"; FAIL=$((FAIL+1)); fi
}

python3 - "$LOG" <<'PY' &
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
log = sys.argv[1]
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        with open(log, "a") as f:
            f.write(f"{self.path} token={self.headers.get('x-internal-token')}\n")
        body = b"<script>alert(1)</script>"
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass
HTTPServer(("127.0.0.1", 9100), H).serve_forever()
PY
STUB=$!
trap 'kill $STUB 2>/dev/null; rm -f "$LOG"' EXIT
sleep 1

URL="$EXT/api/public/cbz/1/2/3.cbz"
TOKEN=$(curl -s --get --data-urlencode "url=$URL" "$V/session" \
  | python3 -c "import json,sys; print(json.load(sys.stdin).get('session_token',''))")
check "session for allowed external host" "yes" "$([ -n "$TOKEN" ] && echo yes || echo no)"

HDR=$(mktemp)
BODY=$(curl -s -D "$HDR" --get --data-urlencode "url=$URL" --data-urlencode "index=0" \
  --data-urlencode "session_token=$TOKEN" "$V/thumbnail")
CT=$(grep -i '^content-type:' "$HDR" | tr -d '\r' | sed 's/^[^:]*: *//' | cut -d';' -f1 | tr 'A-Z' 'a-z')
NOSNIFF=$(grep -i '^x-content-type-options:' "$HDR" | tr -d '\r' | sed 's/^[^:]*: *//')
rm -f "$HDR"

check "external host received no thumb request" "0" "$(grep -c '^/api/public/thumb/' "$LOG")"
check "internal token never sent to external host" "0" "$(grep -c 'token=SECRET' "$LOG")"
check "HTML is not relayed (no <script> in body)" "0" "$(echo "$BODY" | grep -c '<script>')"
check "response is not text/html" "no" "$([ "$CT" == "text/html" ] && echo yes || echo no)"
# 画像を返した場合だけ nosniff を確認する（外部の作品は未ダウンロードなら 404 の JSON になる）
case "$CT" in image/*) check "nosniff header on image response" "nosniff" "$NOSNIFF" ;; esac

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
