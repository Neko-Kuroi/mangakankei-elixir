defmodule PlatformExWeb.AdminLive do
  @moduledoc "管理者ビュー（現行の「管理」ページ）。全作品の一覧と公開停止/解除。"
  use PlatformExWeb, :live_view

  alias PlatformEx.{Access, Works}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "管理", current_path: "/admin")
     |> load_groups()}
  end

  defp load_groups(socket) do
    groups =
      Works.admin_works()
      |> Enum.group_by(fn w -> {w["author_id"], w["title_id"]} end)
      |> Enum.map(fn {{author_id, title_id}, episodes} ->
        first = hd(episodes)

        %{
          author_id: author_id,
          title_id: title_id,
          author_name: first["author_name"] || "",
          title_name: first["title_name"] || "作品#{title_id}",
          suspended: first["suspended"] == true,
          suspend_reason: first["suspend_reason"] || "",
          episodes: episodes
        }
      end)

    assign(socket, groups: groups)
  end

  @impl true
  def handle_event("refresh", _params, socket), do: {:noreply, load_groups(socket)}

  def handle_event("suspend", %{"author_id" => a, "title_id" => t, "reason" => reason}, socket) do
    {author_id, ""} = Integer.parse(a)
    {title_id, ""} = Integer.parse(t)

    socket =
      case Access.suspend(socket.assigns.current_user, author_id, title_id, reason || "") do
        {:ok, %{status: "already_suspended"}} ->
          put_flash(socket, :error, "すでに公開停止中です")

        {:ok, _} ->
          put_flash(socket, :info, "公開を停止しました")
      end

    {:noreply, load_groups(socket)}
  end

  def handle_event("resume", %{"author" => a, "title" => t}, socket) do
    {author_id, ""} = Integer.parse(a)
    {title_id, ""} = Integer.parse(t)

    socket =
      case Access.resume(author_id, title_id) do
        {:ok, _} -> put_flash(socket, :info, "公開停止を解除しました")
        {:error, _st, msg} -> put_flash(socket, :error, msg)
      end

    {:noreply, load_groups(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <h2 class="text-lg font-semibold mb-4">🛡 管理者：全作品</h2>
      <button phx-click="refresh" class="border rounded px-3 py-1.5 text-sm mb-4">🔄 更新</button>

      <%= if @groups == [] do %>
        <div class="text-center text-slate-400 py-10">作品がありません</div>
      <% end %>

      <div class="space-y-4">
        <div :for={g <- @groups} class="border rounded-lg p-4">
          <div class="font-semibold">
            {g.title_name}
            <span class="font-normal text-slate-500 text-sm">👤 {g.author_name}</span>
          </div>
          <div class="text-sm text-slate-600 my-2">
            {Enum.map_join(g.episodes, "、", fn w ->
              "#{w["episode_name"] || "エピソード#{w["episode_id"]}"}（#{if w["status"] == "published", do: "公開中", else: "下書き"}・#{if w["access_level"] == "public", do: "無料", else: "許可制"}）"
            end)}
          </div>
          <div :if={g.suspended and g.suspend_reason != ""} class="text-sm text-slate-600">
            理由：{g.suspend_reason}
          </div>
          <div class="mt-3">
            <%= if g.suspended do %>
              <span class="text-red-600 font-bold mr-3">⛔ 公開停止中</span>
              <button
                phx-click="resume"
                phx-value-author={g.author_id}
                phx-value-title={g.title_id}
                class="bg-blue-600 text-white px-4 py-1.5 rounded text-sm font-semibold"
              >
                解除する
              </button>
            <% else %>
              <form phx-submit="suspend" class="flex gap-2">
                <input type="hidden" name="author_id" value={g.author_id} />
                <input type="hidden" name="title_id" value={g.title_id} />
                <input
                  type="text"
                  name="reason"
                  placeholder="停止の理由（任意）"
                  class="flex-1 border rounded px-2.5 py-1.5 text-sm"
                />
                <button
                  type="submit"
                  class="bg-red-500 text-white px-4 py-1.5 rounded text-sm font-semibold"
                >
                  公開を停止
                </button>
              </form>
            <% end %>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
