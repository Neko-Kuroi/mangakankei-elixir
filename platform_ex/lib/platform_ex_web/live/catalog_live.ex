defmodule PlatformExWeb.CatalogLive do
  @moduledoc "公開作品の一覧（現行の「公開作品」ページ）。データは Works.public_catalog（API と同じ）。"
  use PlatformExWeb, :live_view

  alias PlatformEx.Works

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: "公開作品", current_path: "/")
      |> load_catalog()

    {:ok, socket}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, load_catalog(socket)}
  end

  defp load_catalog(socket) do
    assign(socket, catalog: Works.public_catalog(PlatformExWeb.LiveUtil.base_url(socket)))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <h2 class="text-lg font-semibold mb-4">🔍 公開中の作品</h2>
      <button phx-click="refresh" class="border rounded px-3 py-1.5 text-sm mb-4">🔄 更新</button>

      <%= if @catalog == [] do %>
        <div class="text-center text-slate-400 py-10">公開中の作品はありません</div>
      <% end %>

      <div class="space-y-4">
        <div :for={m <- @catalog} class="flex gap-4 border rounded-lg p-4">
          <%= if m["cover_url"] do %>
            <img src={m["cover_url"]} alt="cover" class="w-24 h-32 object-cover rounded" />
          <% else %>
            <div class="w-24 h-32 bg-slate-100 rounded flex items-center justify-center text-3xl">
              📖
            </div>
          <% end %>
          <div class="flex-1">
            <div class="font-semibold">{m["title_name"]} — {m["episode_name"]}</div>
            <div class="text-sm text-slate-500 mt-1">
              👤 {m["author_name"]}
              <span class={"ml-2 px-2 py-0.5 rounded text-xs font-semibold " <> if(m["access_level"] == "public", do: "bg-emerald-100 text-emerald-700", else: "bg-amber-100 text-amber-700")}>
                {if m["access_level"] == "public", do: "無料", else: "許可制"}
              </span>
              <%= if m["age_restricted"] do %>
                <span class="ml-1 px-2 py-0.5 rounded text-xs font-semibold bg-red-100 text-red-700">年齢確認</span>
              <% end %>
            </div>
            <div :if={m["caption"]} class="text-sm mt-2">{m["caption"]}</div>
            <%= if @viewer_url != "" do %>
              <a
                href={@viewer_url <> "/reader?" <> URI.encode_query(%{"url" => m["cbz_url"]})}
                target="_blank"
                rel="noopener"
                class="inline-block mt-3 bg-blue-600 text-white px-4 py-1.5 rounded text-sm font-semibold"
              >
                📖 読む
              </a>
            <% else %>
              <span class="block text-xs text-slate-400 mt-2">ビューワーURL未設定</span>
            <% end %>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
