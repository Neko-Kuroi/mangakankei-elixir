#!/bin/bash
# 手順3（リーダー完成）の検証。
# 前提: platform :8000（seed.py + seed_step3.py 適用済み）、
#       Elixir 閲覧側 :8001、Python 閲覧側 :8002 が起動していること。
E=http://127.0.0.1:8001
P=http://127.0.0.1:8002
CBZ505=http://127.0.0.1:8000/api/public/cbz/1/505/1.cbz
CBZ506=http://127.0.0.1:8000/api/public/cbz/1/506/1.cbz
FIX=~/workspace/yomima-ex-fixture/step3_assets
WORK=$(mktemp -d)
PASS=0; FAIL=0

check() { if [ "$2" == "$3" ]; then echo "PASS: $1"; PASS=$((PASS+1));
  else echo "FAIL: $1 (expected [$2] got [$3])"; FAIL=$((FAIL+1)); fi; }
session() { curl -s -G "$1/session" --data-urlencode "url=$2" | python3 -c "import json,sys; print(json.load(sys.stdin)['session_token'])"; }
download() { curl -sN -G "$1/download/start" --data-urlencode "url=$2" --data-urlencode "session_token=$3" --max-time 60 | grep -q "data: done"; }
images() { curl -s -G "$1/images" --data-urlencode "url=$2" --data-urlencode "session_token=$3" $4; }
norm_frag() { sed "s/$2/TOK/g" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$'; }

echo "== A. /images pending（Elixir、506 未ダウンロード） =="
TOK_E506=$(session "$E" "$CBZ506")
F=$(images "$E" "$CBZ506" "$TOK_E506" "--data-urlencode offset=0 --data-urlencode limit=3")
case "$F" in *'data-pending="true"'*) check "pending fragment" "yes" "yes";; *) check "pending fragment" "yes" "no";; esac

echo "== B. バッチ分割の差分（506・25ページ、Elixir vs Python） =="
download "$E" "$CBZ506" "$TOK_E506"; check "Elixir download 506" "0" "$?"
TOK_P506=$(session "$P" "$CBZ506")
download "$P" "$CBZ506" "$TOK_P506"; check "Python download 506" "0" "$?"
for spec in "offset=0 limit=3" "offset=3 limit=3" "offset=24 limit=3" "offset=0" "offset=25 limit=3"; do
  args=""; for kv in $spec; do args="$args --data-urlencode $kv"; done
  images "$E" "$CBZ506" "$TOK_E506" "$args" | norm_frag x "$TOK_E506" > "$WORK/e.frag"
  images "$P" "$CBZ506" "$TOK_P506" "$args" | norm_frag x "$TOK_P506" > "$WORK/p.frag"
  if diff -q "$WORK/e.frag" "$WORK/p.frag" > /dev/null; then check "batch [$spec] identical" "yes" "yes";
  else check "batch [$spec] identical" "yes" "no"; diff "$WORK/e.frag" "$WORK/p.frag" | head -6; fi
done

echo "== B2. スクランブル作品のバッチ差分（505、ファイル名が保持されること） =="
TOK_P505=$(session "$P" "$CBZ505")
download "$P" "$CBZ505" "$TOK_P505"; check "Python download 505" "0" "$?"
TOK_E505B=$(session "$E" "$CBZ505")
download "$E" "$CBZ505" "$TOK_E505B"; check "Elixir download 505" "0" "$?"
images "$E" "$CBZ505" "$TOK_E505B" "--data-urlencode offset=0 --data-urlencode limit=1" | norm_frag x "$TOK_E505B" > "$WORK/e505.frag"
images "$P" "$CBZ505" "$TOK_P505" "--data-urlencode offset=0 --data-urlencode limit=1" | norm_frag x "$TOK_P505" > "$WORK/p505.frag"
if diff -q "$WORK/e505.frag" "$WORK/p505.frag" > /dev/null; then check "batch 505 identical" "yes" "yes";
else check "batch 505 identical" "yes" "no"; diff "$WORK/e505.frag" "$WORK/p505.frag" | head -6; fi

echo "== C. リーダースクリプトの一致（505） =="
curl -s -G "$E/reader" --data-urlencode "url=$CBZ505" > "$WORK/e_reader.html"
curl -s -G "$P/reader" --data-urlencode "url=$CBZ505" > "$WORK/p_reader.html"
grep -q "const SCRAMBLED       = true;" "$WORK/e_reader.html"; check "Elixir SCRAMBLED=true" "0" "$?"
grep -q "let tileSize          = 16;" "$WORK/e_reader.html"; check "Elixir tileSize=16" "0" "$?"
python3 - "$WORK/e_reader.html" "$WORK/p_reader.html" > "$WORK/script_diff.txt" <<'PYEOF'
import re, sys
def extract(path):
    html = open(path).read()
    blocks = [b for b in html.split("<script>")[1:] if "class Xorshift32" in b]
    s = blocks[0].split("</script>")[0]
    s = re.sub(r"const SCRAMBLED\s*= \w+;", "const SCRAMBLED = X;", s)
    s = re.sub(r"let tileSize\s*= \d+;", "let tileSize = X;", s)
    s = re.sub(r"const WEBHOOK_ENABLED = \w+;", "const WEBHOOK_ENABLED = X;", s)
    s = re.sub(r"const READER_LOGGED_IN = \w+;", "const READER_LOGGED_IN = X;", s)
    return [ln.strip() for ln in s.splitlines() if ln.strip()]
a, b = extract(sys.argv[1]), extract(sys.argv[2])
if a == b:
    print("IDENTICAL")
else:
    print(f"DIFFERENT ({len(a)} vs {len(b)} lines)")
    import difflib
    print("\n".join(list(difflib.unified_diff(b, a, "python", "elixir"))[:20]))
PYEOF
check "reader script identical (normalized)" "IDENTICAL" "$(head -1 "$WORK/script_diff.txt")"
cat "$WORK/script_diff.txt" | tail -n +2 | head -20

echo "== D. 復号の画素一致（Elixir 配信ページの JS で） =="
TOK_E505=$(session "$E" "$CBZ505")
download "$E" "$CBZ505" "$TOK_E505"; check "Elixir download 505" "0" "$?"
SRC=$(images "$E" "$CBZ505" "$TOK_E505" "--data-urlencode offset=0 --data-urlencode limit=1" | grep -o 'src="[^"]*"' | head -1 | sed 's/src="//;s/"//')
curl -s "$E$SRC" -o "$WORK/served.png"
~/venv-manga/bin/python -c "
from PIL import Image
Image.open('$WORK/served.png').convert('RGBA').save('$WORK/scrambled.rgba', format='RAW')
" 2>/dev/null || ~/venv-manga/bin/python -c "
from PIL import Image
open('$WORK/scrambled.rgba','wb').write(Image.open('$WORK/served.png').convert('RGBA').tobytes())
"
node ~/workspace/yomima_ex/decode_check.js "$WORK/e_reader.html" "$WORK/scrambled.rgba" "$FIX/original_505.rgba" "$FIX/meta_505.json"
check "decode_check exit" "0" "$?"

echo "== 結果: PASS=$PASS FAIL=$FAIL (作業dir: $WORK) =="
