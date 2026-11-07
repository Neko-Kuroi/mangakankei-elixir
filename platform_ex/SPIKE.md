# 手順0スパイク記録：プラットフォーム Elixir 化（Elixir らしい作り）

実施：2026-11-07
計画書：~/workspace/mangaupload_yomima_site2/PLAN-platform-elixir.md
検証アセット：~/workspace/platform-spike-assets/（build_assets.py で生成、verify_reverse.py で逆方向検証）
検証テスト：test/spike/（12件）＋生成時テスト5件 = **17 tests, 0 failures**

## 結果一覧（6項目すべて合格）

| # | 項目 | 結果 |
|---|---|---|
| 1 | Phoenix 雛形＋Ecto（ecto_sqlite3）で既存 DB を開く | ✅ users 9件・grants 2件・suspensions の存在まで確認 |
| 2 | bcrypt 相互検証 | ✅ Python→Elixir、Elixir→Python、DB 内の実ハッシュの照合すべて成功 |
| 3 | JWT 相互検証 | ✅ python-jose 発行分を Joken で検証、Elixir 発行分を jose で検証（sub 一致） |
| 4 | スクランブル相互検証 | ✅ 3ケース（320x320/tile16、端数あり 250x190/tile16、96x96/tile32）すべて Python 出力と画素一致。既存 JS 復号でも原画に画素一致（decode_check 4/4 ×3） |
| 5 | LiveView で 100MB 級アップロード | ✅ 100,000,000 バイトを受信・保存（chunk 2MB）。要・下記 MIME の注意 |
| 6 | Hammer の意味論 | ✅ キー文字列で枠を分離できる（クライアントキー分離を表現可能）。`set(key, scale, 0)` で成功時リセット（ユーザー名カウンタの解除）も表現可能 |

## 重要な発見：スクランブルの実装方式

- compose（Image.compose!）をタイル数だけ連ねる実装は、画素は正確だったが
  **1つの VM 内で大きなスクランブル（400タイル級）を複数回行うと VM が segfault する**再現を確認
  （単発では正常。2回目以降の実行中または終了時に落ちる。終了コード139で切り分け）
- 対策として、タイルを目的地順に並べて **Image.join（vips arrayjoin）で1演算にまとめ、
  原画の上に1回だけ重ねる**実装（Scramble.scramble_join）に変更。
  4回連続実行でも安定し、画素は Python 出力と完全一致を維持
- 本実装（手順3）では scramble_join 方式を採用する。リサイズ等の単発演算は :image で問題なし
  （閲覧側の実績どおり）

## 環境の癖と回避策（この VM 固有）

- `mix archive.install hex phx_new` が File.cp の EPERM（not owner）で失敗する。
  回避：repo.hex.pm から tarball を取り、/tmp で `mix archive.build` して .ez を作り、
  `~/.mix/archives/phx_new-1.8.16/` へ unzip で手配置（Phoenix installer v1.8.16）
- phoenix 本体のコンパイル時も、テンプレート複写の File.cp! が同理由で失敗する。
  回避：deps/phoenix/mix.exs の copy_core_components を「宛先があれば飛ばす」に変更
  （hex パッケージには同一ファイルが同梱済みで内容一致を確認済み）。
  **deps を取り直すたびに再発する**ので、手順1でも同じ手当てが要る
- Hex のレジストリ取得が :timeout で間欠的に失敗する。リトライと HEX_HTTP_TIMEOUT=120 で解消
- exqlite 0.43 の接続 mode は `:readonly` が正しい値（`:ro` は ArgumentError で接続が死ぬ）

## 本実装への申し送り

- LiveView の upload `accept:` に `.cbz` を入れると MIME 型未登録で検証エラーになる。
  `config :mime, :types` に application/x-cbz 等を追加登録すること（手順3/5）
- JWT は Joken、パスワードは bcrypt_elixir（$2b$12$ で生成されることも確認）、
  レート制限は Hammer で計画どおり進められる
- スパイクの検証資産（Scramble、LegacyRepo 等）は test/spike と lib/platform_spike に残置。
  本実装の部屋（Media 等）へ移す際に作り直す

---

# 手順1：基盤（2026-11-07 実施）

前提の確定：Phoenix あり、DB は SQLite（既存ファイルそのまま）。計画書の判断ポイント
（プロジェクト名 platform_ex、SQLite 維持、アップロード応答は加工完了まで待つ）もこの前提で確定。

実施内容：

- Repo の接続先を `storage/manga_platform.db` に変更（dev はプロジェクト相対、
  prod はカレント相対、どちらも env `MANGA_DB_PATH` で差し替え可能）。ポートは 8000 に統一
- dev 用にフィクスチャ DB のコピーを storage/ へ配置し、jobs マイグレーションを適用
  （既存テーブルには無変更、users 9件はそのまま）
- スキーマ：Accounts.User（users）、Access.Grant（grants）、Access.Suspension（suspensions）、
  Jobs.Job（jobs、新設）。既存3テーブルはマイグレーションで作らず、増やすのは jobs だけ
- Secrets：JWT 署名鍵の解決を Python 版 _load_secret_key と同じ流儀で実装
  （env > instance/secret_key > 生成。token_urlsafe(48) 相当、0600、一時ファイル＋link で原子公開、
  空ファイルは同じ文言で RuntimeError）
- Admin＋BootCheck：MANGA_ADMIN_USERS の都度読み・完全一致判定と、起動時ログを監督ツリーに組み込み
  （文言は Python 版と同一。未設定なら無音、失敗しても起動を妨げない）

検証：

- mix test：**24 tests, 0 failures**（スパイク12＋生成時5＋Secrets 4＋Admin 3）
- 起動確認：コピー DB でサーバーを起動し、起動時ログが Python 版どおりに出ることを確認
  （spike_admin → WARNING「アカウントなし」、spike_reader → INFO「登録済み（email=spike_reader@example.com）」）、
  GET / は 200、待受は 127.0.0.1:8000

---

# 手順2：ユーザーと認証（2026-11-07 実施）

実装：

- Accounts（ユーザーの部屋）：登録（検査の順序は Python 版 signup と同じ：
  メール重複 → 予約名 → 名前重複 → 種別 → パスワード規則）、
  normalize_username（NFKC＋ゼロ幅除去＋trim＋casefold。casefold と downcase の差は
  ß→ss、ς→σ を補って寄せた）と予約名判定、password_rule_error、
  bcrypt は Python 版と同じく先頭72バイトで切り詰めてから渡す。
  authenticate はユーザー名カウンタ（ブロック→失敗記録→成功でリセット）まで内包。
  user_from_token（2種類の 401 文言）、declare_adult（冪等）、grants_for_user
- Auth.Token：Joken で HS256・sub/exp（60分）。鍵は Secrets
- レート制限：RateLimiter（Hammer、ETS）。キーの解決は RateLimitKey
  （内部判定・クライアントキー・CF 規則は Python 版と同一）。
  確認の位置はプラグではなくアクション内（FastAPI では検証→制限→本体の順のため。
  先に数えると 422 と 429 の出る順序が逆転する）
- ユーザー名カウンタは滑走ウィンドウ（失敗が1件ずつ60秒で抜ける方式）のため
  Hammer の固定枠では表せず、LoginThrottle として自前の GenServer で実装
- プラグ：CurrentUser（Bearer 解決、失敗文言は3種を使い分け）、
  RequireAuthor（読者 403）、RequireAdmin（403）
- AuthController：POST /api/auth/signup、POST /api/auth/token（フォームのみ）、
  GET /api/auth/me、GET /api/auth/grants、POST /api/auth/declare-adult。
  422 は pydantic v2 の形に寄せた（実測：エラーに url フィールドは無し、
  フォーム側の missing は input が null、JSON 側は input がボディ全体）
- manage 相当：PlatformEx.Manage（create_admin/list_admins、文言は manage.py と同一）＋
  Mix.Tasks.Manage（対象DB を絶対パスで表示。対話入力の代わりに --password-env 必須）

検証：

- mix test：**51 tests, 0 failures**（手順1までの24＋今回27）
- Python 版との突き合わせ：同一の DB コピーから両サーバーを順に起動し、
  51ケースのシナリオ（~/workspace/platform-diff/scenario.py）を流して
  状態・Content-Type・本文を記録。**全52行が完全一致**
  （登録の 200/400/422、ログイン、me、ブロック 429（JSON）、送信元枠 429（テキスト）、
  クライアントキー分離、CF ヘッダ分離、年齢申告、許可一覧を含む）
- mix manage list-admins の実走：対象DB 表示と2行の状態表示が manage.py の形式どおり

既知の近似（差分として記録）：

- EmailStr の検証は近似（@ の有無・ドットの有無など実用範囲のみ）。
  email-validator の理由文は「@ が無い」場合だけ実測どおりで、それ以外は一般文
- 405 の本文など、閲覧側が使わない範囲は寄せていない
- 予約名の拒否は、Python 側では issue-admin-reserved.patch（適用待ち）に含まれる
  決定済み設計を先行実装したもの。突き合わせの Python 側は未適用 repo のため、
  予約名ケースは突き合わせ対象から外し、単体・結合テストで担保した

---

# 手順3：作品と加工ジョブ（2026-11-07 実施）

計画の前提を2件、現行コードで裏取りして訂正した（計画書にも訂正を入れた）：

- アップロード API は「加工完了まで待って応答」ではなく、job_id を即返しして
  背景加工＋進捗ポーリング（Python 版の現行契約そのまま）
- 進捗ストアは DB ではなくメモリ内（Python 版 upload_progress と同じ。
  再起動で消え、done/error は読み取り時に消える）。jobs テーブルは未使用のまま残置

実装：

- Works（作品の部屋）：一覧（settings.json 走査＋停止フラグ付与）、設定保存
  （公開には CBZ 必須、作成日時の保持、tmp＋rename の原子的書き換え、
  SettingsLock で直列化）、削除、アップロード受け付けと加工パイプライン
- Media（加工の部屋）：スクランブル（スパイクの join 方式を移設）、ページ名生成
  （base62＋乱数16桁）、リサイズ寸法は Pillow の thumbnail の実装どおり
  （round_aspect＝切り捨て/切り上げのうち縦横比が近い方、同点は切り捨て。
  銀行丸めではない。150/1.333…=112.5 が 113 になるケースで実証）、
  CBZ は ZIP_STORED（:zip の uncompress: :all）
- Jobs：進捗ストア（GenServer）＋同時実行2件の許可（Permits）＋Task.Supervisor。
  進捗の段階（queued/resize/scramble/zip/done/error）と数え方は Python 版と同一
- アップロードのスカラー値（do_scramble/tile_size）は **クエリパラメータだけ**が
  契約（フォームで送ると Python 版は読まず既定値になる。422 の loc も ["query", …]）。
  ファイル部品だけがフォーム由来
- multipart の組み立ては Plug.Parsers の :multipart_to_params に自前関数を差し、
  同名ファイル部品（files の繰り返し）をすべて集めるようにした
  （Plug 標準は最後の1つしか残さない）
- File.cp! はこの VM の overlayfs で "not owner" になるため、スプールへの
  写しは読み書きのストリーム複写にした（スパイク LiveView の受け取りも同手当て）
- ファイル配信（preview/thumb/cover）は Content-Type に charset を付けないよう
  ヘッダを直接設定。preview/thumb/cover は ?token= 認証（Bearer でない）

検証：

- mix test：**67 tests, 0 failures**（手順2までの51＋今回16）
- Python 版との突き合わせ（~/workspace/platform-diff/scenario3.py、30ケース）：
  応答の記録が**全行一致**（アップロード→進捗 done、設定、一覧、削除、
  各種 400/401/403/404/422、11MB の 400、フォーム値が読まれないことの固定を含む）
- 成果物の比較（compare3.py）：CBZ はエントリ数・STORED・名前の index 部が一致。
  復号したページは、リサイズ無しのものは**画素完全一致**、サムネイル・表紙も
  リサイズ無しは完全一致

既知の差分（記録）：

- リサイズ（Lanczos）を伴うページ／サムネイルの画素は、PIL と libvips の
  フィルタ実装差で最大 21/255 の差が出る（寸法は完全一致。検証用の
  高周波パターンでの最悪値で、リサイズ無しの経路はすべて完全一致）
- PNG/JPEG のバイト列はエンコーダ差で一致しない（画素と寸法で一致を取る方針）
- 壊れた画像ファイルのときの進捗 message は PIL と vips で文面が違う
  （「有効な画像ファイルがありませんでした」のケースは文言まで一致させた）

---

# 手順4：公開とアクセス制御（2026-11-07 実施）

実装：

- Access（アクセス制御の部屋）に執行判定を集約：公開停止、許可制
  （_enforce_premium_access の順序：匿名401→作者素通り→許可なし403→
  年齢未申告403）、年齢（無料作品のみ。内部通信＋X-Age-Verified: 1 でも可）。
  判定は Python の真値意味論に合わせ、age_restricted キー欠けでも落ちないようにした
- 許可の管理（grants）：作成は冪等（already フラグ）、自分宛400・相手不在404、
  一覧は created_at 順、削除は不在404。作品の存在確認は settings ファイルの有無
- 管理者：全作品一覧（note を落とす、停止フラグ付与）、公開停止（冪等で
  already_suspended＋元の理由を返す）、解除（lifted_at を立てる）
- 公開配信：カタログ（公開中のみ・停止除外・年齢作品は cover_url=null・
  note 除外）、CBZ（10/分・内部免除、ダウンロード名 title{tid}_ep{eid}.cbz、
  Cache-Control: public, max-age=3600）、サムネイル、表紙（年齢作品は403で
  表紙そのものを出さない。許可制でも表紙は公開＝執行しない）
- 文言の非対称も現行どおり：非公開の応答は CBZ が「この作品は非公開です」、
  サムネイル・表紙は「非公開です」
- 閲覧数：CBZ 配信成功時に settings.json の view_count を+1
  （同じ IP は1時間に1回まで。クールダウンはメモリ内の ViewCounts、
  記録は書き込み成功時にだけ更新＝Python 版の意味論どおり）
- /api/config は platform_base_url（Host ヘッダ由来）を返す
- 公開まわりのレート制限はカタログ5/分・CBZ 10/分、どちらも内部リクエスト免除

検証：

- mix test：**81 tests, 0 failures**（手順3までの67＋今回14）
- Python 版との突き合わせ（scenario4.py、45件）：**全行一致**
  （カタログ・閲覧数の増え方・執行マトリクス・許可 CRUD・停止/解除・
  レート制限の 429 になる回数まで）
- 閲覧側 Elixir の既存スイートを、相手を Elixir プラットフォームに替えて全 PASS：
  verify.sh **18/18**、verify_auth.sh **25/25**、verify_step3.sh **20/20**、
  verify_step4.sh **29/29**、verify_step5.sh **55/55**
  （前提：フィクスチャを再 seed し、プラットフォームはコピーでなく
  フィクスチャ実物に向ける。スイートは storage を直接動かすため。
  閲覧側には PLATFORM_BASE_URL／MANGA_INTERNAL_TOKEN／MANGA_TRUST_CF_HEADER=1／
  MANGA_CLIENT_KEY_SECRET を渡す。参照用 Python 閲覧側（:8002）は
  プロキシ env を空にして起動する＝この VM の NO_PROXY の角括弧 IPv6 記法で
  httpx が InvalidURL になるため）

突き合わせで外したもの（手順2と同じ扱い）：

- 管理者名（boss4）の通常登録：Elixir 側は予約名で拒否するのが確定済み設計、
  Python 側は未適用パッチのため登録できてしまう。両 DB に同じ管理者を
  直接作って突き合わせた

## 手順5（画面・LiveView）完了（2026-11-07）

- 前提の訂正：現行 Python 版の画面は複数ページではなく、GET / が返す単一ページ（埋め込みHTML＋手書きJS、タブ切替）に
  公開作品／マイ作品／管理／アップロード／アカウントが全部入っている。Elixir 版はこれを LiveView で組み直した。
- 構成：`/`=CatalogLive（公開作品）、`/login`=通常レンダリングのフォーム（送信は SessionController が受けて
  API と同じ JWT をセッションに入れる。LiveView では CSRF トークンを安全に出せないためフォームは通常レンダリング）、
  `/author`=AuthorLive（作品一覧・編集・閲覧許可・削除のモーダル＋アップロード）、`/admin`=AdminLive（全作品・停止/解除）。
  共通ナビとビューワーURLバーは root レイアウト（ビューワーURLはセッションに保存）。
- アップロードは LiveView のファイル入力→手順3の Works.start_upload を再利用し、進捗は Jobs の PubSub で受ける
  （Jobs.update に broadcast を追加）。加工完了後に設定を保存し、それから一覧を読み直す（順序が逆だと一覧に出ない）。
- 実装上の注意（実測）：consume_uploaded_entries のコールバックを抜けると LiveView の一時ファイルは消える。
  パスだけ持ち回ると start_upload の stat で enoent になるため、コールバック内で自分の tmp へ写してから渡すこと。
- ログインの確認順序・文言は API と揃えた（送信元枠→ユーザー名ブロック→資格情報）。signup も画面から可能。
- 削除したもの：スパイク用 /spike-upload とそのテスト、生成時の PageController・トップページ・そのテスト
  （`/` はカタログになったため）。
- 検証：mix test **75 tests, 0 failures**（81 から、削除した生成時/スパイクの 13 件を除き、画面の新規 7 件を追加）。
  実機確認（フィクスチャ＋実サーバー）：カタログ表示、CSS 200、未ログインの /author は 302、
  CSRF 込みの実ログイン→ダッシュボードに全7作品、ナビにユーザー名。
- 意図的な違い：見た目は Tailwind で組み直したため現行と同一ではない（構成・文言・機能は踏襲）。
  読者アカウントで /author を開くと「読者アカウントでは利用できません」の表示になる（API の 403 と同じ趣旨）。

## 手順6（配布と総検証）完了（2026-11-07）

- 配布形：`MIX_ENV=prod mix assets.deploy`（先に prod compile が必要。colocated CSS の解決のため）→
  `mix release --path /tmp/platform_ex_rel` → `~/workspace/platform_ex/release`（93MB、自己完結）。
  起動には PHX_SERVER=true と SECRET_KEY_BASE（必須）が要る。ポートは PORT（既定8000）。
  DB は MANGA_DB_PATH／storage は MANGA_STORAGE_DIR で差し替え可（既定はカレント相対）。
  prod の force_ssl は外した（Python 版と同じく平文 HTTP、TLS はトンネル終端）。url の既定も http/8000 に寄せた。
  この VM では ELIXIR_ERL_OPTIONS="+fnu" を付けないと起動ログの日本語が化ける。
- マイグレーション：`bin/platform_ex eval "PlatformEx.Release.migrate()"`（既存 DB への jobs 追加）。
- manage の release 版：`bin/platform_ex eval 'PlatformEx.ReleaseManage.run(["list-admins"])'` /
  `run(["create-admin", 名前, "--email", X, "--password-env", VAR])`（mix manage と同じ引数・文言）。
  eval では Repo が起動していないため with_repo で一時起動する。標準出力の文字コードも unicode に寄せた。
- **総検証で見つけた実バグ（release でのみ発生）**：prod は IPv6 ワイルドカード待ち受けのため、
  127.0.0.1 からの接続が ::ffff:127.0.0.1（IPv4 マップド）で届き、内部リクエスト判定（ループバック＋内部トークン）が
  素通りできずに外れていた。影響：閲覧側経由の年齢確認済みダウンロードが 403、ログインのクライアントキー分離が
  効かず閲覧側経由のログインが全部同じ枠（5/分）を分け合って 429 が頻発。dev は IPv4 バインドのため全テストで見えなかった。
  修正：RateLimitKey で マップド IPv4 を通常の IPv4 に正規化してから判定・キー生成する（単体テスト追加）。
- 総検証結果（すべて相手は最終 release）：
  - 閲覧側スイート：verify 18/18、verify_auth 25/25、verify_step3 20/20、verify_step4 29/29、verify_step5 55/55 全 PASS。
    （step4 の「Python download 505」が単発で落ちることがあるが、原因は参照用 Python 閲覧側自身の
    ダウンロードレート制限（ログに 429）で、間隔を空けると 29/29 になる。プラットフォーム側の問題ではない。）
  - Python 版との突き合わせ再実行（ツリーを作り直して両側とも新規実行）：手順2 scenario 52行・手順3 scenario 29行＋
    成果物比較 ALL EQUAL（リサイズ時の画素差は既知の Lanczos 実装差で最大21）・手順4 scenario 42行、すべて全行一致。
  - mix test **76 tests, 0 failures**（mix precommit も通過。format 修正1件・未使用変数の警告解消1件）。
- 残件（この実装の範囲外）：repo への取り込みはユーザーが後で判断。Discord 実送信は実 Webhook が無く未検証のまま。
