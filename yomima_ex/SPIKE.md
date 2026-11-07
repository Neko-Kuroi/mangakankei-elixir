# 手順0 スパイク記録 — 閲覧側の Elixir なぞり実装（2026-11-07）

## 目的と合格条件

プラットフォーム（Python）は無改造のまま、閲覧側だけを Elixir で実装し直して
同じ振る舞いになるかを確認する。合格条件は「無改造の Python プラットフォームに
対して、カタログ表示／公開作品の読書／premium の unlock／年齢ゲートの4点が通ること」。

**結果: 合格。** verify.sh で 18項目すべて PASS、画像リサイズも寸法一致。

## 環境

- Erlang/OTP 27.3.4.2 + Elixir 1.18.4 を永続領域 `~/elixir-tools/` に導入
  （builds.hex.pm の事前ビルド tarball + Elixir 公式の事前ビルド zip）。
  起動は `source ~/elixir-tools/env.sh` で PATH を通す。VM 入替でも消えない。
- OTP tarball は展開後に `./Install -sasl <ERL_ROOT>` の実行が必要。
- `mix local.hex` の自己ダウンローダがこの環境では失敗する（:eperm）ため、
  Hex 2.2.1 の .ez を curl で取得して `~/.mix/archives/hex-2.2.1/` へ手動配置した。
  rebar3 3.25.0 も GitHub リリースから `~/.mix/rebar3` へ手動配置。
- Hex の依存解決はプロキシ越しに時々 TLS 切断するが、再試行で通る。

## 技術構成（スパイク）

- Phoenix は使わず Plug + Bandit + Req + Jason の薄い構成。
- 状態（読者ログイン・読書セッション・年齢ゲート・許可キャッシュ）は
  GenServer 1個（YomimaEx.Store）に集約し、期限切れは30秒 sweep。
  プラットフォーム JWT はサーバー側だけに持ち、ブラウザには HttpOnly Cookie のみ。
- カタログは CatalogCache GenServer で60秒キャッシュ（Python 版と同じ）。
- 通信契約は現行どおり: X-Internal-Token、CBZ 取得時の Authorization 併送、
  年齢確認済みの X-Age-Verified ヘッダ、プラットフォーム宛先判定は完全一致。
- 画像処理は `:image` 0.73（libvips / Vix）。注意: GitHub README の
  `~> 0.74` は hex 未公開で、公開済み最新は 0.73.0。

## 実測（verify.sh、プラットフォームはフィクスチャの実サーバー）

フィクスチャ: `~/workspace/yomima-ex-fixture/`（repo 現行ツリー＋アクセス制御
4パッチ適用済みツリーのコピー＋ seed.py の種データ）。作品501 公開 /
502 premium（reader に許可）/ 503 公開＋年齢 / 504 premium＋年齢。

- カタログ: 一覧・施錠表示・年齢表示・許可あり表示すべて一致（4 PASS）
- 公開作品: セッション→SSE ダウンロード→画像一覧→画像配信（3 PASS）
- premium: 匿名セッション 401、無許可はダウンロード段で拒否、許可ありは
  ダウンロード完了＋画像 200、他人のセッション流用は本人 Cookie なし／
  別ユーザーとも 403（7 PASS）
- 年齢: 匿名 403 → セッション申告で取得可。premium+年齢は未申告で拒否、
  アカウント申告後は同じセッションのまま再試行で成功（4 PASS）

合計 18/18 PASS。

## 画像リサイズ確認（resize_check.exs）

Python 版 load_image_bytes（非スクランブル: PIL thumbnail で最大1200×1800、
JPEG quality 90）と Elixir :image（Image.thumbnail "1200x1800"）を比較。

- 2400×3600 → 両方とも 1200×1800
- 800×1000 → 両方とも無変更（縮小のみ）

寸法は完全一致。画素単位の一致は目的ではない（リサンプラが異なる:
PIL LANCZOS と libvips）。スクランブル画像はリサイズ対象外という現行仕様も
そのまま適用できる。

## つまずき（再発防止メモ）

- Elixir の %URI{} に username/password フィールドは無い（userinfo を見る）。
  dot アクセスはコンパイル警告だけで実行時に KeyError になるので、
  警告を流さないこと。
- Bandit では Plug.Conn.chunk をリクエストプロセス以外（Agent 等）から呼べない。
  SSE の進捗はダウンロードを Task で走らせ、メッセージでリクエストプロセスに
  戻してから chunk する形にした（Python 版の「配信は本人の接続で」の素直な対応）。
- この実行環境では、コマンド文字列中の `password=<値>` が実行時に
  プレースホルダへ書き換わる。検証スクリプトの資格情報は変数経由で渡すこと
  （verify.sh は printf で組み立てている）。ログイン失敗の切り分けで最初に
  これに引っかかった。

## 発見（プラットフォーム側の設計メモ、今回の作業範囲外）

`/api/auth/token` は `@limiter.limit("5/minute")` で内部免除がない。
閲覧側経由のログインは全読者が閲覧側サーバーの送信元 IP を共有するため、
読者全体で「5回/分」のログイン上限を共有する形になっている。
これは Elixir 化とは無関係で、現行の Python 閲覧側でも同じ構造。
実運用で読者数が増えると最初に詰まる場所なので、対処するなら
プラットフォーム側で内部トークン提示時の免除か、キー設計の見直しが要る。

## 本実装 手順1 再検証（2026-11-07、現行プラットフォーム 65be38c 基準）

本実装の開始が決まり、手順1としてフィクスチャを現行ツリー
（access-all＋ratelimit-all 適用済み、HEAD 65be38c）で作り直して再検証した。

- フィクスチャ platform/ を現行ツリーに入れ替え、seed.py を再実行
- verify.sh: **18/18 PASS**（スパイク時と同一結果。レート制限パッチ適用後の
  プラットフォームでも、クライアントキーなしのスパイク実装が従来どおり動く）

運用上の注意（今回の切り分けで判明）:

- 閲覧側の起動には `PLATFORM_BASE_URL=http://127.0.0.1:8000` が必須。
  verify.sh は 127.0.0.1 の URL を組み立て、platform_origin? は完全一致で
  判定するため、既定の localhost では別オリジン扱いになり、SSRF ガードが
  「内部ネットワークへのアクセスは許可されていません」(400) で弾く。
- verify.sh は再実行に弱い: 作中の /auth/declare-adult がアカウントに
  永続化される（取消不可の設計）ため、2回目以降は「未申告で拒否」の
  チェックが成立しない。フル実行の前には必ず seed.py を流し直し、
  実行は seed ごとに1回だけにすること。

## 本実装 手順2 認証の本実装＋クライアントキー（2026-11-07）

Python 版閲覧側（ratelimit 全段階適用後）と認証まわりを同等化した。

実装:
- 新規 `YomimaEx.ClientKey`: 秘密の解決（env MANGA_CLIENT_KEY_SECRET ＞
  instance/client_key_secret ＞ 生成して 0600 で原子的に保存）、
  HMAC-SHA256 によるキー計算、CF-Connecting-IP の信用規則を含む
  クライアントIP取得。秘密のキャッシュは Store が保持（失敗時の
  空文字も含め初回結果で固定、Python 版と同じ）。
  秘密ファイルの既定パスは cwd 配下の instance/（Python 版はコードの隣。
  配布形態を決める手順6で再検討する）。
- `Platform.auth_headers/1`（内部トークン＋クライアントキー）を新設し、
  login/signup の代理送信に付与。これまで Elixir 版は認証系に内部
  トークン自体を付けていなかった点も是正（キーはトークン併送で初めて
  プラットフォームに信頼される）。
- エラーの出し分けを Python 版に一致: ログインは 429→混雑の案内
  （ステータスも 429）、不一致→401、/me 失敗→502。登録は 429→混雑、
  それ以外はプラットフォームの detail を 400 で透過。登録後の自動
  ログイン失敗も同じ出し分けに統一（スパイク独自の「登録はできまし
  たがログインに失敗しました」は廃止）。
- 意図的な相違が1点: プラットフォームへの接続自体が失敗した場合、
  Python 版は例外で 500 になるが、Elixir 版は 502
  「プラットフォームとの通信に失敗しました」に寄せた。

検証:
- mix test: 6 tests＋1 doctest、0 failures（新規 ClientKey テスト5件は
  Python 版テストと同項目。HMAC は Python で計算した検証ベクトルと一致）
- verify.sh: 18/18 PASS（回帰なし）
- verify_auth.sh（新規、25項目）: 全 PASS。内訳は、パスワード違いの
  表示、slowapi 429→混雑案内、ユーザー名カウンタ 429→混雑案内
  （キーを毎回変えてプラットフォーム JSON 429 を踏む経路。Python 版
  段階3のテストで欠けていた E2E の組み合わせ）、登録枠のキー分離
  （CF-IP A で3件＋4件目 429、B からは成功）、重複登録の detail 透過。

## 本実装 手順3 リーダーの完成（2026-11-07）

- /images を Python 版 images_partial と同じバッチ契約に作り替えた:
  offset/limit（既定 page_size は IMAGES_PER_LOAD=1）、batch-meta
  （total / next-offset / has-more / pending）、.img-block 断片、
  未ダウンロード時は pending 断片。
- リーダーページを新設 YomimaEx.ReaderPage に分離し、Python 版
  reader.html の画面部品とスクリプト全文を移植。サーバー由来の定数
  （SCRAMBLED / tileSize / WEBHOOK_ENABLED / READER_LOGGED_IN）は
  カタログから Python 版と同じ規則で決定（webhook は外部URLでは
  常時 true、プラットフォーム作品はカタログ値）。CSS は style.css の
  リーダー分を CSS 変数を実値化して同梱。
- 差分検証で見つけた実物の相違を同梱で修正: 展開処理が Python 版
  （manga.py extract_archive）と別物だった（Elixir は生ファイル名＋
  自然順ソート、Python はアーカイブ順に {index:05d}_ 接頭辞＋安全化、
  結果を自然順ソート）。スクランブル命名（stem=20文字＋16hex）は
  seed 抽出位置を守るため Python 側でも無変換で保持される特別規則。
  Manga の展開を Python 仕様に移植した（上限 50MB/480MB/2500件、
  警告文言、拡張子のマジックバイト推定、結果のプロセス内キャッシュを
  Store に保持）。RAR は :zip が読めないため「無効なアーカイブ」の
  警告に倒れる（Python は rarfile 依存。既知の残差分）。
- 実装中の実測メモ: :zip.foldl の GetBinary はバイナリを直接返し、
  コールバックは acc をそのまま返す（{:ok, _} 形式ではない）。

検証:
- mix test: 11 tests＋1 doctest、0 failures（safe_filename の単体5件）
- verify.sh 18/18、verify_auth.sh 25/25（回帰なし）
- verify_step3.sh（新規、16項目）: 全 PASS。内訳: pending 断片、
  25ページ作品のバッチ差分5態様が Python 閲覧側と完全一致、
  スクランブル作品のバッチ一致（ファイル名保持）、配信リーダー
  スクリプトが Python 版と正規化一致、Node 上で配信ページの decode を
  実行し原画と画素一致（フィクスチャ追加 seed_step3.py: 作品505
  スクランブル・506 25ページ）。

## 本実装 手順4 サムネイルフォールバック生成（2026-11-07）

- /thumbnail を Python 版 serve_thumbnail と同じ契約に作り替えた:
  セッション検証→宛先ポリシー（400）→プラットフォームのサムネイル
  代理（5秒タイムアウト、成功時は Cache-Control: private,
  max-age=86400 を付与。従来の Elixir 実装は付けていなかった）→
  失敗時は閲覧側キャッシュの CBZ から生成するフォールバック。
- フォールバック: アーカイブ無しは 404「アーカイブが見つかりません」、
  範囲外は 404「ページが見つかりません」、生成失敗は
  500「サムネイル生成失敗」（文言・状態とも Python 版と一致）。
- Manga.load_image_bytes（Python 版のなぞり）を新設: thumbs/ への
  ディスクキャッシュ（キー=パス・更新時刻・サイズ・寸法・
  スクランブル有無の md5）、スクランブル命名はリサイズ無し、
  非スクランブルは {80, 120} に縮小のみ、アルファ有りは PNG・
  無しは JPEG quality 90、失敗は nil。
- 実測で踏んだ差分2件: (1) :image の Image.thumbnail は既定で
  拡大もする（PIL の thumbnail は縮小のみ）→ resize: :down を指定。
  (2) Manga.image_files は安全名（ファイル名のみ）を返すので、
  実パスは Manga.image_path/2 で解決する（/images と同じ経路）。
- Python 版 /thumbnail にある閲覧側レート制限（30/minute）は
  Elixir 側に枠組み自体が無いため未移植（既知の差分として残す）。

検証:
- mix test: 19 tests＋1 doctest、0 failures（新規8件:
  scrambled_filename? 2件、load_image_bytes 6件）
- verify.sh 18/18、verify_auth.sh 25/25、verify_step3.sh 16/16（回帰なし）
- verify_step4.sh（新規、29項目）: 全 PASS。内訳: 代理経路の
  バイト一致と Cache-Control、フォールバック生成が Python 閲覧側と
  形式・寸法一致（506 の 60x80 は画素一致 meandiff=0.000、505 の
  スクランブル 320x320 は無リサイズで一致、meandiff=2.766 は
  JPEG エンコーダ差）、404 の文言2種、セッション無し 403。
  プラットフォームの episode_1_thumbs を一時退避して発火させ、
  trap で復元する方式。検証上の注意: アーカイブ削除（E 節）は
  実行中ビューワのメモリ内キャッシュと競合するため、step4 は
  ビューワ再起動＋キャッシュ掃除の直後に流すこと。

## 本実装 手順5 残り機能（Discord・マイリスト・共有・作品登録）（2026-11-07）

- ホーム画面（GET /）を新設 YomimaEx.ListPage で移植（list.html＋
  partials/manga_list.html のなぞり、全体は既存 page_shell に載せる）。
  リストの実体はサーバーに無く、share パラメータ（base64url の JSON、
  Python 版 encode/decode_manga_list と相互運用可能）が持ち回る。
- POST /manga/add・/manga/remove: 検証の順序と文言（拡張子→宛先
  ポリシー→上限12件→重複）、部分 HTML のバイト一致、HX-Push-Url
  ヘッダまで Python 版と一致。GET /share/url: quote(safe="") の
  引用と TinyURL 短縮（失敗時は完全 URL）も移植。
- POST /discord/send: 常時 200 の HTML 断片で、セッション確認→
  作者許可（カタログの webhook_enabled、外部URLは許可）→ファイル
  解決→Webhook 未設定→送信、の順序と文言を一致させた。送信は
  multipart を手組み（送信ファイル名は stem 先頭5文字＋拡張子、
  Webhook URL の検証は Python 版 is_discord_webhook_url のなぞり）。
  リーダーの FormData（multipart）に合わせ Plug.Parsers に
  :multipart を追加（認証系の FormData 送信もこれで通るように
  なった。従来は urlencoded のみで、検証も curl の urlencoded
  送信で通っていた）。
- ついでに宛先ポリシーを Python 版 fetch_policy_check に完全一致
  させた: 理由文言（「http/https のURLだけ取得できます」等）、
  MANGA_URL_ALLOW_HOSTS 例外、ホスト名の DNS 解決＋解決先チェック、
  遮断リストを Python の明示リストに統一（CGNAT 100.64/10 等を
  外した）。validate_manga_url のスキーム判定も大小文字を不問に。
- 実測メモ: 展開はダウンロード時ではなく /images 初回アクセス時に
  走る（Discord 送信の前に対象が展開されている必要がある）。
  curl -F "filename=" はファイル部品になり Python 版は 422 を返す
  （ブラウザの FormData では起きない。検証では filename=".." で
  不正名ケースを確認）。

検証:
- mix test: 33 tests＋1 doctest、0 failures（新規14件: 宛先ポリシー、
  リスト往復と Python 製文字列の読解、ファイル名導出、Webhook
  検証、送信の前段まで）
- verify.sh 18/18、verify_auth.sh 25/25、verify_step3.sh 16/16、
  verify_step4.sh 29/29（回帰なし）
- verify_step5.sh（新規、55項目）: 全 PASS。内訳: ホーム画面と
  共有リストの表示、追加/削除の部分 HTML バイト一致（時刻のみ
  正規化）と HX-Push-Url の中身、上限12件、共有の双方向互換、
  /share/url（短縮の有無）、Discord の分岐6種（フィクスチャ追加
  seed_step5.py: webhook 許可作品507）、multipart ログイン。
  Discord の実送信の成功だけは実 Webhook が無いため未検証
  （エラー文は接頭辞まで一致、詳細の文面には実装差が残る）。

## 本実装 手順6 配布の確認（mix release）（2026-11-07）

- MIX_ENV=prod の mix release で自己完結な release を作成
  （~/workspace/yomima_ex/release、84MB。erts 同梱、要 libvips
  等のシステムライブラリ）。Phoenix 化はしない前提どおり Plug
  構成のまま。ポートは環境変数 VIEWER_PORT で変更できる。
- ビルド時の注意（この VM の事情）: プロジェクト直下への assembly
  は erts のコピー（File.cp_r!）が heart で EPERM になり失敗する
  （overlayfs 向けの制限。/tmp へのコピーは通る）。そのため
  `mix release --path /tmp/yomima_ex_release` で組み立ててから
  通常の cp -r で配置した。配置後の release は正常動作する。
- 秘密ファイルの既定パス（cwd 配下 instance/）は再検討の結果、
  維持で確定: release を別 cwd（~/workspace/reltest）から起動し、
  環境変数なしで instance/client_key_secret が 0600 で自動生成
  されることを実測。運用では起動ディレクトリを固定する。
  なお release の cwd は永続ファイルシステム上に置くこと
  （この VM では /tmp 配下の作業ディレクトリがセッションを跨ぐと
  消えることがあり、その状態で DNS 解決をすると inet_gethost の
  起動に失敗して VM ごと落ちた。cwd を ~/workspace 配下にして解消）。
- キャッシュ互換: MANGA_CACHE_DIR を Python 版のキャッシュ
  （/tmp/manga_cache）に向けると相互に使えることを実測した:
  release が展開した 507 を Python 版が配信（200）、Python 版が
  展開した 506 を release が配信（200）、プラットフォーム停止中
  でも release のサムネイルフォールバック生成が共有キャッシュ
  から成功（200）。サムネイルのディスクキャッシュだけはキー
  形式が実装ごとに違うため、共有時は初回だけ再生成される。

検証（release を :8001 に置いて全スイートを再実施）:
- verify.sh 18/18、verify_auth.sh 25/25（秘密はファイル自動生成）、
  verify_step3.sh 16/16、verify_step4.sh 29/29、
  verify_step5.sh 55/55。全て mix run 時と同じ結果。

## 本実装の完了状態と既知の差分

手順1〜6は全て完了。残るのは既知の差分のみ（いずれも記録済みで、
必要になったら個別の作業として扱う）:

- /thumbnail の閲覧側レート制限（Python 版は 30/minute、
  Elixir 側に枠組みなし）未移植
- セッションの接続元 IP 紐付けなし（Python 版 validate_session は
  IP を見る。Elixir 側セッションは全体を通して IP を紐付けない）
- Discord 送信エラーとデコードエラーの詳細文面（接頭辞は一致）
- Phoenix 化の要否判断（現行の Plug 構成で全機能が揃ったため、
  必要性は生じていない）
