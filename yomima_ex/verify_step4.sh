#!/bin/bash
# 手順4（サムネイル取得失敗時のフォールバック生成）の検証。
# 前提: platform :8000（seed.py + seed_step3.py 適用済み）、
#       Elixir 閲覧側 :8001、Python 閲覧側 :8002 が起動していること。
# プラットフォームの episode_1_thumbs を一時的に退避してフォールバックを
# 発火させ、終了時に必ず復元する（trap）。
E=http://127.0.0.1:8001
P=http://127.0.0.1:8002
CBZ505=http://127.0.0.1:8000/api/public/cbz/1/505/1.cbz
CBZ506=http://127.0.0.1:8000/api/public/cbz/1/506/1.cbz
ZIPS=~/workspace/yomima-ex-fixture/platform/storage/zips/user_1
VPY=~/venv-manga/bin/python
WORK=$(mktemp -d)
PASS=0; FAIL=0

check() { if [ "$2" == "$3" ]; then echo "PASS: $1"; PASS=$((PASS+1));
  else echo "FAIL: $1 (expected [$2] got [$3])"; FAIL=$((FAIL+1)); fi; }
session() { curl -s -G "$1/session" --data-urlencode "url=$2" | python3 -c "import json,sys; print(json.load(sys.stdin)['session_token'])"; }
download() { curl -sN -G "$1/download/start" --data-urlencode "url=$2" --data-urlencode "session_token=$3" --max-time 60 | grep -q "data: done"; }
thumb() { curl -s -G "$1/thumbnail" --data-urlencode "url=$2" --data-urlencode "index=$3" --data-urlencode "session_token=$4" -o "$5" -D "$6" -w "%{http_code}"; }

restore_thumbs() {
  [ -d "$ZIPS/title_505/episode_1_thumbs.step4bak" ] && mv "$ZIPS/title_505/episode_1_thumbs.step4bak" "$ZIPS/title_505/episode_1_thumbs"
  [ -d "$ZIPS/title_506/episode_1_thumbs.step4bak" ] && mv "$ZIPS/title_506/episode_1_thumbs.step4bak" "$ZIPS/title_506/episode_1_thumbs"
}
trap restore_thumbs EXIT

cat > "$WORK/imgcmp.py" <<'PYEOF'
import sys
from PIL import Image, ImageChops
a = Image.open(sys.argv[1]); b = Image.open(sys.argv[2])
if a.format != b.format or a.size != b.size:
    print(f"NG format/size: {a.format} {a.size} vs {b.format} {b.size}"); sys.exit(0)
diff = ImageChops.difference(a.convert("RGB"), b.convert("RGB"))
hist = diff.histogram()
mean = sum((i % 256) * c for i, c in enumerate(hist)) / (a.size[0] * a.size[1] * 3)
print(f"OK {a.format} {a.size[0]}x{a.size[1]} meandiff={mean:.3f}" if mean < 6.0
      else f"NG meandiff={mean:.3f}")
PYEOF
imgcmp() { "$VPY" "$WORK/imgcmp.py" "$1" "$2"; }

echo "== A. 代理のまま（506・プラットフォームのサムネイルあり） =="
TOK_E506=$(session "$E" "$CBZ506")
TOK_P506=$(session "$P" "$CBZ506")
CODE_E=$(thumb "$E" "$CBZ506" 0 "$TOK_E506" "$WORK/a_e.bin" "$WORK/a_e.hdr")
CODE_P=$(thumb "$P" "$CBZ506" 0 "$TOK_P506" "$WORK/a_p.bin" "$WORK/a_p.hdr")
check "proxy status Elixir" "200" "$CODE_E"
check "proxy status Python" "200" "$CODE_P"
cmp -s "$WORK/a_e.bin" "$WORK/a_p.bin"; check "proxy body identical" "0" "$?"
grep -qi "^cache-control: private, max-age=86400" "$WORK/a_e.hdr"; check "proxy Cache-Control Elixir" "0" "$?"
grep -qi "^cache-control: private, max-age=86400" "$WORK/a_p.hdr"; check "proxy Cache-Control Python" "0" "$?"

echo "== B. フォールバック生成（506・60x80 ページ、拡大しないこと） =="
mv "$ZIPS/title_506/episode_1_thumbs" "$ZIPS/title_506/episode_1_thumbs.step4bak"
download "$E" "$CBZ506" "$TOK_E506"; check "Elixir download 506" "0" "$?"
download "$P" "$CBZ506" "$TOK_P506"; check "Python download 506" "0" "$?"
CODE_E=$(thumb "$E" "$CBZ506" 0 "$TOK_E506" "$WORK/b_e.bin" "$WORK/b_e.hdr")
CODE_P=$(thumb "$P" "$CBZ506" 0 "$TOK_P506" "$WORK/b_p.bin" "$WORK/b_p.hdr")
check "fallback status Elixir" "200" "$CODE_E"
check "fallback status Python" "200" "$CODE_P"
R=$(imgcmp "$WORK/b_e.bin" "$WORK/b_p.bin"); echo "  imgcmp: $R"
case "$R" in "OK JPEG 60x80"*) check "fallback 506 image match (60x80 JPEG)" "yes" "yes";; *) check "fallback 506 image match (60x80 JPEG)" "yes" "no";; esac
grep -qi "^cache-control: private, max-age=86400" "$WORK/b_e.hdr"; check "fallback Cache-Control Elixir" "0" "$?"
CODE_E=$(thumb "$E" "$CBZ506" 24 "$TOK_E506" "$WORK/b24_e.bin" "$WORK/b24_e.hdr")
CODE_P=$(thumb "$P" "$CBZ506" 24 "$TOK_P506" "$WORK/b24_p.bin" "$WORK/b24_p.hdr")
check "fallback p24 status Elixir" "200" "$CODE_E"
check "fallback p24 status Python" "200" "$CODE_P"
R=$(imgcmp "$WORK/b24_e.bin" "$WORK/b24_p.bin"); echo "  imgcmp: $R"
case "$R" in "OK "*) check "fallback 506 p24 image match" "yes" "yes";; *) check "fallback 506 p24 image match" "yes" "no";; esac

echo "== C. フォールバック生成（505・スクランブル 320x320、リサイズしないこと） =="
mv "$ZIPS/title_505/episode_1_thumbs" "$ZIPS/title_505/episode_1_thumbs.step4bak"
TOK_E505=$(session "$E" "$CBZ505")
TOK_P505=$(session "$P" "$CBZ505")
download "$E" "$CBZ505" "$TOK_E505"; check "Elixir download 505" "0" "$?"
download "$P" "$CBZ505" "$TOK_P505"; check "Python download 505" "0" "$?"
CODE_E=$(thumb "$E" "$CBZ505" 0 "$TOK_E505" "$WORK/c_e.bin" "$WORK/c_e.hdr")
CODE_P=$(thumb "$P" "$CBZ505" 0 "$TOK_P505" "$WORK/c_p.bin" "$WORK/c_p.hdr")
check "fallback 505 status Elixir" "200" "$CODE_E"
check "fallback 505 status Python" "200" "$CODE_P"
R=$(imgcmp "$WORK/c_e.bin" "$WORK/c_p.bin"); echo "  imgcmp: $R"
case "$R" in "OK JPEG 320x320"*|"OK PNG 320x320"*) check "fallback 505 image match (320x320, no resize)" "yes" "yes";; *) check "fallback 505 image match (320x320, no resize)" "yes" "no";; esac

echo "== D. 範囲外インデックス（506・フォールバック側） =="
CODE_E=$(thumb "$E" "$CBZ506" 99 "$TOK_E506" "$WORK/d_e.bin" "$WORK/d_e.hdr")
CODE_P=$(thumb "$P" "$CBZ506" 99 "$TOK_P506" "$WORK/d_p.bin" "$WORK/d_p.hdr")
check "range status Elixir" "404" "$CODE_E"
check "range status Python" "404" "$CODE_P"
grep -q "ページが見つかりません" "$WORK/d_e.bin"; check "range message Elixir" "0" "$?"
grep -q "ページが見つかりません" "$WORK/d_p.bin"; check "range message Python" "0" "$?"

echo "== E. アーカイブがキャッシュに無い（506） =="
H506=$(printf %s "$CBZ506" | md5sum | cut -d' ' -f1)
rm -f "/tmp/manga_cache_ex/$H506.cbz" "/tmp/manga_cache/$H506.cbz"
CODE_E=$(thumb "$E" "$CBZ506" 0 "$TOK_E506" "$WORK/e_e.bin" "$WORK/e_e.hdr")
CODE_P=$(thumb "$P" "$CBZ506" 0 "$TOK_P506" "$WORK/e_p.bin" "$WORK/e_p.hdr")
check "no-archive status Elixir" "404" "$CODE_E"
check "no-archive status Python" "404" "$CODE_P"
grep -q "アーカイブが見つかりません" "$WORK/e_e.bin"; check "no-archive message Elixir" "0" "$?"
grep -q "アーカイブが見つかりません" "$WORK/e_p.bin"; check "no-archive message Python" "0" "$?"

echo "== F. セッションなし =="
CODE_E=$(curl -s -G "$E/thumbnail" --data-urlencode "url=$CBZ506" --data-urlencode "index=0" -o /dev/null -w "%{http_code}")
CODE_P=$(curl -s -G "$P/thumbnail" --data-urlencode "url=$CBZ506" --data-urlencode "index=0" -o /dev/null -w "%{http_code}")
check "no-session Elixir" "403" "$CODE_E"
check "no-session Python" "403" "$CODE_P"

echo
echo "RESULT: $PASS passed, $FAIL failed"
