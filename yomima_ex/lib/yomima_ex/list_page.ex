defmodule YomimaEx.ListPage do
  @moduledoc """
  ホーム画面（ライブラリ）と、その部分 HTML。
  Python 版 templates/list.html + partials/manga_list.html のなぞり。
  全体は Router の page_shell に載せ、部分 HTML は /manga/add と
  /manga/remove がそのまま返す（htmx の差し替え対象）。
  リストの実体はサーバーに無く、share パラメータ（base64 の JSON）が
  持ち回る（Python 版と同じ）。
  """

  alias YomimaEx.Manga

  defp esc(s), do: Plug.HTML.html_escape(to_string(s || ""))

  def index(manga_list, share_param, import_message) do
    badge =
      if manga_list != [] do
        ~s(<span class="count-badge">#{length(manga_list)} / #{Manga.max_manga_count()}</span>)
      else
        ""
      end

    import_html =
      if import_message do
        ~s(<p class="msg-error" style="margin-top:1rem;">#{esc(import_message)}</p>)
      else
        ""
      end

    """
    <script src="https://unpkg.com/htmx.org@1.9.12/dist/htmx.min.js"></script>
    <input type="hidden" id="share-param"  value="#{esc(share_param)}">
    <input type="hidden" id="webhook1-val" value="">
    <input type="hidden" id="webhook2-val" value="">

    <div class="section-label">アーカイブを追加</div>
    <div class="add-form">
      <input
        class="input url-field"
        id="new-url"
        type="url"
        placeholder="https://example.com/manga.zip"
        autocomplete="off"
        spellcheck="false"
      >
      <button class="btn btn-primary add-btn" onclick="submitAdd()">追加</button>
    </div>

    <div class="section-label">Discord Webhook <span style="font-size:0.65rem;opacity:.6">（任意）</span></div>
    <div class="webhook-grid">
      <input class="input" id="wh1" type="url" placeholder="https://discord.com/api/webhooks/…" oninput="syncWebhooks()">
      <input class="input" id="wh2" type="url" placeholder="https://discord.com/api/webhooks/…" oninput="syncWebhooks()">
    </div>

    <hr class="divider">

    <div id="list-root">
      <div class="section-label">
        ライブラリ
        #{badge}
      </div>
      #{partial(manga_list, nil)}
    </div>

    <div id="share-panel" hidden style="margin-top:1rem;padding:1rem 1.1rem;background:var(--bg2);border:1px solid var(--border);border-radius:var(--radius);">
      <div class="section-label" style="margin-bottom:.5rem;">共有URL <span style="font-size:.65rem;opacity:.6">（クリックで全選択）</span></div>
      <div id="share-url-display" class="share-url-box">—</div>
    </div>

    #{import_html}

    <script>
      function syncWebhooks() {
        document.getElementById('webhook1-val').value = document.getElementById('wh1').value;
        document.getElementById('webhook2-val').value = document.getElementById('wh2').value;
      }

      function syncShareFromResponse(evt) {
        const pushUrl = evt.detail.xhr.getResponseHeader('HX-Push-Url');
        if (pushUrl) {
          const newShare = new URLSearchParams(pushUrl.split('?')[1] || '').get('share') || '';
          document.getElementById('share-param').value = newShare;
        }
      }

      function submitAdd() {
        const url   = document.getElementById('new-url').value.trim();
        const share = document.getElementById('share-param').value;
        if (!url) return;
        htmx.ajax('POST', '/manga/add', {
          values: { url, share },
          target: '#list-root',
          swap: 'innerHTML',
        });
        document.getElementById('new-url').value = '';
      }

      document.getElementById('new-url').addEventListener('keydown', e => {
        if (e.key === 'Enter') submitAdd();
      });

      function submitRemove(mangaUrl) {
        const share = document.getElementById('share-param').value;
        htmx.ajax('POST', '/manga/remove', {
          values: { url: mangaUrl, share },
          target: '#list-root',
          swap: 'innerHTML',
        });
      }

      document.body.addEventListener('htmx:afterRequest', syncShareFromResponse);

      function openReader(mangaUrl) {
        const share = document.getElementById('share-param').value;
        const wh1   = document.getElementById('wh1').value;
        const wh2   = document.getElementById('wh2').value;
        const params = new URLSearchParams({ url: mangaUrl, share });
        if (wh1) params.set('webhook1', wh1);
        if (wh2) params.set('webhook2', wh2);
        location.href = '/reader?' + params.toString();
      }

      async function generateShareUrl() {
        const share = document.getElementById('share-param').value;
        if (!share) return;
        const el = document.getElementById('share-url-display');
        el.textContent = '生成中…';
        try {
          const res  = await fetch(`/share/url?share=${encodeURIComponent(share)}&shorten=true`);
          el.textContent = await res.text();
        } catch {
          const base = location.origin + '/?share=' + encodeURIComponent(share);
          el.textContent = base;
        }
        const range = document.createRange();
        range.selectNodeContents(el);
        window.getSelection().removeAllRanges();
        window.getSelection().addRange(range);
      }

      function toggleShare() {
        const panel = document.getElementById('share-panel');
        panel.hidden = !panel.hidden;
        if (!panel.hidden) generateShareUrl();
      }

      (function () {
        const params = new URLSearchParams(location.search);
        const sp  = params.get('share')    || '';
        const wh1 = params.get('webhook1') || '';
        const wh2 = params.get('webhook2') || '';
        document.getElementById('share-param').value = sp;
        if (wh1) document.getElementById('wh1').value = wh1;
        if (wh2) document.getElementById('wh2').value = wh2;

        // ナビリンクにも share / webhook を引き継ぐ
        const qs = params.toString();
        if (qs) {
          const mylist = document.getElementById('nav-mylist');
          if (mylist) mylist.href = '/?' + qs;
          const pub = document.getElementById('nav-public');
          if (pub) pub.href = '/public?' + qs;
        }
      })();
    </script>
    """
  end

  def partial(manga_list, error) do
    error_html =
      if error, do: "<p class=\"msg-error\">⚠ #{esc(error)}</p>\n", else: ""

    body =
      if manga_list == [] do
        """
        <div class="empty-state">
          <span class="icon">📚</span>
          マンガがまだありません。<br>上のフォームにURLを入力して追加してください。
        </div>
        """
      else
        items = Enum.map_join(manga_list, "\n", &item/1)

        remaining =
          if length(manga_list) < Manga.max_manga_count() do
            ~s(<span class="msg-info">あと #{Manga.max_manga_count() - length(manga_list)} 件追加できます</span>)
          else
            ~s(<span class="msg-error">リストが満杯です（#{Manga.max_manga_count()}件）</span>)
          end

        """
        <ul class="manga-list">
        #{items}
        </ul>
        <div style="margin-top:1.25rem;display:flex;gap:0.5rem;flex-wrap:wrap;align-items:center;">
            #{remaining}
          <button class="btn btn-sm" style="margin-left:auto;" onclick="toggleShare()">🔗 URL共有</button>
        </div>
        """
      end

    error_html <> body <> time_script()
  end

  defp item(m) do
    added = m["added_time"] || 0

    """
      <li class="manga-item" data-url="#{esc(m["url"])}">
        <div class="manga-info">
          <div class="manga-title">#{esc(m["title"])}</div>
          <div class="manga-title-sub">
            <time datetime="#{trunc(added)}"></time>
          </div>
        </div>
        <button class="btn btn-sm"
          onclick="openReader(this.closest('.manga-item').dataset.url)">読む</button>
        <button class="btn btn-sm btn-ghost"
          onclick="submitRemove(this.closest('.manga-item').dataset.url)">削除</button>
      </li>
    """
  end

  # partials/manga_list.html 末尾のスクリプト（追加日時の整形）
  defp time_script do
    """
    <script>
      document.querySelectorAll('.manga-title-sub time').forEach(el => {
        const ts = parseInt(el.getAttribute('datetime'), 10);
        if (!ts) return;
        el.textContent = new Date(ts * 1000).toLocaleDateString('ja-JP', {
          year: 'numeric', month: 'short', day: 'numeric',
          hour: '2-digit', minute: '2-digit',
        });
      });
    </script>
    """
  end
end
