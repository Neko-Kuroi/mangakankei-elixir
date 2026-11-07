defmodule PlatformExWeb.AuthorLive do
  @moduledoc """
  作者ダッシュボード（現行の「マイ作品」「アップロード」ページ）。
  一覧・設定・削除・許可は手順3/4のコンテキストをそのまま使い、
  アップロードの進捗は Jobs の PubSub で受け取る。
  """
  use PlatformExWeb, :live_view

  alias PlatformEx.{Access, Jobs, Works}

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(
        page_title: "マイ作品",
        current_path: "/author",
        editing: nil,
        edit_msg: nil,
        grants: nil,
        deleting: nil,
        delete_msg: nil,
        job: nil,
        pending_settings: nil,
        upload_msg: nil,
        base_url: PlatformExWeb.LiveUtil.base_url(socket)
      )
      |> allow_upload(:pages,
        accept: ~w(.jpg .jpeg .png .webp),
        max_entries: 200,
        max_file_size: 125_000_000
      )
      |> allow_upload(:cover,
        accept: ~w(.jpg .jpeg .png .webp),
        max_entries: 1,
        max_file_size: 125_000_000
      )
      |> reload_works()

    {:ok, socket}
  end

  defp reload_works(socket) do
    assign(socket, works: Works.list_works(socket.assigns.current_user))
  end

  defp consume_files(socket, name) do
    consume_uploaded_entries(socket, name, fn %{path: path}, entry ->
      dest =
        Path.join(
          System.tmp_dir!(),
          "lv_upload_#{:erlang.unique_integer([:positive])}_#{entry.client_name}"
        )

      # File.cp! は overlayfs で EPERM になることがあるため読み書きで写す
      path
      |> File.stream!([], 64_000)
      |> Stream.into(File.stream!(dest))
      |> Stream.run()

      {:ok, %{path: dest, filename: entry.client_name}}
    end)
  end

  # ---------------------------------------------------------------------------
  # アップロード
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("validate-upload", _params, socket), do: {:noreply, socket}

  def handle_event("upload", params, socket) do
    user = socket.assigns.current_user

    with {title_id, ""} <- Integer.parse(params["title_id"] || ""),
         {episode_id, ""} <- Integer.parse(params["episode_id"] || "") do
      # consume のコールバック内で自分の tmp へ写す（コールバックを抜けると
      # LiveView の一時ファイルは消されるため、パスだけ持ち回ると消えている）
      files = consume_files(socket, :pages)

      cover =
        case consume_files(socket, :cover) do
          [first | _] -> first
          [] -> nil
        end

      do_scramble = params["do_scramble"] != "0"
      tile_size = parse_int(params["tile_size"], 16)

      result =
        Works.start_upload(user, title_id, episode_id, files, cover, do_scramble, tile_size)

      Enum.each(Enum.reject([cover | files], &is_nil/1), fn f -> File.rm(f.path) end)

      case result do
        {:ok, job_id, _total_files} ->
          Phoenix.PubSub.subscribe(PlatformEx.PubSub, "job:#{job_id}")

          {:noreply,
           assign(socket,
             job: %{"phase" => "queued", "current" => 0, "total" => length(files)},
             job_id: job_id,
             pending_settings: settings_from(params),
             upload_msg: nil
           )}

        {:error, _status, message} ->
          {:noreply, assign(socket, upload_msg: {:error, message})}
      end
    else
      _ -> {:noreply, assign(socket, upload_msg: {:error, "作品IDとエピソードIDは数値で指定してください"})}
    end
  end

  # ---------------------------------------------------------------------------
  # 編集・削除・許可
  # ---------------------------------------------------------------------------

  def handle_event("open-edit", %{"title" => t, "episode" => e}, socket) do
    work = find_work(socket, t, e)
    {:noreply, assign(socket, editing: work, edit_msg: nil)}
  end

  def handle_event("close-edit", _params, socket) do
    {:noreply, assign(socket, editing: nil)}
  end

  def handle_event("save-edit", params, socket) do
    user = socket.assigns.current_user
    {tid, ""} = Integer.parse(params["title_id"])
    {eid, ""} = Integer.parse(params["episode_id"])

    case Works.update_settings(user, tid, eid, settings_from(params)) do
      :ok ->
        {:noreply,
         socket
         |> assign(editing: nil)
         |> reload_works()
         |> put_flash(:info, "保存しました")}

      {:error, _st, msg} ->
        {:noreply, assign(socket, edit_msg: msg)}
    end
  end

  def handle_event("open-grants", %{"title" => t, "name" => name}, socket) do
    {tid, ""} = Integer.parse(t)
    {:noreply, assign(socket, grants: grant_state(socket, tid, name, nil))}
  end

  def handle_event("close-grants", _params, socket) do
    {:noreply, assign(socket, grants: nil)}
  end

  def handle_event("add-grant", %{"username" => username}, socket) do
    %{title_id: tid, title_name: name} = socket.assigns.grants
    author_id = socket.assigns.current_user.id

    msg =
      case Access.create_grant(author_id, tid, String.trim(username)) do
        {:ok, %{already: true}} -> {:info, "すでに許可済みです"}
        {:ok, _} -> {:info, "許可を追加しました"}
        {:error, _st, message} -> {:error, message}
      end

    {:noreply, assign(socket, grants: grant_state(socket, tid, name, msg))}
  end

  def handle_event("remove-grant", %{"user" => uid}, socket) do
    %{title_id: tid, title_name: name} = socket.assigns.grants
    author_id = socket.assigns.current_user.id
    {user_id, ""} = Integer.parse(uid)
    Access.delete_grant(author_id, tid, user_id)
    {:noreply, assign(socket, grants: grant_state(socket, tid, name, nil))}
  end

  def handle_event("open-delete", %{"title" => t, "episode" => e}, socket) do
    {:noreply, assign(socket, deleting: find_work(socket, t, e), delete_msg: nil)}
  end

  def handle_event("close-delete", _params, socket) do
    {:noreply, assign(socket, deleting: nil)}
  end

  def handle_event("confirm-delete", _params, socket) do
    user = socket.assigns.current_user
    work = socket.assigns.deleting

    case Works.delete_episode(user, work["title_id"], work["episode_id"]) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(deleting: nil)
         |> reload_works()
         |> put_flash(:info, "削除しました")}

      {:error, _st, msg} ->
        {:noreply, assign(socket, delete_msg: msg)}
    end
  end

  def handle_event("refresh", _params, socket), do: {:noreply, reload_works(socket)}

  @impl true
  def handle_info({:job_progress, job_id, progress}, socket) do
    if socket.assigns[:job_id] != job_id do
      {:noreply, socket}
    else
      case progress["phase"] do
        "done" ->
          Jobs.pop(job_id)
          socket = finish_upload(socket)
          {:noreply, socket}

        "error" ->
          Jobs.pop(job_id)

          {:noreply,
           assign(socket,
             job: nil,
             job_id: nil,
             pending_settings: nil,
             upload_msg: {:error, "❌ " <> (progress["message"] || "加工に失敗しました")}
           )}

        _ ->
          {:noreply, assign(socket, job: progress)}
      end
    end
  end

  defp finish_upload(socket) do
    user = socket.assigns.current_user
    settings = socket.assigns.pending_settings

    socket = assign(socket, job: nil, job_id: nil, pending_settings: nil)

    socket =
      case settings do
        %{"title_id" => tid, "episode_id" => eid} = s ->
          case Works.update_settings(user, tid, eid, Map.drop(s, ["title_id", "episode_id"])) do
            :ok -> assign(socket, upload_msg: {:info, "✅ アップロードと設定の保存が完了しました"})
            {:error, _st, msg} -> assign(socket, upload_msg: {:error, "設定の保存に失敗: " <> msg})
          end

        _ ->
          assign(socket, upload_msg: {:info, "✅ アップロードが完了しました"})
      end

    # 設定を書いてから一覧を読み直す（一覧は settings.json を走査するため）
    reload_works(socket)
  end

  # ---------------------------------------------------------------------------

  defp grant_state(socket, title_id, title_name, msg) do
    %{
      title_id: title_id,
      title_name: title_name,
      list: Access.list_grants(socket.assigns.current_user.id, title_id),
      msg: msg
    }
  end

  defp find_work(socket, t, e) do
    {tid, ""} = Integer.parse(t)
    {eid, ""} = Integer.parse(e)

    Enum.find(socket.assigns.works, fn w ->
      w["title_id"] == tid and w["episode_id"] == eid
    end)
  end

  defp settings_from(params) do
    %{
      "title_id" => parse_int(params["title_id"], 0),
      "episode_id" => parse_int(params["episode_id"], 0),
      "status" => params["status"] || "draft",
      "access_level" => params["access_level"] || "public",
      "title_name" => params["title_name"] || "",
      "episode_name" => params["episode_name"] || "",
      "caption" => params["caption"] || "",
      "comment" => params["comment"] || "",
      "note" => params["note"] || "",
      "scrambled" => params["do_scramble"] != "0",
      "tile_size" => parse_int(params["tile_size"], 16),
      "webhook_enabled" => params["webhook_enabled"] == "true",
      "age_restricted" => params["age_restricted"] == "true"
    }
  end

  defp parse_int(v, default) do
    case Integer.parse(to_string(v || "")) do
      {n, ""} -> n
      _ -> default
    end
  end

  # ---------------------------------------------------------------------------
  # 画面
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <%= if @current_user.account_type == "reader" do %>
        <p class="bg-amber-50 border border-amber-200 rounded p-4">
          読者アカウントでは利用できません（作者向けの画面です）。
        </p>
      <% else %>
        <h2 class="text-lg font-semibold mb-4">📋 マイ作品管理</h2>
        <button phx-click="refresh" class="border rounded px-3 py-1.5 text-sm mb-4">🔄 更新</button>

        <%= if @works == [] do %>
          <div class="text-center text-slate-400 py-8">作品がありません。下のフォームからアップロードしてください。</div>
        <% end %>

        <div class="space-y-4 mb-10">
          <div :for={w <- @works} class="flex gap-4 border rounded-lg p-4">
            <%= if w["has_cover"] do %>
              <img
                src={"/api/author/cover/#{w["title_id"]}/#{w["episode_id"]}?token=#{@user_token}"}
                alt="cover"
                class="w-20 h-28 object-cover rounded"
              />
            <% else %>
              <div class="w-20 h-28 bg-slate-100 rounded flex items-center justify-center text-2xl">
                📖
              </div>
            <% end %>
            <div class="flex-1">
              <div class="font-semibold">{w["title_name"]} — {w["episode_name"]}</div>
              <div class="mt-1 space-x-1">
                <span class={"px-2 py-0.5 rounded text-xs font-semibold " <> elem(badge_status(w["status"]), 0)}>
                  {elem(badge_status(w["status"]), 1)}
                </span>
                <span class={"px-2 py-0.5 rounded text-xs font-semibold " <> elem(badge_access(w["access_level"]), 0)}>
                  {elem(badge_access(w["access_level"]), 1)}
                </span>
                <span
                  :if={w["suspended"]}
                  class="px-2 py-0.5 rounded text-xs font-semibold bg-red-100 text-red-700"
                >
                  ⛔ 公開停止中
                </span>
                <span :if={!w["has_cbz"]} class="text-red-500 text-xs">⚠ CBZ未生成</span>
              </div>
              <div class="mt-3 flex gap-2 flex-wrap">
                <%= if w["has_cbz"] and @viewer_url != "" do %>
                  <a
                    href={@viewer_url <> "/reader?" <> URI.encode_query(%{"url" => @base_url <> "/api/author/preview/#{w["title_id"]}/#{w["episode_id"]}.cbz?token=#{@user_token}"})}
                    target="_blank"
                    rel="noopener"
                    class="bg-blue-600 text-white px-3 py-1.5 rounded text-sm font-semibold"
                  >
                    ▶ プレビュー
                  </a>
                <% end %>
                <button
                  phx-click="open-edit"
                  phx-value-title={w["title_id"]}
                  phx-value-episode={w["episode_id"]}
                  class="border rounded px-3 py-1.5 text-sm"
                >
                  ✏️ 編集
                </button>
                <button
                  phx-click="open-grants"
                  phx-value-title={w["title_id"]}
                  phx-value-name={w["title_name"]}
                  class="border rounded px-3 py-1.5 text-sm"
                >
                  🔑 閲覧許可
                </button>
                <button
                  phx-click="open-delete"
                  phx-value-title={w["title_id"]}
                  phx-value-episode={w["episode_id"]}
                  class="border border-red-300 text-red-600 rounded px-3 py-1.5 text-sm"
                >
                  🗑️ 削除
                </button>
              </div>
            </div>
          </div>
        </div>

        <hr class="my-8" />

        <h2 id="upload" class="text-lg font-semibold mb-4">📤 原稿アップロード</h2>
        <p
          :if={@upload_msg && elem(@upload_msg, 0) == :error}
          class="bg-red-50 text-red-700 rounded p-3 mb-3 text-sm"
        >
          {elem(@upload_msg, 1)}
        </p>
        <p
          :if={@upload_msg && elem(@upload_msg, 0) == :info}
          class="bg-emerald-50 text-emerald-700 rounded p-3 mb-3 text-sm"
        >
          {elem(@upload_msg, 1)}
        </p>

        <form id="upload-form" phx-submit="upload" phx-change="validate-upload" class="space-y-4">
          <div class="grid grid-cols-2 gap-3">
            <div>
              <label class="block text-sm font-semibold mb-1">作品タイトル名</label>
              <input
                type="text"
                name="title_name"
                placeholder="例: 鬼の城"
                class="w-full border rounded px-2.5 py-2 text-sm"
              />
            </div>
            <div>
              <label class="block text-sm font-semibold mb-1">エピソード名</label>
              <input
                type="text"
                name="episode_name"
                placeholder="例: 第1話"
                class="w-full border rounded px-2.5 py-2 text-sm"
              />
            </div>
            <div>
              <label class="block text-sm font-semibold mb-1">作品ID</label>
              <input
                type="number"
                name="title_id"
                value="1"
                min="1"
                class="w-full border rounded px-2.5 py-2 text-sm"
              />
            </div>
            <div>
              <label class="block text-sm font-semibold mb-1">エピソードID</label>
              <input
                type="number"
                name="episode_id"
                value="1"
                min="1"
                class="w-full border rounded px-2.5 py-2 text-sm"
              />
            </div>
          </div>
          <div>
            <label class="block text-sm font-semibold mb-1">キャプション
            <span class="font-normal text-slate-400">（任意・公開）</span></label>
            <textarea
              name="caption"
              placeholder="作品の紹介文"
              class="w-full border rounded px-2.5 py-2 text-sm"
            ></textarea>
          </div>
          <div>
            <label class="block text-sm font-semibold mb-1">作者コメント
            <span class="font-normal text-slate-400">（任意・公開）</span></label>
            <textarea
              name="comment"
              placeholder="読者へのコメント"
              class="w-full border rounded px-2.5 py-2 text-sm"
            ></textarea>
          </div>
          <div>
            <label class="block text-sm font-semibold mb-1">備考
            <span class="font-normal text-amber-700">（非公開・自分のみ）</span></label>
            <textarea
              name="note"
              placeholder="管理メモ、素材フォルダパスなど"
              class="w-full border rounded px-2.5 py-2 text-sm"
            ></textarea>
          </div>
          <div class="grid grid-cols-2 gap-3">
            <div>
              <label class="block text-sm font-semibold mb-1">公開状態</label>
              <select name="status" class="w-full border rounded px-2.5 py-2 text-sm">
                <option value="draft">下書き（非公開）</option>
                <option value="published">公開</option>
              </select>
            </div>
            <div>
              <label class="block text-sm font-semibold mb-1">アクセス権限</label>
              <select name="access_level" class="w-full border rounded px-2.5 py-2 text-sm">
                <option value="public">無料公開</option>
                <option value="premium">許可した人だけ読める</option>
              </select>
            </div>
          </div>
          <div>
            <label class="block text-sm font-semibold mb-1">🔒 画像スクランブル</label>
            <div class="flex gap-4 text-sm">
              <label><input type="radio" name="do_scramble" value="1" checked /> する（推奨）</label>
              <label><input type="radio" name="do_scramble" value="0" /> しない</label>
              <span>
                タイルサイズ:
                <select name="tile_size" class="border rounded px-1.5 py-1">
                  <option value="16" selected>16px（推奨）</option>
                  <option value="8">8px（高強度）</option>
                  <option value="32">32px（軽量）</option>
                </select>
              </span>
            </div>
          </div>
          <label class="block text-sm">
            <input type="hidden" name="age_restricted" value="false" />
            <input type="checkbox" name="age_restricted" value="true" /> 年齢確認が必要な作品にする（18歳未満は閲覧できません）
          </label>
          <label class="block text-sm">
            <input type="hidden" name="webhook_enabled" value="false" />
            <input type="checkbox" name="webhook_enabled" value="true" /> Discord Webhook送信を許可する
          </label>
          <div>
            <label class="block text-sm font-semibold mb-1">原稿画像（複数可）</label>
            <.live_file_input upload={@uploads.pages} class="block text-sm" />
            <div :for={entry <- @uploads.pages.entries} class="text-xs text-slate-500">
              {entry.client_name}
            </div>
          </div>
          <div>
            <label class="block text-sm font-semibold mb-1">表紙画像（任意）</label>
            <.live_file_input upload={@uploads.cover} class="block text-sm" />
          </div>

          <%= if @job do %>
            <div class="bg-slate-50 border rounded p-3 text-sm">
              加工中… {@job["phase"]}（{@job["current"]}/{@job["total"]}）
              <div class="h-2 bg-slate-200 rounded mt-2">
                <div
                  class="h-2 bg-blue-500 rounded"
                  style={"width: #{if @job["total"] > 0, do: round(@job["current"] / @job["total"] * 100), else: 0}%"}
                >
                </div>
              </div>
            </div>
          <% else %>
            <button
              type="submit"
              class="w-full bg-blue-600 text-white px-4 py-2.5 rounded font-semibold"
            >
              📤 アップロードして ZIP 化
            </button>
          <% end %>
        </form>

        <.edit_modal :if={@editing} work={@editing} msg={@edit_msg} />
        <.grants_modal :if={@grants} grants={@grants} />
        <.delete_modal :if={@deleting} work={@deleting} msg={@delete_msg} />
      <% end %>
    </Layouts.app>
    """
  end

  defp edit_modal(assigns) do
    ~H"""
    <div class="fixed inset-0 bg-black/50 flex items-center justify-center z-50">
      <div class="bg-white rounded-lg p-6 w-full max-w-lg max-h-[90vh] overflow-y-auto">
        <h3 class="font-semibold mb-4">✏️ エピソード編集</h3>
        <p :if={@msg} class="bg-red-50 text-red-700 rounded p-2 mb-3 text-sm">{@msg}</p>
        <form id="edit-form" phx-submit="save-edit" class="space-y-3">
          <input type="hidden" name="title_id" value={@work["title_id"]} />
          <input type="hidden" name="episode_id" value={@work["episode_id"]} />
          <div>
            <label class="block text-sm font-semibold mb-1">作品タイトル名</label>
            <input
              type="text"
              name="title_name"
              value={@work["title_name"]}
              class="w-full border rounded px-2.5 py-2 text-sm"
            />
          </div>
          <div>
            <label class="block text-sm font-semibold mb-1">エピソード名</label>
            <input
              type="text"
              name="episode_name"
              value={@work["episode_name"]}
              class="w-full border rounded px-2.5 py-2 text-sm"
            />
          </div>
          <div>
            <label class="block text-sm font-semibold mb-1">キャプション</label>
            <textarea name="caption" class="w-full border rounded px-2.5 py-2 text-sm">{@work["caption"]}</textarea>
          </div>
          <div>
            <label class="block text-sm font-semibold mb-1">作者コメント</label>
            <textarea name="comment" class="w-full border rounded px-2.5 py-2 text-sm">{@work["comment"]}</textarea>
          </div>
          <div>
            <label class="block text-sm font-semibold mb-1">備考（非公開）</label>
            <textarea name="note" class="w-full border rounded px-2.5 py-2 text-sm">{@work["note"]}</textarea>
          </div>
          <div class="grid grid-cols-2 gap-3">
            <div>
              <label class="block text-sm font-semibold mb-1">公開状態</label>
              <select name="status" class="w-full border rounded px-2.5 py-2 text-sm">
                <option value="draft" selected={@work["status"] != "published"}>下書き（非公開）</option>
                <option value="published" selected={@work["status"] == "published"}>公開</option>
              </select>
            </div>
            <div>
              <label class="block text-sm font-semibold mb-1">アクセス権限</label>
              <select name="access_level" class="w-full border rounded px-2.5 py-2 text-sm">
                <option value="public" selected={@work["access_level"] != "premium"}>無料公開</option>
                <option value="premium" selected={@work["access_level"] == "premium"}>
                  許可した人だけ読める
                </option>
              </select>
            </div>
          </div>
          <div class="text-sm flex gap-4">
            <label>
              <input type="radio" name="do_scramble" value="1" checked={@work["scrambled"] != false} />
              スクランブルする
            </label>
            <label>
              <input type="radio" name="do_scramble" value="0" checked={@work["scrambled"] == false} />
              しない
            </label>
            <span>
              タイル:
              <select name="tile_size" class="border rounded px-1.5 py-1">
                <option value="8" selected={@work["tile_size"] == 8}>8px</option>
                <option value="16" selected={@work["tile_size"] not in [8, 32]}>16px</option>
                <option value="32" selected={@work["tile_size"] == 32}>32px</option>
              </select>
            </span>
          </div>
          <label class="block text-sm">
            <input type="hidden" name="age_restricted" value="false" />
            <input
              type="checkbox"
              name="age_restricted"
              value="true"
              checked={@work["age_restricted"] == true}
            /> 年齢確認が必要な作品にする
          </label>
          <label class="block text-sm">
            <input type="hidden" name="webhook_enabled" value="false" />
            <input
              type="checkbox"
              name="webhook_enabled"
              value="true"
              checked={@work["webhook_enabled"] == true}
            /> Discord Webhook送信を許可する
          </label>
          <div class="flex justify-end gap-2 pt-2">
            <button type="button" phx-click="close-edit" class="border rounded px-4 py-2 text-sm">キャンセル</button>
            <button
              type="submit"
              class="bg-blue-600 text-white px-4 py-2 rounded text-sm font-semibold"
            >💾 保存</button>
          </div>
        </form>
      </div>
    </div>
    """
  end

  defp grants_modal(assigns) do
    ~H"""
    <div class="fixed inset-0 bg-black/50 flex items-center justify-center z-50">
      <div class="bg-white rounded-lg p-6 w-full max-w-md">
        <h3 class="font-semibold mb-2">🔑 閲覧許可</h3>
        <p class="text-sm text-slate-500 mb-3">作品： {@grants.title_name}</p>
        <p
          :if={@grants.msg && elem(@grants.msg, 0) == :error}
          class="bg-red-50 text-red-700 rounded p-2 mb-3 text-sm"
        >
          {elem(@grants.msg, 1)}
        </p>
        <p
          :if={@grants.msg && elem(@grants.msg, 0) == :info}
          class="bg-emerald-50 text-emerald-700 rounded p-2 mb-3 text-sm"
        >
          {elem(@grants.msg, 1)}
        </p>
        <div class="space-y-1 mb-4">
          <%= if @grants.list == [] do %>
            <div class="text-sm text-slate-500">許可しているユーザーはいません</div>
          <% end %>
          <div :for={g <- @grants.list} class="flex items-center gap-2 py-1">
            <span class="flex-1 text-sm">👤 {g.username}</span>
            <button
              phx-click="remove-grant"
              phx-value-user={g.user_id}
              class="bg-red-500 text-white px-3 py-1 rounded text-xs"
            >
              取り消し
            </button>
          </div>
        </div>
        <form id="grant-form" phx-submit="add-grant" class="flex gap-2">
          <input
            type="text"
            name="username"
            placeholder="ユーザー名"
            required
            class="flex-1 border rounded px-2.5 py-2 text-sm"
          />
          <button type="submit" class="bg-blue-600 text-white px-4 py-2 rounded text-sm font-semibold">追加</button>
        </form>
        <div class="flex justify-end mt-4">
          <button phx-click="close-grants" class="border rounded px-4 py-2 text-sm">閉じる</button>
        </div>
      </div>
    </div>
    """
  end

  defp delete_modal(assigns) do
    ~H"""
    <div class="fixed inset-0 bg-black/50 flex items-center justify-center z-50">
      <div class="bg-white rounded-lg p-6 w-full max-w-md">
        <h3 class="font-semibold mb-3">🗑️ 削除の確認</h3>
        <p class="text-sm mb-2">
          「{@work["title_name"]} — {@work["episode_name"]}」を削除しますか？（原稿・設定・表紙・サムネイルが消えます）
        </p>
        <p :if={@msg} class="bg-red-50 text-red-700 rounded p-2 mb-3 text-sm">{@msg}</p>
        <div class="flex justify-end gap-2">
          <button phx-click="close-delete" class="border rounded px-4 py-2 text-sm">キャンセル</button>
          <button
            phx-click="confirm-delete"
            class="bg-red-500 text-white px-4 py-2 rounded text-sm font-semibold"
          >
            削除する
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp badge_access(level) do
    if level == "public",
      do: {"bg-emerald-100 text-emerald-700", "無料"},
      else: {"bg-amber-100 text-amber-700", "許可制"}
  end

  defp badge_status(status) do
    if status == "published",
      do: {"bg-blue-100 text-blue-700", "公開中"},
      else: {"bg-slate-200 text-slate-600", "下書き"}
  end
end
