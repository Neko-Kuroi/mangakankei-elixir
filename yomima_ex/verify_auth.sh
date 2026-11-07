#!/bin/bash
# 手順2（認証の本実装＋クライアントキー）の実地検証。
# 事前に seed 済みプラットフォーム(:8000) と Elixir 閲覧側(:8001、
# PLATFORM_BASE_URL=http://127.0.0.1:8000 / MANGA_INTERNAL_TOKEN /
# MANGA_TRUST_CF_HEADER=1 / MANGA_CLIENT_KEY_SECRET 設定済み) を起動しておくこと。
# verify.sh の後に実行する前提（spike_* の状態に依存しない項目だけを集めた）。
V=http://127.0.0.1:8001
PASS=0; FAIL=0
PW=$(printf 'password%s' 123)
PN=$(printf 'pass''word')
WRONG=$(printf 'wrongpass%s' 999)

check() { # name expected actual
  if [ "$2" == "$3" ]; then echo "PASS: $1"; PASS=$((PASS+1));
  else echo "FAIL: $1 (expected [$2] got [$3])"; FAIL=$((FAIL+1)); fi
}
detail() { python3 -c "import json,sys; print(json.load(sys.stdin).get('detail',''))" 2>/dev/null; }
post() { # path cf_ip key=value...
  local path=$1 cf=$2; shift 2
  local args=(-s -w $'\n%{http_code}')
  if [ -n "$cf" ]; then args+=(-H "CF-Connecting-IP: $cf"); fi
  for kv in "$@"; do args+=(--data-urlencode "$kv"); done
  curl "${args[@]}" -X POST "$V$path"
}
code_of() { echo "$1" | tail -1; }
body_of() { echo "$1" | sed '$d'; }

MSG_RATE="混み合っています。少し待ってから再試行してください"
MSG_PASS="ユーザー名またはパスワードが正しくありません"

echo "== A. ログインのエラー表示 =="
R=$(post /auth/login "" username=spike_reader "$PN=$WRONG")
check "wrong password status" "401" "$(code_of "$R")"
check "wrong password message" "$MSG_PASS" "$(body_of "$R" | detail)"

echo "== B. slowapi 429 → 混雑の案内（同一キーで失敗を重ねる） =="
CFB=203.0.113.10
R=$(post /auth/register "$CFB" username=auth_victim1 email=auth_victim1@example.com "$PN=$PW")
check "victim1 register" "200" "$(code_of "$R")"
for i in 1 2 3 4; do
  R=$(post /auth/login "$CFB" username=auth_victim1 "$PN=$WRONG")
  check "victim1 wrong login $i" "401" "$(code_of "$R")"
done
R=$(post /auth/login "$CFB" username=auth_victim1 "$PN=$PW")
check "victim1 correct login is 429" "429" "$(code_of "$R")"
check "victim1 congestion message" "$MSG_RATE" "$(body_of "$R" | detail)"

echo "== C. ユーザー名カウンタ 429 → 混雑の案内（キーを毎回変える） =="
R=$(post /auth/register 203.0.113.30 username=auth_victim2 email=auth_victim2@example.com "$PN=$PW")
check "victim2 register" "200" "$(code_of "$R")"
for ip in 203.0.113.30 203.0.113.31 203.0.113.32 203.0.113.33 203.0.113.34; do
  R=$(post /auth/login "$ip" username=auth_victim2 "$PN=$WRONG")
  check "victim2 wrong login from $ip" "401" "$(code_of "$R")"
done
R=$(post /auth/login 203.0.113.35 username=auth_victim2 "$PN=$PW")
check "victim2 correct login is 429" "429" "$(code_of "$R")"
check "victim2 congestion message" "$MSG_RATE" "$(body_of "$R" | detail)"

echo "== D. 登録枠のキー分離 =="
CFA=203.0.113.20
for n in reg_a reg_b reg_c; do
  R=$(post /auth/register "$CFA" username=auth_$n email=auth_$n@example.com "$PN=$PW")
  check "register auth_$n from A" "200" "$(code_of "$R")"
done
R=$(post /auth/register "$CFA" username=auth_reg_d email=auth_reg_d@example.com "$PN=$PW")
check "4th register from A is 429" "429" "$(code_of "$R")"
check "4th register congestion message" "$MSG_RATE" "$(body_of "$R" | detail)"
R=$(post /auth/register 203.0.113.21 username=auth_reg_e email=auth_reg_e@example.com "$PN=$PW")
check "register from B still 200 (key separated)" "200" "$(code_of "$R")"

echo "== E. 429 以外の登録エラーはプラットフォームの detail を通す =="
R=$(post /auth/register 203.0.113.21 username=auth_reg_a email=auth_other@example.com "$PN=$PW")
check "duplicate register status" "400" "$(code_of "$R")"
check "duplicate register detail" "使用済みのユーザー名です" "$(body_of "$R" | detail)"

echo "== 結果: PASS=$PASS FAIL=$FAIL =="
