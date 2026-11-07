defmodule YomimaEx.ReaderPage do
  @moduledoc """
  リーダーページ本体（Python 版 templates/reader.html のなぞり）。
  画面部品・スタイル・スクリプトを文字列で返し、Router が page_shell で包む。
  スクリプトは Python 版と同一のものを埋め込み、サーバー由来の定数
  （SCRAMBLED / tileSize / WEBHOOK_ENABLED / READER_LOGGED_IN）だけを
  プレースホルダ経由で差し替える。
  """

  defp esc(s), do: Plug.HTML.html_escape(to_string(s || ""))

  def render(a) do
    lock_display = if a.show_lock, do: "block", else: "none"

    body = """
    <style>
    .reader-header { display:flex; align-items:center; gap:.5rem; padding:.2rem 0; }
    .reader-title { font-size:.85rem; flex:1; min-width:0; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
    #wh-bar { display:none; grid-template-columns:1fr 1fr; gap:.4rem; padding:.4rem .6rem; background:#181614; border:1px solid #3a3530; border-radius:6px; margin-bottom:.2rem; }
    #wh-bar.open { display:grid; }
    #wh-bar .section-label { grid-column:1 / -1; margin-bottom:.2rem; }
    @media (max-width:500px) { #wh-bar { grid-template-columns:1fr; } }
    #download-area { margin-bottom:.2rem; }
    .progress-wrap { height:4px; background:#211f1c; border-radius:2px; overflow:hidden; margin-top:.3rem; }
    #dl-bar { height:100%; width:0%; background:#c0392b; transition:width 200ms ease; }
    .progress-label { font-size:.7rem; color:#857e76; margin-top:.2rem; }
    #page-view { display:flex; align-items:flex-start; justify-content:center; background:#181614; border-radius:6px; overflow:hidden; min-height:200px; }
    #page-view img, #page-view canvas { max-width:100%; width:auto; height:auto; display:block; -webkit-user-select:none; user-select:none; pointer-events:none; }
    .page-spinner { text-align:center; font-size:.8rem; color:#857e76; padding:1rem; }
    .spinner { display:inline-block; width:14px; height:14px; border:2px solid #3a3530; border-top-color:#c0392b; border-radius:50%; animation:spin .7s linear infinite; }
    @keyframes spin { to { transform:rotate(360deg); } }
    #discord-status-area { display:flex; align-items:center; font-size:.72rem; }
    #nav-bar { position:fixed; bottom:38px; left:0; right:0; z-index:199; display:flex; align-items:center; justify-content:space-between; gap:.5rem; padding:.25rem 1rem; background:rgba(15,14,13,.95); border-top:1px solid #3a3530; color:#d4cfc8; }
    .nav-counter { font-size:.8rem; color:#857e76; flex:1; text-align:center; }
    #bottom-pad { height:80px; }
    .discord-btn { position:absolute; bottom:.5rem; right:.5rem; opacity:0; transition:opacity .2s; font-size:.7rem; padding:.25em .65em; background:rgba(15,14,13,.85); border:1px solid #3a3530; border-radius:6px; color:#857e76; cursor:pointer; display:none; }
    body.wh-active .discord-btn { display:inline-flex; }
    .img-block { position:relative; }
    .img-block:hover .discord-btn { opacity:1; }
    #seekbar-wrap { position:fixed; bottom:0; left:0; right:0; z-index:200; display:flex; align-items:center; gap:.75rem; padding:.4rem 1rem; background:rgba(15,14,13,.96); border-top:1px solid #3a3530; height:38px; box-sizing:border-box; }
    #seekbar-track { flex:1; height:6px; background:#211f1c; border-radius:3px; position:relative; cursor:pointer; }
    #seekbar-thumb { position:absolute; top:50%; left:0%; transform:translate(-50%,-50%); width:16px; height:16px; background:#c0392b; border-radius:50%; pointer-events:none; transition:left 100ms ease; }
    #seekbar-track::before { content:''; position:absolute; left:0; top:0; height:100%; width:var(--progress,0%); background:#7a1f17; border-radius:3px; }
    #seekbar-label { font-size:.7rem; color:#857e76; white-space:nowrap; min-width:4rem; text-align:right; }
    #seekbar-popup { position:absolute; bottom:calc(100% + 8px); width:88px; background:#181614; border:1px solid #3a3530; border-radius:6px; overflow:hidden; box-shadow:0 4px 12px rgba(0,0,0,.6); pointer-events:none; text-align:center; }
    #seekbar-popup img { width:100%; display:block; min-height:60px; background:#211f1c; }
    #seekbar-popup-label { font-size:.62rem; color:#857e76; padding:.15rem 0; }
    </style>
    <input type="hidden" id="manga-url"   value="#{esc(a.url)}">
    <input type="hidden" id="share-param" value="#{esc(a.share_param)}">
    <div class="reader-header">
      <a id="back-link" href="/?share=#{URI.encode_www_form(a.share_param)}" class="btn btn-sm">↩</a>
      <span class="reader-title">📖 #{esc(a.title)}</span>
      <button class="btn btn-sm btn-ghost" onclick="toggleWh()">⚙ WH</button>
    </div>
    <div id="lock-msg" style="display:#{lock_display};background:#fef2f2;border:1px solid #fecaca;color:#991b1b;border-radius:6px;padding:.7rem 1rem;margin:.6rem 0;font-size:.9rem">#{a.lock_html}</div>
    <div id="wh-bar">
      <div class="section-label">Discord Webhook</div>
      <input class="input" id="wh1" type="url" placeholder="Webhook 1"
             value="#{esc(a.webhook1)}" oninput="onWhInput()">
      <input class="input" id="wh2" type="url" placeholder="Webhook 2"
             value="#{esc(a.webhook2)}" oninput="onWhInput()">
    </div>
    <div id="download-area" hidden>
      <div class="progress-wrap"><div id="dl-bar"></div></div>
      <div class="progress-label" id="dl-label">接続中…</div>
    </div>
    <div id="page-view">
      <div class="page-spinner">
        <div class="spinner" style="margin:0 auto 0.75rem"></div>読み込み中…
      </div>
    </div>
    <div id="nav-bar">
      <button class="btn btn-sm" id="btn-prev" onclick="goPage(-1)" disabled>◀ 前</button>
      <span id="page-counter" class="nav-counter">— / —</span>
      <div id="discord-status-area"></div>
      <button class="btn btn-sm" id="btn-next" onclick="goPage(1)"  disabled>次 ▶</button>
    </div>
    <div id="bottom-pad"></div>
    <div id="seekbar-wrap">
      <div id="seekbar-track">
        <div id="seekbar-thumb"></div>
        <div id="seekbar-popup" hidden>
          <img id="seekbar-popup-img" src="" alt="">
          <div id="seekbar-popup-label"></div>
        </div>
      </div>
      <span id="seekbar-label">— / —</span>
    </div>
    <script>
    #{script(a)}
    </script>
    """

    body
  end

  defp script(a) do
    template()
    |> String.replace("__SCRAMBLED__", bool(a.scrambled))
    |> String.replace("__TILE_SIZE__", Integer.to_string(a.tile_size))
    |> String.replace("__WEBHOOK_ENABLED__", bool(a.webhook_enabled))
    |> String.replace("__READER_LOGGED_IN__", bool(a.reader_logged_in))
  end

  defp bool(true), do: "true"
  defp bool(_), do: "false"

  defp template do
    ~S"""
  'use strict';

  /* ── Canvas保護 ── */
  HTMLCanvasElement.prototype.toBlob    = function() {};
  HTMLCanvasElement.prototype.toDataURL = function() { return ''; };

  /* ================================================================
     Xorshift32 + デコード
     ================================================================ */
  class Xorshift32 {
    constructor(seed) {
      this.state = (seed >>> 0) || 1;
    }
    next() {
      let x = this.state;
      x ^= (x << 13) >>> 0;
      x ^= (x >>> 17);
      x ^= (x << 5)  >>> 0;
      return (this.state = x >>> 0);
    }
  }

  function xorshiftShuffle(n, seed) {
    /* 0..n-1 の配列を返す */
    const arr = Array.from({length: n}, (_, i) => i);
    const rng = new Xorshift32(seed);
    for (let i = n - 1; i > 0; i--) {
      const j = rng.next() % (i + 1);
      [arr[i], arr[j]] = [arr[j], arr[i]];
    }
    return arr;
  }

  /**
   * ファイル名がスクランブル命名規則か判定
   * stem = {4文字Base62}{16文字hex} → 計20文字
   */
  function isScrambled(filename) {
    const stem = filename.replace(/\.[^.]+$/, '');
    return stem.length === 20 && /^[0-9a-fA-F]{16}$/.test(stem.slice(4));
  }

  /**
   * スクランブル済み画像を Canvas に復号して返す
   */
  function decode(img, filename, tileSize) {
    const W = img.naturalWidth, H = img.naturalHeight;
    const cols = Math.floor(W / tileSize);
    const rows = Math.floor(H / tileSize);
    const n    = cols * rows;

    const seed     = parseInt(filename.replace(/\.[^.]+$/, '').slice(4, 12), 16);
    const shuffled = xorshiftShuffle(n, seed);

    const cv  = document.createElement('canvas');
    cv.width  = W;
    cv.height = H;
    const ctx = cv.getContext('2d');
    ctx.drawImage(img, 0, 0);           // まず全体コピー（端数処理）

    /* 逆写像: Python側で tile[i] → pos[shuffled[i]] に置いた
       JS側:   pos[shuffled[i]] から tile を取り出して pos[i] に戻す */
    for (let i = 0; i < n; i++) {
      const si = shuffled[i];
      ctx.drawImage(img,
        (si % cols) * tileSize, Math.floor(si / cols) * tileSize, tileSize, tileSize,
        ( i % cols) * tileSize, Math.floor( i / cols) * tileSize, tileSize, tileSize
      );
    }
    return cv;
  }

  /* ================================================================
     状態
     ================================================================ */
  const mangaUrl   = document.getElementById('manga-url').value;
  let total        = null;
  let currentN     = 0;
  let sessionToken = '';
  // サーバーから渡されたスクランブル設定
  const SCRAMBLED       = __SCRAMBLED__;
  let tileSize          = __TILE_SIZE__;
  // Webhook送信許可フラグ（外部ZIP=true、プラットフォーム作品=settings.jsonの値）
  const WEBHOOK_ENABLED = __WEBHOOK_ENABLED__;

  const buffer  = new Map();   // index → { el, filename }
  const loading = new Set();

  /* ================================================================
     セッション取得
     ================================================================ */
  const READER_LOGGED_IN = __READER_LOGGED_IN__;
  async function declareAge() {
    try {
      const path = READER_LOGGED_IN ? '/auth/declare-adult' : '/age/declare';
      const r = await fetch(path, { method: 'POST' });
      if (!r.ok) {
        const d = await r.json().catch(() => ({}));
        showLock(d.detail || '年齢確認に失敗しました');
        return;
      }
      location.reload();
    } catch(e) { showLock('年齢確認に失敗しました'); }
  }
  function showLock(msg) {
    const el = document.getElementById('lock-msg');
    el.textContent = '🔒 ' + msg;
    el.style.display = 'block';
  }
  async function initSession() {
    try {
      const r = await fetch(`/session?url=${encodeURIComponent(mangaUrl)}`);
      if (r.ok) { sessionToken = (await r.json()).session_token || ''; return true; }
      const d = await r.json().catch(() => ({}));
      showLock(d.detail || 'セッションの取得に失敗しました');
      return false;
    } catch(e) { console.warn('session:', e); return false; }
  }

  /* ================================================================
     Webhook
     ================================================================ */
  const wh1El = () => document.getElementById('wh1').value.trim();
  const wh2El = () => document.getElementById('wh2').value.trim();

  function toggleWh() {
    document.getElementById('wh-bar').classList.toggle('open');
    document.body.classList.toggle('wh-active');
  }

  function updateAllBackLinks() {
    const shareParam = document.getElementById('share-param').value;
    const wh1 = wh1El(), wh2 = wh2El();
    const params = new URLSearchParams();
    if (shareParam) params.set('share', shareParam);
    if (wh1) params.set('webhook1', wh1);
    if (wh2) params.set('webhook2', wh2);
    const qs   = params.toString();
    const dest = '/?' + qs;

    // ↩ボタン
    const backLink = document.getElementById('back-link');
    if (backLink) backLink.href = dest;

    // ヘッダーのマイリストリンク
    const mylistLink = document.getElementById('nav-mylist');
    if (mylistLink) mylistLink.href = dest;

    // ヘッダーの公開作品リンク（shareとwebhookを引き継ぎ、公開作品画面から戻れるようにする）
    const publicLink = document.getElementById('nav-public');
    if (publicLink) publicLink.href = '/public' + (qs ? '?' + qs : '');
  }

  function onWhInput() { updateAllBackLinks(); }

  /* ================================================================
     画像fetch → バッファに格納
     ================================================================ */
  function retryImg(img, n) {
    if (n >= 3) { img.dataset.failed = '1'; return; }
    setTimeout(() => {
      img.src = img.src.split('?')[0] + '?r=' + n;
      img.onerror = () => retryImg(img, n + 1);
    }, 500 * (2 ** n));
  }

  /* 1枚だけ取得（後方互換用ラッパー） */
  function fetchOne(index) {
    return fetchBatch(index, 1);
  }

  /* ================================================================
     バッチフェッチ：1リクエストで count 枚まとめて取得
     ================================================================ */
  async function fetchBatch(startIndex, count = 3) {
    if (startIndex < 0) return;
    if (total !== null && startIndex >= total) return;

    /* バッファ・ロード済みを除いた実際に取得が必要なインデックスを算出 */
    const needed = [];
    for (let i = startIndex; i < startIndex + count; i++) {
      if (i < 0) continue;
      if (total !== null && i >= total) break;
      if (!buffer.has(i) && !loading.has(i)) needed.push(i);
    }
    if (needed.length === 0) return;

    /* needed の先頭から連続する範囲を1リクエストで取得 */
    const first  = needed[0];
    const limit  = needed.length;
    needed.forEach(i => loading.add(i));

    try {
      const qs  = new URLSearchParams({
        url: mangaUrl, offset: first, limit,
        webhook1: wh1El(), webhook2: wh2El(),
        session_token: sessionToken,
      });
      const res  = await fetch('/images?' + qs);
      if (!res.ok) throw new Error('images ' + res.status);
      const html = await res.text();

      const doc  = new DOMParser().parseFromString(html, 'text/html');
      const meta = doc.getElementById('batch-meta');
      if (!meta) throw new Error('no batch-meta');
      if (meta.dataset.pending === 'true') { startDownload(); return; }

      total = parseInt(meta.dataset.total, 10);

      const blocks = doc.querySelectorAll('.img-block');

      /* 各ブロックを並列でロード・復号してバッファに積む */
      await Promise.all(Array.from(blocks).map(async (block, i) => {
        const index   = first + i;
        if (buffer.has(index)) return;   // 並列リクエストで先着済みの場合はスキップ

        const imgEl   = block.querySelector('img');
        if (!imgEl) return;
        const discBtn = block.querySelector('.discord-btn');
        const filename = discBtn ? discBtn.dataset.filename : '';

        /* ブラウザに画像をロードさせる（body に隠して追加） */
        imgEl.style.display = 'none';
        imgEl.onerror = () => retryImg(imgEl, 0);
        document.body.appendChild(imgEl);

        await new Promise(resolve => {
          if (imgEl.complete && imgEl.naturalWidth > 0) return resolve();
          imgEl.onload  = resolve;
          imgEl.onerror = resolve;
        });

        /* スクランブル判定 → Canvas に復号 or そのまま */
        let el;
        if (SCRAMBLED && filename && isScrambled(filename)) {
          try   { el = decode(imgEl, filename, tileSize); }
          catch(e) {
            console.warn("復号失敗:", e);
            el = imgEl;
          }
          if (imgEl.parentNode) imgEl.parentNode.removeChild(imgEl);
        } else {
          el = imgEl;
        }

        buffer.set(index, { el, filename });
        if (index === currentN) render(index);
      }));

    } catch(e) {
      console.error('fetchBatch', first, e);
      needed.forEach(index => {
        if (buffer.has(index)) return;
        const d = Object.assign(document.createElement('div'), {
          textContent: '🔴 読み込み失敗',
        });
        d.style.cssText = 'color:var(--text-dim);font-size:.8rem;text-align:center';
        buffer.set(index, { el: d, filename: '' });
        if (index === currentN) render(index);
      });
    } finally {
      needed.forEach(i => loading.delete(i));
    }
  }

  /* prefetch：現在地から3枚を1リクエストでまとめて取得 */
  function prefetch(n) {
    fetchBatch(n, 3);
  }

  /* ================================================================
     描画
     ================================================================ */
  let _gen = 0;

  function render(index) {
    if (index !== currentN) return;
    const gen   = ++_gen;
    const view  = document.getElementById('page-view');
    const entry = buffer.get(index);

    if (!entry) {
      view.innerHTML =
        '<div class="page-spinner"><div class="spinner" style="margin:0 auto .75rem"></div>読み込み中…</div>';
      fetchOne(index);
      return;
    }
    if (gen !== _gen) return;

    const { el, filename } = entry;

    const show = () => {
      if (gen !== _gen) return;
      if (el.parentNode) el.parentNode.removeChild(el);

      // 画像表示中はsite-headerを非表示
      document.querySelector('.site-header').style.display = 'none';

      // site-header の display:none 後、reflow完了を2フレーム待って
      // #page-view の実高さを取得してmax-heightにセットする
      requestAnimationFrame(() => requestAnimationFrame(() => {
        // seekbar-wrap（fixed, bottom:0）がpage-viewに重なるため
        // bottom-padの高さ分（80px）を差し引いた高さを上限にする
        const bottomPad = document.getElementById('bottom-pad').offsetHeight || 80;
        const viewH = view.getBoundingClientRect().height - bottomPad;
        el.style.cssText =
          `max-width:100%;max-height:${viewH}px;width:auto;height:auto;display:block;` +
          '-webkit-user-select:none;user-select:none;pointer-events:none;';
        view.innerHTML = '';
        view.appendChild(el);
      }));

      const sta = document.getElementById('discord-status-area');
      if (WEBHOOK_ENABLED && (wh1El() || wh2El()) && filename) {
        const safeFilename = filename.replace(/\\/g, '\\\\').replace(/'/g, "\\'");
        sta.innerHTML =
          `<button class="btn btn-sm" style="font-size:.7rem"
             onclick="sendDiscord('${safeFilename}')">
             Discord ↑ ${index+1}/${total}
           </button>`;
      } else {
        sta.innerHTML = '';
      }
      updateCounter();
      updateNavButtons();
    };

    if (el instanceof HTMLCanvasElement) {
      show();
    } else if (el instanceof HTMLImageElement) {
      if (el.complete && el.naturalWidth > 0 || el.dataset.failed) {
        show();
      } else {
        view.innerHTML =
          '<div class="page-spinner"><div class="spinner" style="margin:0 auto .75rem"></div>読み込み中…</div>';
        el.onload = show;
      }
    } else {
      view.innerHTML = '';
      view.appendChild(el);
    }
  }

  /* ================================================================
     ページ移動
     ================================================================ */
  function goPage(delta) {
    const next = currentN + delta;
    if (next < 0 || (total !== null && next >= total)) return;
    currentN = next;

    // 前5枚・後5枚を保持（それ以外を解放）
    for (const [idx, e] of buffer) {
      if (idx < next - 5 || idx > next + 5) {
        if (e.el && e.el.parentNode === document.body)
          e.el.parentNode.removeChild(e.el);
        buffer.delete(idx);
      }
    }

    prefetch(next);
    render(next);
  }

  /* ================================================================
     カウンター・ボタン
     ================================================================ */
  function updateCounter() {
    const t = total !== null ? `${currentN + 1} / ${total}` : '読み込み中…';
    document.getElementById('page-counter').textContent = t;
    updateSeekbar();
  }
  function updateNavButtons() {
    document.getElementById('btn-prev').disabled = currentN <= 0;
    document.getElementById('btn-next').disabled = total !== null && currentN >= total - 1;
  }

  /* ================================================================
     スクロール / タッチスワイプ
     ================================================================ */
  let _wLock = false;
  window.addEventListener('wheel', e => {
    if (_wLock || Math.abs(e.deltaY) < 30) return;
    _wLock = true;
    goPage(e.deltaY > 0 ? 1 : -1);
    setTimeout(() => _wLock = false, 500);
  }, { passive: true });

  let _ty = null;
  window.addEventListener('touchstart', e => { _ty = e.touches[0].clientY; },      { passive: true });
  window.addEventListener('touchend',   e => {
    if (_ty === null) return;
    const dy = _ty - e.changedTouches[0].clientY;
    _ty = null;
    if (Math.abs(dy) < 80) return;
    goPage(dy > 0 ? 1 : -1);
  }, { passive: true });

  /* ================================================================
     Discord送信
     ================================================================ */
  async function sendDiscord(filename) {
    const sta = document.getElementById('discord-status-area');
    sta.textContent = '送信中…';
    const fd = new FormData();
    fd.append('url',           mangaUrl);
    fd.append('filename',      filename);
    fd.append('webhook1',      wh1El());
    fd.append('webhook2',      wh2El());
    fd.append('session_token', sessionToken);
    const r = await fetch('/discord/send', { method: 'POST', body: fd });
    sta.innerHTML = await r.text();
  }

  /* ================================================================
     ダウンロード (SSE)
     ================================================================ */
  let _sseActive = false;
  function startDownload() {
    if (_sseActive) return;
    _sseActive = true;
    const area  = document.getElementById('download-area');
    const bar   = document.getElementById('dl-bar');
    const label = document.getElementById('dl-label');
    area.hidden = false;

    const es = new EventSource('/download/start?url=' + encodeURIComponent(mangaUrl) + '&session_token=' + encodeURIComponent(sessionToken));
    let ok   = false;
    es.onmessage = e => {
      if (e.data === 'done') {
        ok = true; bar.style.width = '100%';
        label.textContent = 'ダウンロード完了 — 展開中…';
        es.close();
        setTimeout(() => { area.hidden = true; init(); }, 400);
      } else if (e.data.startsWith('error:')) {
        ok = true; label.textContent = '❌ ' + e.data.slice(6);
        es.close(); _sseActive = false;
      } else {
        bar.style.width   = Math.round(parseFloat(e.data) * 100) + '%';
        label.textContent = `ダウンロード中… ${Math.round(parseFloat(e.data)*100)}%`;
      }
    };
    es.onerror = () => {
      es.close();
      if (!ok) label.textContent = '❌ 接続エラー';
      _sseActive = false;
    };
  }

  /* ================================================================
     シークバー
     ================================================================ */
  function updateSeekbar() {
    if (total === null || total <= 1) return;
    const pct = currentN / (total - 1) * 100;
    document.getElementById('seekbar-thumb').style.left = pct + '%';
    document.getElementById('seekbar-track').style.setProperty('--progress', pct + '%');
    document.getElementById('seekbar-label').textContent = `${currentN + 1} / ${total}`;
  }

  (function() {
    const track   = document.getElementById('seekbar-track');
    const label   = document.getElementById('seekbar-label');
    const popup   = document.getElementById('seekbar-popup');
    const pImg    = document.getElementById('seekbar-popup-img');
    const pLabel  = document.getElementById('seekbar-popup-label');
    let drag = false, prev = null, debT = null, abCtrl = null;

    function pct(clientX) {
      const r = track.getBoundingClientRect();
      return Math.max(0, Math.min(1, (clientX - r.left) / r.width));
    }
    function showPop(clientX, n) {
      const r    = track.getBoundingClientRect();
      const px   = pct(clientX) * r.width;
      popup.style.left   = Math.max(0, Math.min(r.width - 88, px - 44)) + 'px';
      popup.hidden       = false;
      pLabel.textContent = `${n + 1} / ${total}`;
    }
    function hidePop() {
      popup.hidden = true; pImg.src = '';
      if (abCtrl) { abCtrl.abort(); abCtrl = null; }
      clearTimeout(debT);
    }
    async function fetchThumb(n) {
      if (abCtrl) abCtrl.abort();
      abCtrl = new AbortController();
      try {
        const qs  = new URLSearchParams({ url: mangaUrl, index: n, session_token: sessionToken });
        const res = await fetch('/thumbnail?' + qs, { signal: abCtrl.signal });
        if (!res.ok || n !== prev) return;
        pImg.src = URL.createObjectURL(await res.blob());
      } catch(e) { if (e.name !== 'AbortError') console.warn(e); }
    }
    function onMove(cx) {
      if (total === null) return;
      prev = Math.round(pct(cx) * (total - 1));
      label.textContent = `${prev + 1} / ${total}`;
      showPop(cx, prev);
      clearTimeout(debT);
      debT = setTimeout(() => fetchThumb(prev), 60);
    }
    function onEnd(cx) {
      hidePop();
      const n = prev;
      if (n === null || n === currentN) { drag = false; updateSeekbar(); return; }

      // 全クリアではなくジャンプ先から遠いページだけ削除
      for (const [idx, e] of buffer) {
        if (idx < n - 5 || idx > n + 5) {
          if (e.el && e.el.parentNode === document.body) e.el.parentNode.removeChild(e.el);
          buffer.delete(idx);
        }
      }
      loading.clear();

      currentN = n;
      prefetch(n); render(n);
      drag = false; updateSeekbar();
    }

    track.addEventListener('mousedown', e => { drag = true; onMove(e.clientX); e.preventDefault(); });
    window.addEventListener('mousemove', e => { if (drag) onMove(e.clientX); });
    window.addEventListener('mouseup',   e => { if (drag) onEnd(e.clientX); });
    track.addEventListener('touchstart', e => { drag = true; onMove(e.touches[0].clientX); }, { passive: true });
    window.addEventListener('touchmove', e => { if (drag) onMove(e.touches[0].clientX); },    { passive: true });
    window.addEventListener('touchend',  e => { if (drag) onEnd(e.changedTouches[0].clientX); }, { passive: true });
  })();

  /* ================================================================
     起動
     ================================================================ */
  async function init() {
    currentN = 0;
    buffer.clear();
    loading.clear();
    total = null;
    // ローディング中はsite-headerを再表示
    document.querySelector('.site-header').style.display = '';
    document.getElementById('page-counter').textContent = '— / —';
    document.getElementById('btn-prev').disabled = true;
    document.getElementById('btn-next').disabled = true;
    // 0番を待ちつつ、1・2番はバッチで並列取得
    await fetchBatch(0, 1);          // 0番をまず表示
    fetchBatch(1, 2);                // 1・2番を1リクエストで並列取得
  }

  async function boot() {
    if (!await initSession()) return;
    updateAllBackLinks();  // 初期化時にリンクを設定
    await init();
  }

  boot();
  """
  end
end
