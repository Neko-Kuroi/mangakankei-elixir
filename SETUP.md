# 開発環境の準備と起動

このリポジトリには、プラットフォーム（`platform_ex`）と閲覧アプリ
（`yomima_ex`）の2つのElixirアプリがあります。ローカルで試すときは
プラットフォームを先に起動し、その後に閲覧アプリを起動します。

## 1. 必要な環境

- Erlang/OTP と Elixir
  - このリポジトリの動作確認環境は Erlang/OTP `27.3.4.2`、Elixir `1.18.4`。
  - 両アプリの `mix.exs` に記載されたElixir要件を満たすバージョンを使います。
- Mix、Hex、Rebar3
- Git（Hex依存にGitHubから取得するパッケージが含まれます）
- Linuxでは `:image` / Vix が使う libvips と、ネイティブ依存のビルドに必要なツール
  （例: `libvips-dev`, `pkg-config`, `build-essential`）

既存の検証環境では、OTPとElixirを `~/elixir-tools/` に配置し、
`source ~/elixir-tools/env.sh` でPATHを設定していました。新しいシェルで作業する場合は、
まず利用する環境に合わせてErlang/Elixirを有効にしてください。

```sh
elixir --version
mix --version
```

Hex / Rebar3がまだ使えない場合は一度だけインストールします。

```sh
mix local.hex --force
mix local.rebar --force
```

## 2. プラットフォームの依存関係とDB

```sh
cd platform_ex
mix setup
```

`mix setup` は依存関係の取得、EctoのDB準備、アセット用ツールの取得とビルドを行います。
開発用DBの既定パスは `platform_ex/storage/manga_platform.db` です。
必要なら起動前に `MANGA_DB_PATH` で別のDBファイルを指定できます。

**注意:** プラットフォームの既存ユーザー等のテーブルはPython版との互換用で、
Elixir側のマイグレーションは追加テーブル（`jobs`）だけを作成します。
空のSQLiteファイルだけではアプリを完全には利用できません。既存の互換DBを用意し、
DBファイルを上書き・削除しないでください。`storage/` やDBをGitへ登録する必要もありません。

## 3. 内部トークンを設定してプラットフォームを起動

以下は開発用の例です。トークンには任意のローカル専用値を使い、
両方のアプリに同じ値を設定してください。

```sh
# platform_ex/ で実行
export MANGA_INTERNAL_TOKEN='replace-with-a-local-dev-token'
mix phx.server
```

プラットフォームは既定で `http://127.0.0.1:8000` で待ち受けます。
ブラウザで [`http://127.0.0.1:8000`](http://127.0.0.1:8000) を開いて起動を確認できます。
DB内に公開作品がない場合、カタログが空でもサーバー起動自体は正常です。

## 4. 閲覧アプリを起動

別のターミナルを開き、リポジトリの `yomima_ex/` で実行します。

```sh
cd yomima_ex
mix deps.get

PLATFORM_BASE_URL='http://127.0.0.1:8000' \
MANGA_INTERNAL_TOKEN='replace-with-a-local-dev-token' \
mix run --no-halt
```

`PLATFORM_BASE_URL` はプラットフォームが返す作品URLと同じオリジンにします。
ローカル開発では上記の `127.0.0.1` を両アプリで統一してください。
閲覧アプリは既定で `http://localhost:8001` で待ち受けます。別ポートを使う場合は
`VIEWER_PORT` を設定します。

ブラウザで [`http://localhost:8001`](http://localhost:8001) を開きます。
CBZのキャッシュ先は既定で `/tmp/manga_cache_ex` です。必要なら
`MANGA_CACHE_DIR` で変更できます。

各ターミナルで `Ctrl-C` を押すと、そのアプリを停止できます。

## 5. よく使う設定

| 環境変数 | アプリ | 既定値 / 用途 |
|---|---|---|
| `MANGA_INTERNAL_TOKEN` | 両方 | 未設定なら空。閲覧アプリからの内部通信に使うため、設定する場合は両方で同じ値にする |
| `PLATFORM_BASE_URL` | 閲覧 | `http://localhost:8000`。接続先プラットフォームのURL |
| `PORT` | プラットフォーム | `8000`。HTTP待受ポート |
| `VIEWER_PORT` | 閲覧 | `8001`。HTTP待受ポート |
| `MANGA_DB_PATH` | プラットフォーム | 開発時は `platform_ex/storage/manga_platform.db`。SQLite DBの保存先 |
| `MANGA_STORAGE_DIR` | プラットフォーム | カレントディレクトリの `storage/`。CBZ等の保存先 |
| `MANGA_CACHE_DIR` | 閲覧 | `/tmp/manga_cache_ex`。ダウンロード・展開キャッシュ |

JWT署名鍵とクライアントキー用の秘密値は、明示設定がなければ必要になった時に
それぞれ `platform_ex/instance/secret_key` と
`yomima_ex/instance/client_key_secret` へ自動生成されます。
これらの `instance/` ディレクトリはGitへ登録せず、運用で秘密値を維持する場合は
削除せずに保管してください。

プラットフォームの開発起動では `SECRET_KEY_BASE` は不要です。
本番モードでは別途本番用の秘密値などが必要で、この手順の対象外です。

## 補足: 依存取得で失敗する環境

最初の検証環境では `mix local.hex` の自己ダウンロードが権限エラーになったため、
Hexアーカイブを手動配置し、Rebar3も手動で配置しました。また、Hexの依存取得が
一時的なTLS切断やタイムアウトになることがありました。その場合は接続を確認して
再試行してください。これはそのVM固有の回避策であり、通常の環境では上記の
`mix local.hex` / `mix local.rebar` を使います。
