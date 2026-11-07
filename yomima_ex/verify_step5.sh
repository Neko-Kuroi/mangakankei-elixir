#!/bin/bash
# 手順5（Discord・マイリスト・共有・作品登録）の検証。
# 前提: platform :8000（seed.py + seed_step3.py + seed_step5.py 適用済み）、
#       Elixir 閲覧側 :8001、Python 閲覧側 :8002 が起動していること。
E=http://127.0.0.1:8001
P=http://127.0.0.1:8002
CBZ501=http://127.0.0.1:8000/api/public/cbz/1/501/1.cbz
CBZ506=http://127.0.0.1:8000/api/public/cbz/1/506/1.cbz
CBZ507=http://127.0.0.1:8000/api/public/cbz/1/507/1.cbz
WORK=$(mktemp -d)
PASS=0; FAIL=0
PW=$(printf 'password%s' 123)

check() { if [ "$2" == "$3" ]; then echo "PASS: $1"; PASS=$((PASS+1));
  else echo "FAIL: $1 (expected [$2] got [$3])"; FAIL=$((FAIL+1)); fi; }
has() { if grep -q "$2" "$1"; then echo "1"; else echo "0"; fi; }
session() { curl -s -G "$1/session" --data-urlencode "url=$2" | python3 -c "import json,sys; print(json.load(sys.stdin)['session_token'])"; }
download() { curl -sN -G "$1/download/start" --data-urlencode "url=$2" --data-urlencode "session_token=$3" --max-time 60 | grep -q "data: done"; }
norm() { sed -E 's/datetime="[0-9]+"/datetime="T"/g' "$1" | sed 's/[[:space:]]*$//' | grep -v '^$'; }
push_share() { grep -i '^hx-push-url:' "$1" | tr -d '\r' | sed 's/^[^:]*: //' | sed 's|^/?share=||'; }
entries() { python3 -c "
import base64, json, sys
s = sys.argv[1]
s += '=' * (-len(s) % 4)
d = json.loads(base64.urlsafe_b64decode(s))
print('\n'.join(e['url'] + '|' + e['title'] for e in d['manga_urls']))
" "$1"; }
add() { # $1=base $2=url $3=share $4=body $5=headers
  curl -s -X POST "$1/manga/add" --data-urlencode "url=$2" --data-urlencode "share=$3" -o "$4" -D "$5" -w "%{http_code}"
}
remove_manga() { # $1=base $2=url $3=share $4=body $5=headers
  curl -s -X POST "$1/manga/remove" --data-urlencode "url=$2" --data-urlencode "share=$3" -o "$4" -D "$5" -w "%{http_code}"
}

echo "== A. ホーム画面 =="
curl -s "$E/" -o "$WORK/home_e.html" -w "%{http_code}" > "$WORK/code_e"
curl -s "$P/" -o "$WORK/home_p.html" -w "%{http_code}" > "$WORK/code_p"
check "home status Elixir" "200" "$(cat $WORK/code_e)"
check "home status Python" "200" "$(cat $WORK/code_p)"
for kw in "アーカイブを追加" "マンガがまだありません" 'id="share-param"' 'id="new-url"'; do
  check "home contains [$kw] Elixir" "1" "$(has $WORK/home_e.html "$kw")"
  check "home contains [$kw] Python" "1" "$(has $WORK/home_p.html "$kw")"
done
PYMADE="eyJtYW5nYV91cmxzIjogW3sidXJsIjogImh0dHBzOi8vZXhhbXBsZS5jb20vYS56aXAiLCAidGl0bGUiOiAiXHU0ZjVjXHU1NGMxQSIsICJhZGRlZF90aW1lIjogMTcwMDAwMDAwMC41fSwgeyJ1cmwiOiAiaHR0cHM6Ly9leGFtcGxlLmNvbS9iLmNieiIsICJ0aXRsZSI6ICJiLmNieiIsICJhZGRlZF90aW1lIjogMTcwMDAwMDEwMC4yNX1dLCAiZXhwb3J0X3RpbWUiOiAxNzk0MDI4OTM0LjI3OTY2ODh9"
curl -s -G "$E/" --data-urlencode "share=$PYMADE" -o "$WORK/home_share_e.html"
curl -s -G "$P/" --data-urlencode "share=$PYMADE" -o "$WORK/home_share_p.html"
check "shared list title A Elixir" "1" "$(has $WORK/home_share_e.html '作品A')"
check "shared list title A Python" "1" "$(has $WORK/home_share_p.html '作品A')"
check "shared list title B Elixir" "1" "$(has $WORK/home_share_e.html 'b.cbz')"
curl -s -G "$E/" --data-urlencode "share=!!!invalid!!!" -o "$WORK/home_bad_e.html"
curl -s -G "$P/" --data-urlencode "share=!!!invalid!!!" -o "$WORK/home_bad_p.html"
check "invalid share message Elixir" "1" "$(has $WORK/home_bad_e.html 'デコードエラー')"
check "invalid share message Python" "1" "$(has $WORK/home_bad_p.html 'デコードエラー')"

echo "== B. 追加フロー =="
CODE=$(add "$E" "$CBZ506" "" "$WORK/b_e.html" "$WORK/b_e.hdr"); check "add status Elixir" "200" "$CODE"
CODE=$(add "$P" "$CBZ506" "" "$WORK/b_p.html" "$WORK/b_p.hdr"); check "add status Python" "200" "$CODE"
norm "$WORK/b_e.html" > "$WORK/b_e.norm"; norm "$WORK/b_p.html" > "$WORK/b_p.norm"
if diff -q "$WORK/b_e.norm" "$WORK/b_p.norm" > /dev/null; then check "add partial identical" "yes" "yes";
else check "add partial identical" "yes" "no"; diff "$WORK/b_e.norm" "$WORK/b_p.norm" | head -8; fi
SHARE_E=$(push_share "$WORK/b_e.hdr"); SHARE_P=$(push_share "$WORK/b_p.hdr")
check "add share entries equal" "$(entries "$SHARE_P")" "$(entries "$SHARE_E")"
CODE=$(add "$E" "$CBZ506" "$SHARE_E" "$WORK/b2_e.html" "$WORK/b2_e.hdr")
CODE=$(add "$P" "$CBZ506" "$SHARE_P" "$WORK/b2_p.html" "$WORK/b2_p.hdr")
check "duplicate message Elixir" "1" "$(has $WORK/b2_e.html 'このURLはすでに追加されています')"
check "duplicate message Python" "1" "$(has $WORK/b2_p.html 'このURLはすでに追加されています')"
add "$E" "https://203.0.113.10/f.txt" "" "$WORK/b3_e.html" "$WORK/b3_e.hdr" > /dev/null
add "$P" "https://203.0.113.10/f.txt" "" "$WORK/b3_p.html" "$WORK/b3_p.hdr" > /dev/null
check "bad-ext message Elixir" "1" "$(has $WORK/b3_e.html 'URLは .zip / .cbz / .rar / .cbr である必要があります')"
check "bad-ext message Python" "1" "$(has $WORK/b3_p.html 'URLは .zip / .cbz / .rar / .cbr である必要があります')"
add "$E" "http://192.168.9.9/x.zip" "" "$WORK/b4_e.html" "$WORK/b4_e.hdr" > /dev/null
add "$P" "http://192.168.9.9/x.zip" "" "$WORK/b4_p.html" "$WORK/b4_p.hdr" > /dev/null
check "blocked message Elixir" "1" "$(has $WORK/b4_e.html '内部アドレスへの取得は許可されていません')"
check "blocked message Python" "1" "$(has $WORK/b4_p.html '内部アドレスへの取得は許可されていません')"

echo "== C. 削除フロー =="
add "$E" "https://203.0.113.10/f01.zip" "$SHARE_E" "$WORK/c0_e.html" "$WORK/c0_e.hdr" > /dev/null
SHARE_E2=$(push_share "$WORK/c0_e.hdr")
add "$P" "https://203.0.113.10/f01.zip" "$SHARE_P" "$WORK/c0_p.html" "$WORK/c0_p.hdr" > /dev/null
SHARE_P2=$(push_share "$WORK/c0_p.hdr")
remove_manga "$E" "https://203.0.113.10/f01.zip" "$SHARE_E2" "$WORK/c1_e.html" "$WORK/c1_e.hdr" > /dev/null
remove_manga "$P" "https://203.0.113.10/f01.zip" "$SHARE_P2" "$WORK/c1_p.html" "$WORK/c1_p.hdr" > /dev/null
norm "$WORK/c1_e.html" > "$WORK/c1_e.norm"; norm "$WORK/c1_p.html" > "$WORK/c1_p.norm"
if diff -q "$WORK/c1_e.norm" "$WORK/c1_p.norm" > /dev/null; then check "remove partial identical" "yes" "yes";
else check "remove partial identical" "yes" "no"; diff "$WORK/c1_e.norm" "$WORK/c1_p.norm" | head -8; fi
SHARE_E3=$(push_share "$WORK/c1_e.hdr")
remove_manga "$E" "$CBZ506" "$SHARE_E3" "$WORK/c2_e.html" "$WORK/c2_e.hdr" > /dev/null
check "remove-all empty state" "1" "$(has $WORK/c2_e.html 'マンガがまだありません')"
check "remove-all push url is /" "/" "$(grep -i '^hx-push-url:' $WORK/c2_e.hdr | tr -d '\r' | sed 's/^[^:]*: //')"

echo "== D. 上限（12件） =="
SHARE_D=""
for i in 01 02 03 04 05 06 07 08 09 10 11 12; do
  add "$E" "https://203.0.113.10/f$i.zip" "$SHARE_D" "$WORK/d_e.html" "$WORK/d_e.hdr" > /dev/null
  SHARE_D=$(push_share "$WORK/d_e.hdr")
done
check "12 items is full Elixir" "1" "$(has $WORK/d_e.html 'リストが満杯です')"
add "$E" "https://203.0.113.10/f13.zip" "$SHARE_D" "$WORK/d13_e.html" "$WORK/d13_e.hdr" > /dev/null
check "13th refused Elixir" "1" "$(has $WORK/d13_e.html '最大 12 件まで登録できます')"
SHARE_D=""
for i in 01 02 03 04 05 06 07 08 09 10 11 12; do
  add "$P" "https://203.0.113.10/f$i.zip" "$SHARE_D" "$WORK/d_p.html" "$WORK/d_p.hdr" > /dev/null
  SHARE_D=$(push_share "$WORK/d_p.hdr")
done
add "$P" "https://203.0.113.10/f13.zip" "$SHARE_D" "$WORK/d13_p.html" "$WORK/d13_p.hdr" > /dev/null
check "13th refused Python" "1" "$(has $WORK/d13_p.html '最大 12 件まで登録できます')"

echo "== E. 共有の相互運用 =="
curl -s -G "$P/" --data-urlencode "share=$SHARE_E2" -o "$WORK/e2p.html"
check "elixir share opens on Python (1.cbz)" "1" "$(has $WORK/e2p.html '1.cbz')"
check "elixir share opens on Python (f01)" "1" "$(has $WORK/e2p.html 'f01.zip')"
curl -s -G "$E/" --data-urlencode "share=$SHARE_P2" -o "$WORK/e2e.html"
check "python share opens on Elixir (1.cbz)" "1" "$(has $WORK/e2e.html '1.cbz')"
check "python share opens on Elixir (f01)" "1" "$(has $WORK/e2e.html 'f01.zip')"

echo "== F. /share/url =="
R=$(curl -s -G "$E/share/url" --data-urlencode "share=abc def" --data-urlencode "shorten=false")
check "share/url no-shorten Elixir" "http://127.0.0.1:8001/?share=abc%20def" "$R"
R=$(curl -s -G "$P/share/url" --data-urlencode "share=abc def" --data-urlencode "shorten=false")
check "share/url no-shorten Python" "http://127.0.0.1:8002/?share=abc%20def" "$R"
for pair in "$E 8001" "$P 8002"; do
  set -- $pair
  R=$(curl -s -G "$1/share/url" --data-urlencode "share=xyz" --data-urlencode "shorten=true")
  case "$R" in
    "http://127.0.0.1:$2/?share=xyz") check "share/url shorten fallback ($2)" "yes" "yes";;
    https://tinyurl.com/*) check "share/url shorten fallback ($2)" "yes" "yes";;
    *) check "share/url shorten fallback ($2)" "yes" "no: $R";;
  esac
done

echo "== G. Discord 送信 =="
TOK_E501=$(session "$E" "$CBZ501"); TOK_P501=$(session "$P" "$CBZ501")
TOK_E507=$(session "$E" "$CBZ507"); TOK_P507=$(session "$P" "$CBZ507")
download "$E" "$CBZ507" "$TOK_E507"; check "Elixir download 507" "0" "$?"
download "$P" "$CBZ507" "$TOK_P507"; check "Python download 507" "0" "$?"
# 展開は /images の初回アクセスで走る（ダウンロードだけでは展開されない）
curl -s -G "$E/images" --data-urlencode "url=$CBZ507" --data-urlencode "session_token=$TOK_E507" -o /dev/null
curl -s -G "$P/images" --data-urlencode "url=$CBZ507" --data-urlencode "session_token=$TOK_P507" -o /dev/null
FAKE_WH="https://discord.com/api/webhooks/123456789012345678/faketoken"
dsend() { # $1=base $2=url $3=filename $4=webhook1 $5=token $6=out
  curl -s -F "url=$2" -F "filename=$3" -F "webhook1=$4" -F "webhook2=" -F "session_token=$5" "$1/discord/send" -o "$6" -w "%{http_code}"
}
CODE=$(dsend "$E" "$CBZ507" "00000_page01.png" "$FAKE_WH" "bogus-token" "$WORK/g1_e.html")
check "discord bad session Elixir" "1" "$(has $WORK/g1_e.html 'セッションが無効です')"
CODE=$(dsend "$P" "$CBZ507" "00000_page01.png" "$FAKE_WH" "bogus-token" "$WORK/g1_p.html")
check "discord bad session Python" "1" "$(has $WORK/g1_p.html 'セッションが無効です')"
dsend "$E" "$CBZ501" "00000_page01.png" "$FAKE_WH" "$TOK_E501" "$WORK/g2_e.html" > /dev/null
dsend "$P" "$CBZ501" "00000_page01.png" "$FAKE_WH" "$TOK_P501" "$WORK/g2_p.html" > /dev/null
check "discord not-enabled Elixir" "1" "$(has $WORK/g2_e.html 'この作品では Discord 送信が許可されていません')"
check "discord not-enabled Python" "1" "$(has $WORK/g2_p.html 'この作品では Discord 送信が許可されていません')"
dsend "$E" "$CBZ507" ".." "$FAKE_WH" "$TOK_E507" "$WORK/g3_e.html" > /dev/null
dsend "$P" "$CBZ507" ".." "$FAKE_WH" "$TOK_P507" "$WORK/g3_p.html" > /dev/null
check "discord bad filename Elixir" "1" "$(has $WORK/g3_e.html '不正なファイル名です')"
check "discord bad filename Python" "1" "$(has $WORK/g3_p.html '不正なファイル名です')"
dsend "$E" "$CBZ507" "00000_page01.png" "" "$TOK_E507" "$WORK/g4_e.html" > /dev/null
dsend "$P" "$CBZ507" "00000_page01.png" "" "$TOK_P507" "$WORK/g4_p.html" > /dev/null
check "discord no webhook Elixir" "1" "$(has $WORK/g4_e.html 'Webhookが設定されていません')"
check "discord no webhook Python" "1" "$(has $WORK/g4_p.html 'Webhookが設定されていません')"
dsend "$E" "$CBZ507" "00000_page01.png" "https://example.com/api/webhooks/x" "$TOK_E507" "$WORK/g5_e.html" > /dev/null
dsend "$P" "$CBZ507" "00000_page01.png" "https://example.com/api/webhooks/x" "$TOK_P507" "$WORK/g5_p.html" > /dev/null
check "discord non-discord webhook Elixir" "1" "$(has $WORK/g5_e.html 'Webhook URL は Discord のものだけ使えます')"
check "discord non-discord webhook Python" "1" "$(has $WORK/g5_p.html 'Webhook URL は Discord のものだけ使えます')"
dsend "$E" "$CBZ507" "00000_page01.png" "$FAKE_WH" "$TOK_E507" "$WORK/g6_e.html" > /dev/null
dsend "$P" "$CBZ507" "00000_page01.png" "$FAKE_WH" "$TOK_P507" "$WORK/g6_p.html" > /dev/null
check "discord send-error shape Elixir" "1" "$(has $WORK/g6_e.html 'Discord送信エラー (https://discord.com/api/webhooks/1234567...)')"
check "discord send-error shape Python" "1" "$(has $WORK/g6_p.html 'Discord送信エラー (https://discord.com/api/webhooks/1234567...)')"

echo "== H. multipart ログイン（ブラウザの FormData 相当） =="
CODE=$(curl -s -F "username=spike_reader" -F "password=$PW" "$E/auth/login" -o /dev/null -w "%{http_code}")
check "multipart login Elixir" "200" "$CODE"
CODE=$(curl -s -F "username=spike_reader" -F "password=$PW" "$P/auth/login" -o /dev/null -w "%{http_code}")
check "multipart login Python" "200" "$CODE"

echo
echo "RESULT: $PASS passed, $FAIL failed"
