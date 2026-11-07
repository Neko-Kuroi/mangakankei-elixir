defmodule YomimaEx.Router do
  @moduledoc """
  閲覧側スパイクのルーター。Python 版 yomima/main.py のエンドポイントをなぞる。
  """
  use Plug.Router

  alias YomimaEx.{ListPage, Manga, Platform, Store}

  @rate_limit_message "混み合っています。少し待ってから再試行してください"
  @upstream_message "プラットフォームとの通信に失敗しました"
  @invalid_credentials_message "ユーザー名またはパスワードが正しくありません"

  plug(Plug.Parsers, parsers: [:urlencoded, :multipart], pass: ["*/*"])
  plug(:fetch_cookies)
  plug(:match)
  plug(:dispatch)

  # ------------------------------------------------------------------
  # helpers
  # ------------------------------------------------------------------
  defp json(conn, status, map) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(map))
  end

  defp error_json(conn, status, detail), do: json(conn, status, %{detail: detail})

  defp html(conn, status, body) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(status, body)
  end

  defp esc(s), do: Plug.HTML.html_escape(to_string(s || ""))

  defp current_reader(conn) do
    case conn.cookies["viewer_auth"] do
      nil -> nil
      token -> Store.get_auth(token)
    end
  end

  defp age_gate_passed?(conn, reader) do
    cond do
      Store.age_gate_ok?(conn.cookies["age_gate"] || "") ->
        true

      reader != nil ->
        case Platform.me(reader.platform_token) do
          {:ok, me} -> me["adult_declared_at"] != nil
          _ -> false
        end

      true ->
        false
    end
  end

  defp require_session(conn, url) do
    token = conn.params["session_token"] || ""
    session = Store.get_session(token)

    cond do
      session == nil ->
        {:error, 403, "セッションが無効または期限切れです"}

      session.cbz_url != url ->
        {:error, 403, "セッションのURLが一致しません"}

      session.unlock_user_id != nil and not unlock_ok?(conn, session) ->
        {:error, 403, "この作品を読む権限がありません"}

      true ->
        {:ok, session}
    end
  end

  defp unlock_ok?(conn, session) do
    case current_reader(conn) do
      nil -> false
      reader -> reader.user_id == session.unlock_user_id
    end
  end

  defp declared?(reader) do
    case Platform.me(reader.platform_token) do
      {:ok, me} -> me["adult_declared_at"] != nil
      _ -> false
    end
  end

  # ------------------------------------------------------------------
  # ページ
  # ------------------------------------------------------------------
  get "/" do
    share = conn.params["share"] || ""

    {manga_list, import_message} =
      if share == "" do
        {[], nil}
      else
        case Manga.decode_manga_list(share) do
          {list, ""} -> {list, nil}
          {_, err} -> {[], err}
        end
      end

    reader = current_reader(conn)
    html(conn, 200, page_shell(conn, reader, ListPage.index(manga_list, share, import_message)))
  end

  # 作品登録（自分のリストへ追加）。リストの実体は share パラメータが
  # 持ち回り、応答は部分 HTML + HX-Push-Url（Python 版 manga_add と同じ）。
  post "/manga/add" do
    url = conn.params["url"] || ""
    title = conn.params["title"] || ""
    share = conn.params["share"] || ""
    {manga_list, _} = decode_share_param(share)

    error =
      cond do
        not Manga.validate_manga_url(url) ->
          "URLは .zip / .cbz / .rar / .cbr である必要があります"

        true ->
          case Manga.fetch_allowed?(url) do
            {false, reason} ->
              reason

            {true, _} ->
              cond do
                length(manga_list) >= Manga.max_manga_count() ->
                  "最大 #{Manga.max_manga_count()} 件まで登録できます"

                Enum.any?(manga_list, &(&1["url"] == url)) ->
                  "このURLはすでに追加されています"

                true ->
                  nil
              end
          end
      end

    manga_list =
      if error, do: manga_list, else: manga_list ++ [Manga.build_manga_entry(url, title)]

    respond_manga_list(conn, manga_list, error)
  end

  post "/manga/remove" do
    url = conn.params["url"] || ""
    share = conn.params["share"] || ""
    {manga_list, _} = decode_share_param(share)
    respond_manga_list(conn, Enum.reject(manga_list, &(&1["url"] == url)), nil)
  end

  defp decode_share_param(share) do
    if share == "", do: {[], ""}, else: Manga.decode_manga_list(share)
  end

  defp respond_manga_list(conn, manga_list, error) do
    new_share = if manga_list == [], do: "", else: Manga.encode_manga_list(manga_list)
    push_url = if new_share == "", do: "/", else: "/?share=#{new_share}"

    conn
    |> put_resp_header("hx-push-url", push_url)
    |> html(200, ListPage.partial(manga_list, error))
  end

  get "/share/url" do
    share = conn.params["share"] || ""
    shorten = conn.params["shorten"] not in ["false", "0", "off", "no", "False", "OFF", "No"]
    full_url = "#{base_url(conn)}/?share=#{URI.encode(share, &URI.char_unreserved?/1)}"
    result = if shorten, do: Manga.shorten_url(full_url), else: full_url

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, result)
  end

  defp base_url(conn) do
    default_port = if conn.scheme == :https, do: 443, else: 80
    port_part = if conn.port == default_port, do: "", else: ":#{conn.port}"
    "#{conn.scheme}://#{conn.host}#{port_part}"
  end

  # Discord 送信。応答は常に 200 の HTML 断片（htmx の表示先に差し込む）
  # で、検証の順序と文言は Python 版 discord_send と同じ。
  post "/discord/send" do
    url = conn.params["url"] || ""
    filename = conn.params["filename"] || ""
    webhook1 = conn.params["webhook1"] || ""
    webhook2 = conn.params["webhook2"] || ""
    session_token = conn.params["session_token"] || ""
    session = Store.get_session(session_token)

    cond do
      session == nil or session.cbz_url != url ->
        html(conn, 200, "<span class='status-error'>セッションが無効です</span>")

      not webhook_enabled_for?(url) ->
        html(conn, 200, "<span class='status-error'>この作品では Discord 送信が許可されていません</span>")

      true ->
        case Manga.extracted_path(url, filename) do
          nil ->
            html(conn, 200, "<span class='status-error'>不正なファイル名です</span>")

          path ->
            webhooks = Enum.reject([webhook1, webhook2], &(&1 == ""))

            if webhooks == [] do
              html(conn, 200, "<span class='status-error'>Webhookが設定されていません</span>")
            else
              errors = Manga.send_image_to_discord(path, webhooks, Path.basename(path))

              if errors == [] do
                html(conn, 200, "<span class='status-ok'>✓ 送信しました</span>")
              else
                joined = Enum.map_join(errors, "<br>", &esc/1)
                html(conn, 200, "<span class='status-error'>#{joined}</span>")
              end
            end
        end
    end
  end

  # 作者の Discord 送信許可（プラットフォーム作品のみカタログで確認する。
  # 外部URLは許可、カタログに無い・取得できない場合は不許可）
  defp webhook_enabled_for?(url) do
    if String.contains?(url, "/api/public/cbz/") do
      case Platform.catalog_entry(url) do
        nil -> false
        entry -> entry["webhook_enabled"] == true
      end
    else
      true
    end
  end

  get "/public" do
    reader = current_reader(conn)

    entitled =
      if reader, do: Platform.grants(reader.platform_token, reader.user_id), else: MapSet.new()

    case Platform.catalog() do
      {:ok, items} ->
        list =
          Enum.map_join(items, "\n", fn m ->
            key = {m["author_id"], m["title_id"]}

            badge =
              cond do
                m["access_level"] == "public" -> ~s(<span style="color:green">無料</span>)
                MapSet.member?(entitled, key) -> ~s(<span style="color:green">許可制・読めます</span>)
                true -> ~s(<span style="color:#b45309">🔒 許可制</span>)
              end

            age = if m["age_restricted"], do: " · 🔞 年齢確認", else: ""

            cover =
              if m["cover_url"],
                do: ~s(<img src="#{esc(m["cover_url"])}" style="width:60px;height:90px;object-fit:cover">),
                else: "📖"

            """
            <li style="display:flex;gap:12px;padding:1rem 0;border-bottom:1px solid #ddd">
              #{cover}
              <div>
                <div><strong>#{esc(m["title_name"])} — #{esc(m["episode_name"])}</strong></div>
                <div>👤 #{esc(m["author_name"])} · #{badge}#{age}</div>
                <div>#{esc(m["caption"])}</div>
                <a href="/reader?url=#{URI.encode_www_form(m["cbz_url"])}"><button>読む</button></a>
              </div>
            </li>
            """
          end)

        html(conn, 200, page_shell(conn, reader, "<h2>公開中の作品</h2><ul>#{list}</ul>"))

      {:error, msg} ->
        html(conn, 200, page_shell(conn, reader, "<p>⚠ カタログの取得に失敗しました: #{esc(msg)}</p>"))
    end
  end

  get "/reader" do
    url = conn.params["url"] || ""

    cond do
      not Manga.validate_manga_url(url) ->
        error_json(conn, 400, "無効なURL")

      true ->
        case Manga.fetch_allowed?(url) do
          {false, reason} ->
            error_json(conn, 400, reason)

          {true, _} ->
            entry = Platform.catalog_entry(url)
            reader = current_reader(conn)
            is_premium = entry != nil and entry["access_level"] == "premium"
            is_age = entry != nil and entry["age_restricted"] == true
            age_passed = if is_age, do: age_gate_passed?(conn, reader), else: false

            title =
              if entry,
                do: "#{entry["title_name"]} — #{entry["episode_name"]}",
                else: url |> String.split("/") |> List.last()

            show_lock = (is_premium and reader == nil) or (is_age and not age_passed)

            lock_html =
              cond do
                is_premium and reader == nil ->
                  "🔒 この作品は許可制です。読むには、上のフォームから読者アカウントでログインしてください（許可は作家から出ます）。"

                is_age and not age_passed ->
                  ~s[🔞 この作品は年齢対象です。18歳以上の方だけ読めます。 <button class="btn btn-sm btn-primary" onclick="declareAge()">私は18歳以上です</button>]

                true ->
                  ""
              end

            # Python 版 reader と同じ規則: プラットフォーム作品はカタログの
            # webhook_enabled に従い、外部URLは常に許可
            is_platform_url = String.contains?(url, "/api/public/cbz/")

            webhook_enabled =
              cond do
                not is_platform_url -> true
                entry != nil -> entry["webhook_enabled"] == true
                true -> false
              end

            body =
              YomimaEx.ReaderPage.render(%{
                url: url,
                title: title,
                share_param: conn.params["share"] || "",
                webhook1: conn.params["webhook1"] || "",
                webhook2: conn.params["webhook2"] || "",
                show_lock: show_lock,
                lock_html: lock_html,
                scrambled: entry != nil and entry["scrambled"] == true,
                tile_size: (entry && entry["tile_size"]) || 16,
                webhook_enabled: webhook_enabled,
                reader_logged_in: reader != nil
              })

            html(conn, 200, page_shell(conn, reader, body))
        end
    end
  end

  defp page_shell(_conn, reader, inner) do
    auth_area =
      if reader do
        """
        <span>👤 #{esc(reader.username)} でログイン中</span>
        <button onclick="viewerLogout()">ログアウト</button>
        <button id="auth-declare" onclick="viewerDeclareAdult()">年齢申告（18歳以上）</button>
        <span id="auth-msg" style="color:#dc2626"></span>
        """
      else
        """
        <span>未ログイン</span>
        <input id="auth-user" placeholder="ユーザー名">
        <input id="auth-email" placeholder="メール（登録時のみ）">
        <input id="auth-pass" type="password" placeholder="パスワード">
        <button onclick="viewerLogin()">ログイン</button>
        <button onclick="viewerRegister()">新規登録</button>
        <span id="auth-msg" style="color:#dc2626"></span>
        """
      end

    """
    <!DOCTYPE html><html lang="ja"><head><meta charset="utf-8"><title>よみま (Elixir spike)</title></head>
    <body>
    <header class="site-header" style="border-bottom:1px solid #ddd;padding:.5rem 0">
      <a id="nav-public" href="/public">📖 公開作品</a> · <span>読者アカウント:</span> #{auth_area}
    </header>
    #{inner}
    <script>
    async function postAuth(path, fields) {
      const fd = new FormData();
      for (const k in fields) fd.append(k, fields[k]);
      const r = await fetch(path, {method: 'POST', body: fd});
      const d = await r.json().catch(() => ({}));
      if (!r.ok) throw new Error(d.detail || '失敗しました');
      return d;
    }
    function authMsg(t) { document.getElementById('auth-msg').textContent = t || ''; }
    async function viewerLogin() {
      try { await postAuth('/auth/login', {username: document.getElementById('auth-user').value, password: document.getElementById('auth-pass').value}); location.reload(); }
      catch(e) { authMsg(e.message); }
    }
    async function viewerRegister() {
      const email = document.getElementById('auth-email').value.trim();
      if (!email) { authMsg('登録にはメールアドレスも入力してください'); return; }
      try { await postAuth('/auth/register', {username: document.getElementById('auth-user').value, email: email, password: document.getElementById('auth-pass').value}); location.reload(); }
      catch(e) { authMsg(e.message); }
    }
    async function viewerLogout() { try { await fetch('/auth/logout', {method: 'POST'}); } catch(e) {} location.reload(); }
    async function viewerDeclareAdult() {
      try {
        const r = await fetch('/auth/declare-adult', {method: 'POST'});
        const d = await r.json().catch(() => ({}));
        if (!r.ok) throw new Error(d.detail || '年齢申告に失敗しました');
        authMsg('年齢申告を記録しました');
      } catch(e) { authMsg(e.message); }
    }
    </script>
    </body></html>
    """
  end

  # ------------------------------------------------------------------
  # 認証 API
  # ------------------------------------------------------------------
  # ログインして読者セッションを開始する（ログイン・登録後の自動ログイン共通）。
  # エラーの出し分けは Python 版 _platform_login と同じ:
  # 429 は混雑の案内、資格情報の不一致は 401、それ以外は 502。
  defp login_and_start_session(conn, username, password, headers) do
    case Platform.login(username, password, headers) do
      {:ok, token} ->
        case Platform.me(token) do
          {:ok, me} -> start_auth_session(conn, token, me)
          _ -> error_json(conn, 502, @upstream_message)
        end

      {:error, :rate_limited} ->
        error_json(conn, 429, @rate_limit_message)

      {:error, :upstream} ->
        error_json(conn, 502, @upstream_message)

      {:error, :invalid} ->
        error_json(conn, 401, @invalid_credentials_message)
    end
  end

  defp start_auth_session(conn, token, me) do
    cookie = Store.new_token()

    Store.put_auth(cookie, %{
      platform_token: token,
      user_id: me["id"],
      username: me["username"]
    })

    conn
    |> put_resp_cookie("viewer_auth", cookie,
      http_only: true,
      max_age: Store.auth_ttl(),
      path: "/",
      same_site: "Lax"
    )
    |> json(200, %{username: me["username"]})
  end

  post "/auth/login" do
    login_and_start_session(
      conn,
      conn.params["username"] || "",
      conn.params["password"] || "",
      Platform.auth_headers(conn)
    )
  end

  post "/auth/register" do
    headers = Platform.auth_headers(conn)
    username = conn.params["username"] || ""
    password = conn.params["password"] || ""

    case Platform.signup(username, conn.params["email"] || "", password, headers) do
      :ok ->
        login_and_start_session(conn, username, password, headers)

      {:error, :rate_limited} ->
        error_json(conn, 429, @rate_limit_message)

      {:error, {:detail, detail}} ->
        error_json(conn, 400, detail)

      {:error, :upstream} ->
        error_json(conn, 502, @upstream_message)
    end
  end

  post "/auth/logout" do
    if token = conn.cookies["viewer_auth"], do: Store.delete_auth(token)

    conn
    |> delete_resp_cookie("viewer_auth", path: "/")
    |> json(200, %{status: "logged_out"})
  end

  get "/auth/me" do
    case current_reader(conn) do
      nil ->
        error_json(conn, 401, "ログインしていません")

      reader ->
        case Platform.me(reader.platform_token) do
          {:ok, me} ->
            json(conn, 200, me)

          {:error, :unauthorized} ->
            if token = conn.cookies["viewer_auth"], do: Store.delete_auth(token)
            error_json(conn, 401, "ログインの有効期限が切れました")

          _ ->
            error_json(conn, 502, "プラットフォームとの通信に失敗しました")
        end
    end
  end

  post "/auth/declare-adult" do
    case current_reader(conn) do
      nil ->
        error_json(conn, 401, "ログインしていません")

      reader ->
        case Platform.declare_adult(reader.platform_token) do
          {:ok, body} -> json(conn, 200, body)
          {:error, :unauthorized} -> error_json(conn, 401, "ログインの有効期限が切れました")
          _ -> error_json(conn, 502, "プラットフォームとの通信に失敗しました")
        end
    end
  end

  post "/age/declare" do
    cookie = Store.new_token()
    Store.put_age_gate(cookie)

    conn
    |> put_resp_cookie("age_gate", cookie,
      http_only: true,
      max_age: Store.age_gate_ttl(),
      path: "/",
      same_site: "Lax"
    )
    |> json(200, %{status: "declared"})
  end

  # ------------------------------------------------------------------
  # 読書セッション
  # ------------------------------------------------------------------
  get "/session" do
    url = conn.params["url"] || ""

    cond do
      not Manga.validate_manga_url(url) ->
        error_json(conn, 400, "無効なURL")

      true ->
        case Manga.fetch_allowed?(url) do
          {false, reason} ->
            error_json(conn, 400, reason)

          {true, _} ->
            entry = Platform.catalog_entry(url)
            reader = current_reader(conn)

            cond do
              entry != nil and entry["access_level"] == "premium" ->
                if reader == nil do
                  error_json(conn, 401, "この作品を読むにはログインが必要です")
                else
                  issue_session(conn, url, %{
                    unlock_user_id: reader.user_id,
                    auth_token: reader.platform_token,
                    age_verified: false
                  })
                end

              entry != nil and entry["age_restricted"] == true ->
                cond do
                  reader != nil and declared?(reader) ->
                    issue_session(conn, url, %{age_verified: true})

                  reader != nil ->
                    error_json(conn, 403, "年齢対象の作品です。先に年齢申告をしてください")

                  Store.age_gate_ok?(conn.cookies["age_gate"] || "") ->
                    issue_session(conn, url, %{age_verified: true})

                  true ->
                    error_json(conn, 403, "年齢対象の作品です。年齢確認をしてください")
                end

              true ->
                issue_session(conn, url, %{})
            end
        end
    end
  end

  defp issue_session(conn, url, extra) do
    token = Store.new_token()

    entry =
      Map.merge(
        %{cbz_url: url, unlock_user_id: nil, auth_token: nil, age_verified: false},
        extra
      )

    Store.put_session(token, entry)
    json(conn, 200, %{session_token: token, expires_in: Store.session_ttl()})
  end

  get "/download/start" do
    url = conn.params["url"] || ""

    case require_session(conn, url) do
      {:error, status, msg} ->
        error_json(conn, status, msg)

      {:ok, session} ->
        case Manga.fetch_allowed?(url) do
          {false, reason} ->
            error_json(conn, 400, reason)

          {true, _} ->
            conn =
              conn
              |> put_resp_content_type("text/event-stream")
              |> send_chunked(200)

            parent = self()

            task =
              Task.async(fn ->
                Manga.download(url, Manga.archive_path(url), session, fn frac ->
                  send(parent, {:dl_progress, frac})
                end)
              end)

            {conn, result} = sse_await(conn, task.ref)

            case result do
              {:ok, _} -> chunk_or(conn, "data: done\n\n")
              {:error, msg} -> chunk_or(conn, "data: error:#{msg}\n\n")
            end
        end
    end
  end

  # ダウンロードの進捗メッセージを受け取りながら SSE を中継する
  defp sse_await(conn, ref) do
    receive do
      {:dl_progress, frac} ->
        sse_await(chunk_or(conn, "data: #{Float.round(frac, 3)}\n\n"), ref)

      {^ref, result} ->
        Process.demonitor(ref, [:flush])
        {conn, result}
    after
      120_000 -> {conn, {:error, "ダウンロードがタイムアウトしました"}}
    end
  end

  defp chunk_or(conn, data) do
    case Plug.Conn.chunk(conn, data) do
      {:ok, conn} -> conn
      _ -> conn
    end
  end

  # Python 版 images_partial と同じバッチ契約:
  # batch-meta（total / next-offset / has-more / pending）＋ .img-block 群を返す。
  # page_size は limit > 0 のとき limit、それ以外は IMAGES_PER_LOAD = 1。
  @images_per_load 1

  get "/images" do
    url = conn.params["url"] || ""
    offset = max(parse_int(conn.params["offset"], 0), 0)
    limit = max(parse_int(conn.params["limit"], 0), 0)

    case require_session(conn, url) do
      {:error, status, msg} ->
        error_json(conn, status, msg)

      {:ok, _session} ->
        case Manga.fetch_allowed?(url) do
          {false, reason} ->
            error_json(conn, 400, reason)

          {true, _} ->
            case Manga.image_files(url) do
              {:error, :not_downloaded} ->
                html(conn, 200, """
                <div id="batch-meta"
                  data-total="0"
                  data-next-offset="0"
                  data-has-more="false"
                  data-pending="true"
                  hidden>
                </div>
                """)

              {:ok, files, warnings} ->
                total = length(files)
                page_size = if limit > 0, do: limit, else: @images_per_load
                batch = Enum.slice(files, offset, page_size)
                next_offset = offset + length(batch)
                has_more = next_offset < total
                token = conn.params["session_token"] || ""
                hash = Manga.url_hash(url)

                blocks =
                  batch
                  |> Enum.with_index(offset)
                  |> Enum.map_join("\n", fn {name, i} ->
                    """
                    <div class="img-block">
                      <img
                        src="/image/#{token}/#{hash}/#{esc(name)}"
                        alt="ページ #{i + 1} / #{total}"
                        onerror="retryImg(this, 0)"
                      >
                      <button
                        class="discord-btn"
                        data-filename="#{esc(name)}"
                        onclick="sendDiscord(this.dataset.filename, this.nextElementSibling)"
                      >Discord ↑ #{i + 1}/#{total}</button>
                      <div class="discord-status"></div>
                    </div>
                    """
                  end)

                warnings_html =
                  if warnings == [] do
                    ""
                  else
                    items =
                      Enum.map_join(warnings, "\n", fn w -> "<div>⚠ #{esc(w)}</div>" end)

                    """
                    <div style="font-size:0.72rem;color:var(--text-dim);margin-top:0.5rem;">
                    #{items}
                    </div>
                    """
                  end

                html(conn, 200, """
                <div id="batch-meta"
                  data-total="#{total}"
                  data-next-offset="#{next_offset}"
                  data-has-more="#{has_more}"
                  data-pending="false"
                  hidden>
                </div>
                #{blocks}
                #{warnings_html}
                """)
            end
        end
    end
  end

  defp parse_int(nil, default), do: default

  defp parse_int(value, default) do
    case Integer.parse(to_string(value)) do
      {n, _} -> n
      :error -> default
    end
  end

  get "/image/:session_token/:url_hash/:filename" do
    session = Store.get_session(session_token)

    cond do
      session == nil ->
        error_json(conn, 403, "セッションが無効または期限切れです")

      Manga.url_hash(session.cbz_url) != url_hash ->
        error_json(conn, 403, "不正なアクセスです")

      session.unlock_user_id != nil and not unlock_ok?(conn, session) ->
        error_json(conn, 403, "この作品を読む権限がありません")

      true ->
        case Manga.image_path(session.cbz_url, filename) do
          nil ->
            error_json(conn, 404, "画像が見つかりません")

          path ->
            conn
            |> put_resp_content_type(Manga.content_type(filename))
            |> put_resp_header("cache-control", "private, max-age=3600")
            |> send_file(200, path)
        end
    end
  end

  # サムネイル応答に付けるヘッダ（返してよい Content-Type は Platform.image_media_type/1）
  @thumb_headers [
    {"cache-control", "private, max-age=86400"},
    {"x-content-type-options", "nosniff"}
  ]

  get "/thumbnail" do
    url = conn.params["url"] || ""
    index = conn.params["index"] || "0"

    case require_session(conn, url) do
      {:error, status, msg} ->
        error_json(conn, status, msg)

      {:ok, session} ->
        case Manga.fetch_allowed?(url) do
          {false, reason} ->
            error_json(conn, 400, reason)

          {true, _} ->
            thumbnail_response(conn, url, index, session)
        end
    end
  end

  # プラットフォームのサムネイルを優先し、取れなければキャッシュから生成する
  # （Python 版 serve_thumbnail と同じ）。
  defp thumbnail_response(conn, url, index, session) do
    case proxy_thumbnail(url, index, session) do
      {body, content_type} ->
        conn
        |> put_resp_content_type(content_type)
        |> put_thumb_headers(@thumb_headers)
        |> send_resp(200, body)

      nil ->
        fallback_thumbnail(conn, url, index)
    end
  end

  # 組み立てた thumb URL は、利用者が渡した url の文字列から作る。外部ホストの
  # url でも宛先ポリシーは通るので、プラットフォームのオリジンのときだけ
  # 取りに行く（内部トークンと読者トークンを外部へ送らない）。外部の作品は
  # nil を返し、ダウンロード済みの中身から作るフォールバックに回る。
  defp proxy_thumbnail(url, index, session) do
    with thumb_url when is_binary(thumb_url) <- build_thumb_url(url, index),
         true <- Platform.platform_origin?(thumb_url) do
      headers =
        Platform.internal_headers()
        |> add_header(session.auth_token && String.contains?(thumb_url, "/api/public/thumb/"),
          {"authorization", "Bearer #{session.auth_token}"})
        |> add_header(session.age_verified && String.contains?(thumb_url, "/api/public/thumb/"),
          {"x-age-verified", "1"})

      # redirect: false … 宛先ポリシーを通っていない先へ辿らせない
      # decode_body: false … 本文はバイト列のまま受け取る
      case Req.new()
           |> Req.get(
             url: thumb_url,
             headers: headers,
             receive_timeout: 5_000,
             redirect: false,
             decode_body: false
           ) do
        {:ok, %{status: 200, body: body} = resp} when is_binary(body) ->
          case Platform.image_media_type(Req.Response.get_header(resp, "content-type")) do
            nil -> nil
            content_type -> {body, content_type}
          end

        _ ->
          nil
      end
    else
      _ -> nil
    end
  end

  defp fallback_thumbnail(conn, url, index) do
    archive = Manga.archive_path(url)
    idx = parse_int(index, -1)

    cond do
      not File.exists?(archive) ->
        error_json(conn, 404, "アーカイブが見つかりません")

      true ->
        files =
          case Manga.image_files(url) do
            {:ok, files, _warnings} -> files
            _ -> []
          end

        cond do
          idx < 0 or idx >= length(files) ->
            error_json(conn, 404, "ページが見つかりません")

          true ->
            data =
              case Manga.image_path(url, Enum.at(files, idx)) do
                nil -> nil
                path -> Manga.load_image_bytes(path, {80, 120})
              end

            case data do
              nil ->
                error_json(conn, 500, "サムネイル生成失敗")

              data ->
                content_type =
                  case data do
                    <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _::binary>> -> "image/png"
                    _ -> "image/jpeg"
                  end

                conn
                |> put_resp_content_type(content_type)
                |> put_thumb_headers(@thumb_headers)
                |> send_resp(200, data)
            end
        end
    end
  end

  defp put_thumb_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {k, v}, c -> put_resp_header(c, k, v) end)
  end

  defp add_header(headers, flag, header) do
    if flag, do: headers ++ [header], else: headers
  end

  defp build_thumb_url(url, index) do
    cond do
      String.contains?(url, "/api/public/cbz/") ->
        [base, rest] = String.split(url, "/api/public/cbz/", parts: 2)
        parts = rest |> String.replace_suffix(".cbz", "") |> String.split("/")

        if length(parts) == 3 do
          "#{base}/api/public/thumb/#{Enum.join(parts, "/")}/#{index}"
        end

      String.contains?(url, "/api/author/preview/") ->
        [base_and_path, query] =
          case String.split(url, "?", parts: 2) do
            [p, q] -> [p, q]
            [p] -> [p, ""]
          end

        [base, rest] = String.split(base_and_path, "/api/author/preview/", parts: 2)
        parts = rest |> String.replace_suffix(".cbz", "") |> String.split("/")

        if length(parts) == 2 do
          u = "#{base}/api/author/thumb/#{Enum.join(parts, "/")}/#{index}"
          if query != "", do: u <> "?" <> query, else: u
        end

      true ->
        nil
    end
  end

  match _ do
    error_json(conn, 404, "not found")
  end
end
