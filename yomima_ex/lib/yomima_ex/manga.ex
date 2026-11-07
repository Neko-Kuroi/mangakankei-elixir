defmodule YomimaEx.Manga do
  @moduledoc """
  URL 検証・宛先ポリシー、CBZ のダウンロード（進捗つき）、展開と画像一覧。
  Python 版 yomima/manga.py のなぞり。
  """

  @archive_exts ~w(.zip .cbz .rar .cbr)
  @image_exts ~w(.jpg .jpeg .png .webp .gif)
  @max_bytes 240 * 1024 * 1024

  # Python 版 _BLOCKED_NETWORKS と同じ明示リスト（ipaddress の is_private は
  # 使わない。ベンチマーク用 198.18/15 や CGNAT 100.64/10 は含めない）
  @blocked_v4 [
    {{127, 0, 0, 0}, 8},
    {{10, 0, 0, 0}, 8},
    {{172, 16, 0, 0}, 12},
    {{192, 168, 0, 0}, 16},
    {{169, 254, 0, 0}, 16},
    {{0, 0, 0, 0}, 8}
  ]

  def cache_dir do
    dir = System.get_env("MANGA_CACHE_DIR", "/tmp/manga_cache_ex")
    File.mkdir_p!(dir)
    dir
  end

  def url_hash(url), do: :crypto.hash(:md5, url) |> Base.encode16(case: :lower)

  def archive_path(url) do
    ext = url |> String.split("?") |> hd() |> Path.extname() |> String.downcase()
    Path.join(cache_dir(), url_hash(url) <> ext)
  end

  def extract_dir(url), do: Path.join(cache_dir(), url_hash(url) <> "_extracted")

  # --- URL 検証と宛先ポリシー ---
  def validate_manga_url(url) do
    ext = url |> String.split("?") |> hd() |> Path.extname() |> String.downcase()
    String.starts_with?(String.downcase(url), ["http://", "https://"]) and ext in @archive_exts
  end

  # Python 版 fetch_policy_check のなぞり。内部アドレスは原則禁止で、
  # 例外はプラットフォームのオリジンと MANGA_URL_ALLOW_HOSTS の2つだけ。
  # ホスト名は DNS 解決し、解決先のどれか1つでも内部アドレスなら拒否する。
  def fetch_allowed?(url) do
    uri = URI.parse(url)
    scheme = uri.scheme && String.downcase(uri.scheme)
    host = uri.host && String.downcase(uri.host)

    cond do
      invalid_port?(uri) -> {false, "無効なURLです"}
      scheme not in ["http", "https"] -> {false, "http/https のURLだけ取得できます"}
      host in [nil, ""] -> {false, "ホストがありません"}
      YomimaEx.Platform.platform_origin?(url) -> {true, ""}
      host in allow_hosts() -> {true, ""}
      true -> check_host(host)
    end
  end

  defp allow_hosts do
    System.get_env("MANGA_URL_ALLOW_HOSTS", "")
    |> String.split(",")
    |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
  end

  # URI.parse はポートの数値妥当性を検証しないので、Python 版
  # （urlsplit の .port が ValueError になる）と同じになるよう権限部分を見る。
  defp invalid_port?(uri) do
    cond do
      uri.port != nil and (uri.port < 0 or uri.port > 65_535) ->
        true

      is_binary(uri.authority) ->
        authority = uri.authority |> String.split("@") |> List.last()

        port_part =
          cond do
            String.starts_with?(authority, "[") ->
              case String.split(authority, "]:", parts: 2) do
                [_, p] -> p
                _ -> nil
              end

            String.contains?(authority, ":") ->
              authority |> String.split(":") |> List.last()

            true ->
              nil
          end

        port_part not in [nil, ""] and not String.match?(port_part, ~r/^\d+$/)

      true ->
        false
    end
  end

  defp check_host(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, ip} ->
        if dangerous_ip?(ip),
          do: {false, "内部アドレスへの取得は許可されていません"},
          else: {true, ""}

      _ ->
        addrs =
          Enum.flat_map([:inet, :inet6], fn family ->
            case :inet.gethostbyname(String.to_charlist(host), family) do
              {:ok, {:hostent, _, _, _, _, list}} -> list
              _ -> []
            end
          end)

        cond do
          addrs == [] -> {false, "ホストを解決できません"}
          Enum.any?(addrs, &dangerous_ip?/1) -> {false, "内部アドレスへの取得は許可されていません"}
          true -> {true, ""}
        end
    end
  end

  # Python 版 _is_dangerous_ip のなぞり（明示リスト＋マルチキャスト＋
  # 名称未指定アドレス。IPv4 マップド IPv6 は IPv4 として判定する）
  defp dangerous_ip?({a, b, c, d}) do
    addr = a * 16_777_216 + b * 65_536 + c * 256 + d

    a in 224..239 or
      Enum.any?(@blocked_v4, fn {{w, x, y, z}, prefix} ->
        net = w * 16_777_216 + x * 65_536 + y * 256 + z
        shift = 32 - prefix
        Bitwise.bsr(addr, shift) == Bitwise.bsr(net, shift)
      end)
  end

  defp dangerous_ip?({0, 0, 0, 0, 0, 0xFFFF, hi, lo}) do
    dangerous_ip?({div(hi, 256), rem(hi, 256), div(lo, 256), rem(lo, 256)})
  end

  defp dangerous_ip?({a, _, _, _, _, _, _, _} = ip) do
    ip == {0, 0, 0, 0, 0, 0, 0, 0} or ip == {0, 0, 0, 0, 0, 0, 0, 1} or
      a in 0xFC00..0xFDFF or a in 0xFE80..0xFEBF or a >= 0xFF00
  end

  # --- ダウンロード ---
  @doc """
  CBZ をキャッシュへ取得する。progress_fun には 0.0..1.0 を渡す。
  auth_token / age_verified はプラットフォーム宛てのときだけヘッダになる。
  """
  def download(url, dest, session, progress_fun) do
    if File.exists?(dest) do
      {:ok, :cached}
    else
      fetch_hop(url, dest, session, progress_fun, 0)
    end
  end

  defp fetch_hop(url, dest, session, progress_fun, hops) when hops <= 3 do
    case fetch_allowed?(url) do
      {false, reason} ->
        {:error, reason}

      {true, _} ->
        headers = build_headers(url, session)

        into = fn {:data, chunk}, {req, resp} ->
          st = Req.Response.get_private(resp, :dl) || open_dl(dest, resp)
          IO.binwrite(st.io, chunk)
          got = st.got + byte_size(chunk)

          cond do
            got > @max_bytes ->
              File.close(st.io)
              File.rm(st.tmp)
              resp = Req.Response.put_private(resp, :dl_error, :too_big)
              {:halt, {req, resp}}

            true ->
              if progress_fun && st.total > 0, do: progress_fun.(got / st.total)
              {:cont, {req, Req.Response.put_private(resp, :dl, %{st | got: got})}}
          end
        end

        result =
          Req.new()
          |> Req.get(
            url: url,
            headers: headers,
            redirect: false,
            receive_timeout: 60_000,
            into: into
          )

        handle_download_result(result, url, dest, session, progress_fun, hops)
    end
  end

  defp fetch_hop(_, _, _, _, _), do: {:error, "リダイレクトが多すぎます"}

  defp open_dl(dest, resp) do
    tmp = dest <> ".tmp"
    File.rm(tmp)
    {:ok, io} = File.open(tmp, [:write, :binary])

    total =
      case Req.Response.get_header(resp, "content-length") do
        [len] -> String.to_integer(len)
        _ -> 0
      end

    %{io: io, tmp: tmp, total: total, got: 0}
  end

  defp build_headers(url, session) do
    origin = YomimaEx.Platform.platform_origin?(url)

    []
    |> add_if(origin, YomimaEx.Platform.internal_headers())
    |> add_if(origin && session[:auth_token], [
      {"authorization", "Bearer #{session[:auth_token]}"}
    ])
    |> add_if(origin && session[:age_verified], [{"x-age-verified", "1"}])
  end

  defp add_if(headers, flag, extra) when is_list(extra) do
    if flag, do: headers ++ extra, else: headers
  end

  defp add_if(headers, _, _), do: headers

  defp handle_download_result({:ok, resp}, url, dest, session, progress_fun, hops) do
    st = Req.Response.get_private(resp, :dl)

    cond do
      Req.Response.get_private(resp, :dl_error) == :too_big ->
        {:error, "ファイルサイズ上限を超えました"}

      resp.status in [301, 302, 303, 307, 308] ->
        close_dl(st)

        case Req.Response.get_header(resp, "location") do
          [loc] -> fetch_hop(URI.merge(url, loc) |> to_string(), dest, session, progress_fun, hops + 1)
          _ -> {:error, "リダイレクト先がありません"}
        end

      resp.status == 200 and st != nil ->
        File.close(st.io)
        File.rename(st.tmp, dest)
        {:ok, :downloaded}

      resp.status == 200 ->
        {:error, "ダウンロードに失敗しました"}

      true ->
        close_dl(st)
        {:error, "HTTP #{resp.status}"}
    end
  end

  defp handle_download_result({:error, e}, _, dest, _, _, _) do
    File.rm(dest <> ".tmp")
    {:error, "ダウンロードに失敗しました: #{inspect(e) |> String.slice(0, 120)}"}
  end

  defp close_dl(nil), do: :ok

  defp close_dl(st) do
    File.close(st.io)
    File.rm(st.tmp)
  end

  # --- 展開と画像一覧 ---
  # Python 版 extract_archive のなぞり。結果（安全名リスト＋警告）は
  # Store にプロセス内キャッシュする（Python の _extract_cache と同じ）。
  @max_extract_entry_bytes 50 * 1024 * 1024
  @max_extract_total_bytes 480 * 1024 * 1024
  @max_extract_files 2500

  def image_files(url) do
    archive = archive_path(url)

    if not File.exists?(archive) do
      {:error, :not_downloaded}
    else
      case YomimaEx.Store.extract_cache(archive) do
        {files, warnings} ->
          {:ok, files, warnings}

        nil ->
          {files, warnings} = extract_archive(archive, extract_dir(url))
          YomimaEx.Store.put_extract_cache(archive, {files, warnings})
          {:ok, files, warnings}
      end
    end
  end

  require Record
  Record.defrecordp(:file_info, Record.extract(:file_info, from_lib: "kernel/include/file.hrl"))

  defp extract_archive(archive, dir) do
    File.mkdir_p!(dir)
    init = %{index: 0, total: 0, files: [], warnings: [], stop: false, capped: false}

    # :zip.foldl のコールバックは新しい acc をそのまま返す（{:ok, _} ではない）
    fun = fn name, get_info, get_binary, acc ->
      idx = acc.index
      acc = %{acc | index: idx + 1}
      extract_entry(to_string(name), get_info, get_binary, dir, acc, idx)
    end

    case :zip.foldl(fun, init, String.to_charlist(archive)) do
      {:ok, acc} -> {natural_sort(Enum.reverse(acc.files)), Enum.reverse(acc.warnings)}
      {:error, reason} -> {[], ["無効なアーカイブ: #{inspect(reason)}"]}
    end
  rescue
    e -> {[], ["解凍エラー: #{Exception.message(e)}"]}
  end

  defp extract_entry(_name, _get_info, _get_binary, _dir, %{stop: true} = acc, _idx),
    do: acc

  defp extract_entry(name, get_info, get_binary, dir, acc, idx) do
    cond do
      idx >= @max_extract_files ->
        if acc.capped do
          acc
        else
          %{
            acc
            | stop: true,
              capped: true,
              warnings: [
                "エントリ数が上限 (#{@max_extract_files}) に達したため打ち切りました"
                | acc.warnings
              ]
          }
        end

      String.ends_with?(name, "/") or String.ends_with?(name, "\\") ->
        acc

      true ->
        declared = file_info(get_info.(), :size)
        basename = basename_of(name)

        if declared > @max_extract_entry_bytes do
          mb = :erlang.float_to_binary(declared / 1024 / 1024, decimals: 1)

          %{
            acc
            | warnings: ["サイズ上限のためスキップ: #{basename} (#{mb}MB)" | acc.warnings]
          }
        else
          case fetch_binary(get_binary) do
            {:ok, bin} -> store_entry(name, basename, bin, dir, acc, idx)
            {:error, msg} -> %{acc | warnings: ["スキップ: #{basename} (#{msg})" | acc.warnings]}
          end
        end
    end
  end

  # :zip.foldl の GetBinary はバイナリそのものを返す（OTP 27 実測）。
  # {:ok, _} 形式にも両対応し、読み取り失敗は警告に倒す。
  defp fetch_binary(get_binary) do
    case get_binary.() do
      {:ok, bin} when is_binary(bin) -> {:ok, bin}
      bin when is_binary(bin) -> {:ok, bin}
      {:error, reason} -> {:error, inspect(reason)}
      other -> {:error, inspect(other)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    kind, value -> {:error, "#{kind}: #{inspect(value)}"}
  end

  defp store_entry(name, basename, bin, dir, acc, idx) do
    ext =
      if valid_image_name?(name) do
        Path.extname(basename) |> String.downcase()
      else
        guess_ext(bin)
      end

    if ext == "" do
      acc
    else
      safe = safe_filename(name, idx, ext)
      dest = Path.join(dir, safe)
      size = byte_size(bin)

      cond do
        File.exists?(dest) ->
          %{acc | files: [safe | acc.files]}

        acc.total + size > @max_extract_total_bytes ->
          %{
            acc
            | stop: true,
              warnings: [
                "展開合計が上限 (#{div(@max_extract_total_bytes, 1024 * 1024)}MB) に達したため打ち切りました"
                | acc.warnings
              ]
          }

        size > @max_extract_entry_bytes ->
          %{acc | warnings: ["サイズ上限のためスキップ: #{basename}" | acc.warnings]}

        true ->
          case File.write(dest, bin) do
            :ok -> %{acc | total: acc.total + size, files: [safe | acc.files]}
            {:error, reason} -> %{acc | warnings: ["スキップ: #{basename} (#{inspect(reason)})" | acc.warnings]}
          end
      end
    end
  end

  defp basename_of(name),
    do: name |> String.replace("\\", "/") |> String.split("/") |> List.last()

  defp valid_image_name?(name),
    do: String.ends_with?(String.downcase(basename_of(name)), @image_exts)

  # 先頭バイトからの拡張子推定（Python 版 guess_ext_from_bytes と同じ）
  defp guess_ext(<<0xFF, 0xD8, 0xFF, _::binary>>), do: ".jpg"
  defp guess_ext(<<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _::binary>>), do: ".png"
  defp guess_ext(<<"GIF87a", _::binary>>), do: ".gif"
  defp guess_ext(<<"GIF89a", _::binary>>), do: ".gif"
  defp guess_ext(<<"RIFF", _::binary-size(4), "WEBP", _::binary>>), do: ".webp"
  defp guess_ext(_), do: ""

  @unsafe_chars ["#", "?", "&", " ", "+", "%", "=", ":", ";", "@", "!", "*", "'", "(", ")"]

  @doc """
  展開先の安全なファイル名（Python 版 get_safe_filename と同じ）。
  スクランブル命名規則（stem=20文字: 4文字＋16文字hex）はそのまま保持し、
  通常ファイルは {index:05d}_{stem40文字まで}{ext} にする。
  """
  def safe_filename(original, index, ext) do
    basename = basename_of(original)
    stem = Path.rootname(basename)

    if String.length(stem) == 20 and hex?(String.slice(stem, 4, 16)) do
      stem <> ext
    else
      clean =
        @unsafe_chars
        |> Enum.reduce(stem, fn ch, s -> String.replace(s, ch, "_") end)
        |> String.slice(0, 40)

      "#{String.pad_leading(Integer.to_string(index), 5, "0")}_#{clean}#{ext}"
    end
  end

  defp hex?(s), do: s != "" and match?({_, ""}, Integer.parse(s, 16))

  defp natural_sort(names) do
    Enum.sort_by(names, fn name ->
      name
      |> then(&Regex.split(~r/(\d+)/, &1, include_captures: true))
      |> Enum.map(fn part ->
        case Integer.parse(part) do
          {n, ""} -> {0, n, ""}
          _ -> {1, 0, part}
        end
      end)
    end)
  end

  @doc """
  展開フォルダ直下のファイルのパス（Python 版 resolve_extracted_file
  のなぞり）。存在チェックはしない。空の名前や外に出る名前は nil。
  """
  def extracted_path(url, filename) do
    name = filename |> String.replace("\\", "/") |> Path.basename()
    base = Path.expand(extract_dir(url))
    path = Path.expand(Path.join(base, name))
    if name != "" and Path.dirname(path) == base, do: path, else: nil
  end

  def image_path(url, filename) do
    case extracted_path(url, filename) do
      nil -> nil
      path -> if File.regular?(path), do: path, else: nil
    end
  end

  def content_type(filename) do
    case Path.extname(filename) |> String.downcase() do
      ".png" -> "image/png"
      ".webp" -> "image/webp"
      ".gif" -> "image/gif"
      _ -> "image/jpeg"
    end
  end

  @doc """
  スクランブル命名規則（stem=20文字: 先頭4文字＋16文字hex）かどうか。
  Python 版 is_scrambled_filename と同じ。
  """
  def scrambled_filename?(name) do
    stem = name |> Path.basename() |> Path.rootname()
    String.length(stem) == 20 and hex?(String.slice(stem, 4, 16))
  end

  @doc """
  画像バイナリを返す（Python 版 load_image_bytes のなぞり）。

  スクランブル済み画像（または force_no_resize=true）はリサイズしない
  （アップロード時にすでに適切なサイズになっているため）。
  非スクランブルは max_size に収まるよう縮小する（拡大はしない）。
  アルファチャンネルがあれば PNG、なければ JPEG (quality 90) で返し、
  結果はキャッシュディレクトリの thumbs/ に保存する。失敗したら nil。
  """
  def load_image_bytes(path, max_size \\ {1200, 1800}, force_no_resize \\ false) do
    if not File.exists?(path) do
      nil
    else
      scrambled = force_no_resize or scrambled_filename?(path)
      {cache_jpg, cache_png} = thumb_cache_paths(path, max_size, scrambled)

      cond do
        File.exists?(cache_jpg) -> read_cached(cache_jpg)
        File.exists?(cache_png) -> read_cached(cache_png)
        true -> generate_image_bytes(path, max_size, scrambled, cache_jpg, cache_png)
      end
    end
  rescue
    _ -> nil
  end

  defp read_cached(path) do
    case File.read(path) do
      {:ok, data} -> data
      _ -> nil
    end
  end

  defp thumb_cache_paths(path, {w, h}, scrambled) do
    dir = Path.join(cache_dir(), "thumbs")
    File.mkdir_p!(dir)
    stat = File.stat!(path)

    key =
      :crypto.hash(
        :md5,
        "#{path}:#{inspect(stat.mtime)}:#{stat.size}:(#{w}, #{h}):#{scrambled}"
      )
      |> Base.encode16(case: :lower)

    {Path.join(dir, key <> ".jpg"), Path.join(dir, key <> ".png")}
  end

  defp generate_image_bytes(path, {w, h}, scrambled, cache_jpg, cache_png) do
    with {:ok, img} <- Image.open(path),
         {:ok, img} <- resize_for_thumb(img, scrambled, w, h) do
      {suffix, options, cache} =
        if Image.has_alpha?(img) do
          {".png", [], cache_png}
        else
          {".jpg", [quality: 90], cache_jpg}
        end

      with {:ok, data} <- Image.write(img, :memory, [{:suffix, suffix} | options]),
           :ok <- File.write(cache, data) do
        data
      else
        _ -> nil
      end
    else
      _ -> nil
    end
  end

  defp resize_for_thumb(img, true, _w, _h), do: {:ok, img}

  # PIL の thumbnail と同じく縮小のみ（:image の既定は拡大もする）
  defp resize_for_thumb(img, false, w, h),
    do: Image.thumbnail(img, "#{w}x#{h}", resize: :down)

  # --- マンガリスト（共有パラメータ）と作品登録 ---

  @max_manga_count 12

  def max_manga_count, do: @max_manga_count

  @doc "Python 版 get_filename_from_url のなぞり"
  def filename_from_url(url) do
    filename = url |> Path.basename() |> String.split("?") |> hd()
    URI.decode(filename)
  end

  @doc "Python 版 build_manga_entry のなぞり"
  def build_manga_entry(url, title \\ "") do
    %{
      "url" => url,
      "title" => if(title in [nil, ""], do: filename_from_url(url), else: title),
      "added_time" => System.os_time(:microsecond) / 1_000_000
    }
  end

  @doc "Python 版 encode_manga_list のなぞり（JSON を base64url 化）"
  def encode_manga_list(manga_list) do
    payload = %{
      "manga_urls" => manga_list,
      "export_time" => System.os_time(:microsecond) / 1_000_000
    }

    payload
    |> Jason.encode!(escape: :unicode_safe)
    |> Base.url_encode64()
  end

  @doc """
  Python 版 decode_manga_list のなぞり。
  {リスト, ""} か、失敗したら {[], "デコードエラー: ..."} を返す
  （理由の文面は Python 版の例外文字列とは一致しない）。
  """
  def decode_manga_list(encoded) do
    normalized = encoded |> to_string() |> String.trim() |> String.replace(" ", "+")

    with {:ok, raw} <- decode_base64(normalized),
         {:ok, data} when is_map(data) <- Jason.decode(raw) do
      entries =
        case data["manga_urls"] do
          list when is_list(list) -> Enum.filter(list, &is_map/1)
          _ -> []
        end

      {entries, ""}
    else
      _ -> {[], "デコードエラー: 共有パラメータを読み取れませんでした"}
    end
  end

  defp decode_base64(s) do
    case Base.url_decode64(s, padding: false) do
      {:ok, raw} -> {:ok, raw}
      :error -> Base.decode64(s, padding: false)
    end
  end

  # --- Discord Webhook ---

  @discord_webhook_hosts ~w(discord.com ptb.discord.com canary.discord.com discordapp.com)

  @doc "Python 版 is_discord_webhook_url のなぞり"
  def discord_webhook_url?(url) do
    uri = URI.parse(url)
    host = uri.host && String.downcase(uri.host)

    uri.scheme == "https" and host in @discord_webhook_hosts and
      uri.port in [nil, 443] and is_nil(uri.userinfo) and
      String.starts_with?(uri.path || "", "/api/webhooks/") and
      not invalid_port?(uri)
  end

  @doc """
  Python 版 send_image_to_discord のなぞり。
  送信できなかった理由のリストを返す（空なら全て送信できた）。
  送信ファイル名は元の stem の先頭5文字＋拡張子になる。
  """
  def send_image_to_discord(image_path, webhook_urls, filename \\ nil) do
    if not File.exists?(image_path) do
      ["ファイルが見つかりません"]
    else
      filename = filename || Path.basename(image_path)
      ext = image_path |> Path.extname() |> String.downcase()

      mime =
        case ext do
          ".png" -> "image/png"
          ".jpg" -> "image/jpeg"
          ".jpeg" -> "image/jpeg"
          ".webp" -> "image/webp"
          _ -> "image/png"
        end

      send_name = String.slice(Path.rootname(Path.basename(filename)), 0, 5) <> ext
      data = File.read!(image_path)

      Enum.flat_map(webhook_urls, fn webhook_url ->
        cond do
          webhook_url == "" ->
            []

          not discord_webhook_url?(webhook_url) ->
            ["Webhook URL は Discord のものだけ使えます"]

          true ->
            case post_to_discord(webhook_url, send_name, mime, data) do
              :ok ->
                []

              {:error, detail} ->
                ["Discord送信エラー (#{String.slice(webhook_url, 0, 40)}...): #{detail}"]
            end
        end
      end)
    end
  end

  defp post_to_discord(webhook_url, send_name, mime, data) do
    boundary =
      "----yomimaEx" <> (:crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower))

    body =
      "--#{boundary}\r\n" <>
        "Content-Disposition: form-data; name=\"file\"; filename=\"#{send_name}\"\r\n" <>
        "Content-Type: #{mime}\r\n\r\n" <> data <> "\r\n--#{boundary}--\r\n"

    case Req.post(webhook_url,
           body: body,
           headers: [{"content-type", "multipart/form-data; boundary=#{boundary}"}],
           receive_timeout: 30_000,
           redirect: false
         ) do
      {:ok, %{status: status}} when status < 400 -> :ok
      {:ok, %{status: status}} -> {:error, "HTTP #{status}"}
      {:error, e} -> {:error, Exception.message(e)}
    end
  end

  # --- TinyURL ---

  @doc "Python 版 shorten_url のなぞり（失敗したら元の URL を返す）"
  def shorten_url(long_url) do
    case Req.get("https://tinyurl.com/api-create.php",
           params: [url: long_url],
           receive_timeout: 10_000
         ) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        String.trim(body)

      _ ->
        long_url
    end
  end
end
