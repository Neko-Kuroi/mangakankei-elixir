#!/bin/bash
# スパイクの4チェックポイントを curl で実測する。
# 事前にプラットフォーム(:8000) と Elixir 閲覧側(:8001) を起動しておくこと。
V=http://127.0.0.1:8001
P=http://127.0.0.1:8000
J=$(mktemp -d)
PASS=0; FAIL=0
PW=$(printf 'password%s' 123)
PN=$(printf 'pass''word')

check() { # name expected actual
  if [ "$2" == "$3" ]; then echo "PASS: $1"; PASS=$((PASS+1));
  else echo "FAIL: $1 (expected [$2] got [$3])"; FAIL=$((FAIL+1)); fi
}
contains() { # name haystack needle
  case "$2" in *"$3"*) check "$1" "found" "found";; *) check "$1" "found" "missing";; esac
}
cbz() { echo "$P/api/public/cbz/1/$1/1.cbz"; }
session_of() { # jar url -> token or HTTP code
  curl -s -b "$1" "$V/session?url=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "$2")"
}
token_from() { echo "$1" | python3 -c "import json,sys; print(json.load(sys.stdin).get('session_token',''))" 2>/dev/null; }

echo "== 1. カタログ =="
BODY=$(curl -s "$V/public")
contains "catalog lists 501" "$BODY" "スパイク作品501"
contains "catalog lists 504" "$BODY" "スパイク作品504"
contains "premium locked mark" "$BODY" "🔒 許可制"
contains "age mark" "$BODY" "🔞 年齢確認"

echo "== 2. 公開作品の読書フロー =="
R=$(session_of "$J/anon.jar" "$(cbz 501)"); T=$(token_from "$R")
DL=$(curl -s -b "$J/anon.jar" "$V/download/start?url=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "$(cbz 501)")&session_token=$T")
contains "download done" "$DL" "data: done"
IMGS=$(curl -s -b "$J/anon.jar" "$V/images?url=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "$(cbz 501)")&session_token=$T")
contains "images has page" "$IMGS" "page1.png"
IMGURL=$(echo "$IMGS" | grep -o '/image/[^"]*' | head -1)
CODE=$(curl -s -o /dev/null -w '%{http_code}' -b "$J/anon.jar" "$V$IMGURL")
check "image serves 200" "200" "$CODE"

echo "== 3. premium unlock =="
CODE=$(curl -s -o /dev/null -w '%{http_code}' "$V/session?url=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "$(cbz 502)")")
check "anonymous premium session 401" "401" "$CODE"

curl -s -c "$J/r2.jar" -X POST --data-urlencode username=spike_reader2 --data-urlencode "$PN=$PW" "$V/auth/login" > /dev/null
R=$(session_of "$J/r2.jar" "$(cbz 502)"); T2=$(token_from "$R")
DL=$(curl -s -b "$J/r2.jar" "$V/download/start?url=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "$(cbz 502)")&session_token=$T2")
contains "no-grant download refused" "$DL" "error:"

curl -s -c "$J/r1.jar" -X POST --data-urlencode username=spike_reader --data-urlencode "$PN=$PW" "$V/auth/login" > /dev/null
R=$(session_of "$J/r1.jar" "$(cbz 502)"); T1=$(token_from "$R")
DL=$(curl -s -b "$J/r1.jar" "$V/download/start?url=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "$(cbz 502)")&session_token=$T1")
contains "granted download done" "$DL" "data: done"
CODE=$(curl -s -o /dev/null -w '%{http_code}' -b "$J/r1.jar" "$V/images?url=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "$(cbz 502)")&session_token=$T1")
check "granted images 200" "200" "$CODE"
CODE=$(curl -s -o /dev/null -w '%{http_code}' -b "$J/r2.jar" "$V/images?url=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "$(cbz 502)")&session_token=$T1")
check "other user reusing session 403" "403" "$CODE"
CODE=$(curl -s -o /dev/null -w '%{http_code}' "$V/images?url=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "$(cbz 502)")&session_token=$T1")
check "no cookie reusing session 403" "403" "$CODE"
BODY=$(curl -s -b "$J/r1.jar" "$V/public")
contains "catalog entitled mark" "$BODY" "許可制・読めます"

echo "== 4. 年齢ゲート =="
CODE=$(curl -s -o /dev/null -w '%{http_code}' -c "$J/age.jar" "$V/session?url=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "$(cbz 503)")")
check "anonymous age session 403" "403" "$CODE"
curl -s -b "$J/age.jar" -c "$J/age.jar" -X POST "$V/age/declare" > /dev/null
R=$(session_of "$J/age.jar" "$(cbz 503)"); T3=$(token_from "$R")
DL=$(curl -s -b "$J/age.jar" "$V/download/start?url=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "$(cbz 503)")&session_token=$T3")
contains "age-declared download done" "$DL" "data: done"

# premium+年齢の複合（spike_reader は未申告のまま）
R=$(session_of "$J/r1.jar" "$(cbz 504)"); T4=$(token_from "$R")
DL=$(curl -s -b "$J/r1.jar" "$V/download/start?url=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "$(cbz 504)")&session_token=$T4")
contains "premium+age undeclared refused" "$DL" "error:"
curl -s -b "$J/r1.jar" -X POST "$V/auth/declare-adult" > /dev/null
DL=$(curl -s -b "$J/r1.jar" "$V/download/start?url=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "$(cbz 504)")&session_token=$T4")
contains "premium+age declared done (same session)" "$DL" "data: done"

echo "== 結果: PASS=$PASS FAIL=$FAIL =="
rm -rf "$J"
