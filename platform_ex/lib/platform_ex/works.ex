defmodule PlatformEx.Works do
  @moduledoc """
  作品の部屋：作者の一覧・設定・削除と、アップロードの受け付けと加工。
  配置・文言・進捗の形は Python 版 main.py の作者まわりと揃える。
  """
  alias PlatformEx.{Access, Jobs, Media, SettingsLock, Storage}
  alias PlatformEx.Accounts.User

  @max_page_bytes 10 * 1024 * 1024
  @max_total_bytes 100 * 1024 * 1024
  @max_cover_bytes 5 * 1024 * 1024
  @image_suffixes [".jpg", ".jpeg", ".png", ".webp"]

  defmodule ProcessError do
    defexception [:message]
  end

  # ---------------------------------------------------------------------------
  # 一覧
  # ---------------------------------------------------------------------------

  @doc "自分の作品一覧（settings.json の中身＋状態フラグ。壊れたファイルは飛ばす）"
  def list_works(%User{id: user_id}) do
    user_dir = Path.join(Storage.zips_dir(), "user_#{user_id}")

    if File.dir?(user_dir) do
      paths =
        user_dir
        |> Path.join("title_*/episode_*_settings.json")
        |> Path.wildcard()
        |> Enum.sort()

      {works, _cache} =
        Enum.map_reduce(paths, %{}, fn path, cache ->
          case read_work(user_id, path, cache) do
            {:ok, work, cache} -> {work, cache}
            {:skip, cache} -> {nil, cache}
          end
        end)

      Enum.reject(works, &is_nil/1)
    else
      []
    end
  end

  defp read_work(user_id, settings_path, cache) do
    with {:ok, body} <- File.read(settings_path),
         {:ok, meta} when is_map(meta) <- Jason.decode(body),
         episode_id when is_integer(episode_id) <- meta["episode_id"] do
      dir = Path.dirname(settings_path)
      title_id = meta["title_id"]

      {susp, cache} =
        case Map.fetch(cache, title_id) do
          {:ok, susp} ->
            {susp, cache}

          :error ->
            susp = Access.active_suspension(user_id, title_id)
            {susp, Map.put(cache, title_id, susp)}
        end

      work =
        meta
        |> Map.put("has_cbz", File.exists?(Path.join(dir, "episode_#{episode_id}.cbz")))
        |> Map.put(
          "has_cover",
          File.exists?(Path.join(dir, "episode_#{episode_id}_cover.jpg"))
        )
        |> Map.put("suspended", susp != nil)
        |> Map.put("suspend_reason", susp && susp.reason)

      {:ok, work, cache}
    else
      _ -> {:skip, cache}
    end
  end

  # ---------------------------------------------------------------------------
  # 設定
  # ---------------------------------------------------------------------------

  @doc """
  エピソード設定を保存する。settings は検証済みの文字列キー map。
  公開には CBZ が要る（無ければ 400）。
  """
  def update_settings(%User{} = user, title_id, episode_id, settings) do
    title_dir = Storage.title_dir(user.id, title_id)
    cbz_path = Storage.cbz_path(user.id, title_id, episode_id)
    settings_path = Storage.settings_path(user.id, title_id, episode_id)

    if settings["status"] == "published" and not File.exists?(cbz_path) do
      {:error, 400, "先に原稿をアップロードしてください"}
    else
      File.mkdir_p!(title_dir)

      SettingsLock.with_lock(fn ->
        existing =
          case File.read(settings_path) do
            {:ok, body} ->
              case Jason.decode(body) do
                {:ok, meta} when is_map(meta) -> meta
                _ -> %{}
              end

            _ ->
              %{}
          end

        now = System.os_time(:microsecond) / 1_000_000

        merged =
          existing
          |> Map.merge(settings)
          |> Map.merge(%{
            "author_name" => user.username,
            "author_id" => user.id,
            "title_id" => title_id,
            "episode_id" => episode_id,
            "updated_at" => now
          })
          |> Map.put_new("created_at", now)

        save_settings(settings_path, merged)
      end)

      :ok
    end
  end

  # settings.json を一時ファイル経由で原子的に書き換える（Python 版 _save_settings と同じ）
  defp save_settings(settings_path, meta) do
    tmp_path = settings_path <> ".tmp"
    File.write!(tmp_path, Jason.encode!(meta, pretty: true))
    File.rename!(tmp_path, settings_path)
  end

  # ---------------------------------------------------------------------------
  # 削除
  # ---------------------------------------------------------------------------

  def delete_episode(%User{} = user, title_id, episode_id) do
    targets = [
      {Storage.cbz_path(user.id, title_id, episode_id), "episode_#{episode_id}.cbz"},
      {Storage.settings_path(user.id, title_id, episode_id),
       "episode_#{episode_id}_settings.json"},
      {Storage.cover_path(user.id, title_id, episode_id), "episode_#{episode_id}_cover.jpg"}
    ]

    deleted =
      Enum.flat_map(targets, fn {path, name} ->
        if File.exists?(path) do
          File.rm!(path)
          [name]
        else
          []
        end
      end)

    thumbs = Storage.thumbs_dir(user.id, title_id, episode_id)

    deleted =
      if File.dir?(thumbs) do
        File.rm_rf!(thumbs)
        deleted ++ ["thumbs/"]
      else
        deleted
      end

    if deleted == [] do
      {:error, 404, "削除対象のファイルが見つかりません"}
    else
      title_dir = Storage.title_dir(user.id, title_id)

      if File.dir?(title_dir) and File.ls!(title_dir) == [] do
        File.rmdir!(title_dir)
      end

      {:ok, deleted}
    end
  end

  # ---------------------------------------------------------------------------
  # アップロード：受け付け（検証しながらスプールへ写す）
  # ---------------------------------------------------------------------------

  @doc """
  アップロードを受け付ける。files/cover は %Plug.Upload{}（cover は nil 可）。
  サイズ検証に失敗したら {:error, 400, 文言}。成功したら背景ジョブを起動して
  {:ok, job_id, total_files} を返す。
  """
  def start_upload(%User{} = user, title_id, episode_id, files, cover, do_scramble, tile_size) do
    job_id = Jobs.new_job_id()
    Jobs.update(job_id, "queued", 0, length(files))

    spool_dir = Path.join(Storage.tmp_dir(), "spool_#{job_id}")
    File.mkdir_p!(spool_dir)

    case spool_files(files, cover, spool_dir) do
      {:ok, file_paths, cover_spool} ->
        {:ok, _pid} =
          Task.Supervisor.start_child(PlatformEx.JobSupervisor, fn ->
            process_upload(
              job_id,
              title_id,
              episode_id,
              file_paths,
              cover_spool,
              do_scramble,
              tile_size,
              user.id,
              spool_dir
            )
          end)

        {:ok, job_id, length(files)}

      {:error, status, message} ->
        File.rm_rf!(spool_dir)
        Jobs.pop(job_id)
        {:error, status, message}
    end
  end

  defp spool_files(files, cover, spool_dir) do
    result =
      files
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, [], 0}, fn {upload, i}, {:ok, acc, total} ->
        size = File.stat!(upload.path).size

        cond do
          size > @max_page_bytes ->
            {:halt, {:error, 400, "#{upload.filename} が 10MB を超えています"}}

          total + size > @max_total_bytes ->
            {:halt, {:error, 400, "合計サイズが 100MB を超えています"}}

          true ->
            dest = Path.join(spool_dir, "upload_#{Storage.pad4(i)}")
            copy_file!(upload.path, dest)
            {:cont, {:ok, [{upload.filename, dest} | acc], total + size}}
        end
      end)

    case result do
      {:ok, file_paths, _total} ->
        case spool_cover(cover, spool_dir) do
          {:ok, cover_spool} -> {:ok, Enum.reverse(file_paths), cover_spool}
          error -> error
        end

      error ->
        error
    end
  end

  defp spool_cover(nil, _spool_dir), do: {:ok, nil}

  defp spool_cover(cover, spool_dir) do
    size = File.stat!(cover.path).size

    if size > @max_cover_bytes do
      {:error, 400, "バンプ画像が 5MB を超えています"}
    else
      dest = Path.join(spool_dir, "cover_upload")
      copy_file!(cover.path, dest)
      {:ok, {dest, cover.filename}}
    end
  end

  # File.cp! はこの VM の overlayfs で "not owner" になることがあるため、
  # 読み書きで写す（手順0スパイクの File.cp! EPERM と同系統）
  defp copy_file!(src, dest) do
    src
    |> File.stream!([], 1_048_576)
    |> Stream.into(File.stream!(dest))
    |> Stream.run()

    :ok
  end

  # ---------------------------------------------------------------------------
  # アップロード：加工（背景）
  # ---------------------------------------------------------------------------

  def process_upload(
        job_id,
        title_id,
        episode_id,
        file_paths,
        cover_spool,
        do_scramble,
        tile_size,
        user_id,
        spool_dir
      ) do
    title_dir = Storage.title_dir(user_id, title_id)
    File.mkdir_p!(title_dir)

    rand = :crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower)

    work_dir =
      Path.join(Storage.tmp_dir(), "u#{user_id}_t#{title_id}_e#{episode_id}_#{rand}")

    File.mkdir_p!(work_dir)
    work_thumbs = Path.join(work_dir, "thumbs")
    File.mkdir_p!(work_thumbs)

    Jobs.Permits.acquire()

    try do
      sorted = Enum.sort_by(file_paths, fn {filename, _} -> natural_key(filename) end)
      total = length(sorted)

      saved_pages =
        sorted
        |> Enum.with_index()
        |> Enum.reduce([], fn {{filename, spool_path}, index}, acc ->
          if image_file?(filename) do
            [
              process_page(
                job_id,
                index,
                total,
                spool_path,
                work_dir,
                work_thumbs,
                do_scramble,
                tile_size
              )
              | acc
            ]
          else
            acc
          end
        end)
        |> Enum.reverse()

      if saved_pages == [] do
        raise ProcessError, message: "有効な画像ファイルがありませんでした"
      end

      Jobs.update(job_id, "zip", 0, length(saved_pages))

      entries =
        saved_pages
        |> Enum.with_index(1)
        |> Enum.map(fn {page_path, i} ->
          Jobs.update(job_id, "zip", i, length(saved_pages))
          {Path.basename(page_path), page_path}
        end)

      tmp_zip = Path.join(work_dir, "episode_#{episode_id}.cbz")
      Media.write_cbz(tmp_zip, entries)

      tmp_cover = Path.join(work_dir, "cover.jpg")

      if cover_spool do
        {cover_path, _filename} = cover_spool

        cover_path
        |> Media.open_rgb()
        |> Media.resize_for_cover()
        |> Media.save_jpeg(tmp_cover, 85)
      end

      # 成果物の差し替え（ここまでは既存の公開物に触れていない）
      File.rename!(tmp_zip, Storage.cbz_path(user_id, title_id, episode_id))

      thumbs_dir = Storage.thumbs_dir(user_id, title_id, episode_id)
      File.rm_rf!(thumbs_dir)
      File.rename!(work_thumbs, thumbs_dir)

      if File.exists?(tmp_cover) do
        File.rename!(tmp_cover, Storage.cover_path(user_id, title_id, episode_id))
      end

      Jobs.update(job_id, "done", length(saved_pages), length(saved_pages), %{
        "page_count" => length(saved_pages),
        "scrambled" => do_scramble,
        "tile_size" => tile_size
      })
    rescue
      e ->
        Jobs.update(job_id, "error", 0, 0, %{"message" => Exception.message(e)})
    after
      Jobs.Permits.release()
      File.rm_rf!(work_dir)
      File.rm_rf!(spool_dir)
    end
  end

  defp process_page(
         job_id,
         index,
         total,
         spool_path,
         work_dir,
         work_thumbs,
         do_scramble,
         tile_size
       ) do
    Jobs.update(job_id, "resize", index + 1, total)

    resized = spool_path |> Media.open_rgb() |> Media.resize_for_display()
    resized_path = Path.join(work_dir, "resized_#{Storage.pad4(index)}.png")
    Media.save_png(resized, resized_path)

    resized
    |> Media.resize_for_thumb()
    |> Media.save_jpeg(Path.join(work_thumbs, "thumb_#{Storage.pad4(index)}.jpg"), 80)

    Jobs.update(job_id, "scramble", index + 1, total)

    page_filename = Media.page_filename(index)

    page =
      if do_scramble do
        Media.scramble(resized, Media.seed_from_filename(page_filename), tile_size)
      else
        resized
      end

    page_path = Path.join(work_dir, page_filename)
    Media.save_png(page, page_path)

    File.rm(spool_path)
    File.rm(resized_path)
    page_path
  end

  defp image_file?(filename) do
    suffix = filename |> Path.extname() |> String.downcase()
    suffix in @image_suffixes
  end

  # ---------------------------------------------------------------------------
  # 公開まわり（カタログ・管理者一覧・閲覧数）
  # ---------------------------------------------------------------------------

  @doc "settings.json を読む。ファイルが無ければ :missing（壊れていれば例外＝Python 版の 500 相当）"
  def read_settings(user_id, title_id, episode_id) do
    path = Storage.settings_path(user_id, title_id, episode_id)

    if File.exists?(path) do
      {:ok, path |> File.read!() |> Jason.decode!()}
    else
      :missing
    end
  end

  @doc "作品（タイトル）にエピソード設定が1つでもあるか"
  def title_has_settings?(user_id, title_id) do
    dir = Storage.title_dir(user_id, title_id)
    File.dir?(dir) and Path.wildcard(Path.join(dir, "episode_*_settings.json")) != []
  end

  @doc "公開カタログ（公開中のみ・停止中は除外・note は落とす。並びは走査順）"
  def public_catalog(base_url) do
    Storage.zips_dir()
    |> Path.join("user_*/title_*/episode_*_settings.json")
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      case catalog_entry(path, base_url) do
        {:ok, entry} -> [entry]
        :skip -> []
      end
    end)
  end

  defp catalog_entry(settings_path, base_url) do
    with {:ok, body} <- File.read(settings_path),
         {:ok, meta} when is_map(meta) <- Jason.decode(body),
         true <- meta["status"] == "published",
         uid when is_integer(uid) <- meta["author_id"],
         tid when is_integer(tid) <- meta["title_id"],
         eid when is_integer(eid) <- meta["episode_id"],
         nil <- Access.active_suspension(uid, tid) do
      cover_path =
        Path.join(Path.dirname(settings_path), "episode_#{eid}_cover.jpg")

      age_restricted = meta["age_restricted"] != nil and meta["age_restricted"] != false

      entry =
        meta
        |> Map.put("cbz_url", "#{base_url}/api/public/cbz/#{uid}/#{tid}/#{eid}.cbz")
        |> Map.put(
          "cover_url",
          if(File.exists?(cover_path) and not age_restricted,
            do: "#{base_url}/api/public/cover/#{uid}/#{tid}/#{eid}",
            else: nil
          )
        )
        |> Map.delete("note")

      {:ok, entry}
    else
      _ -> :skip
    end
  end

  @doc "管理者用の全作品一覧（note は落とす。壊れたファイルは飛ばす）"
  def admin_works do
    paths =
      Storage.zips_dir()
      |> Path.join("user_*/title_*/episode_*_settings.json")
      |> Path.wildcard()
      |> Enum.sort()

    Enum.flat_map(paths, fn path ->
      with {:ok, body} <- File.read(path),
           {:ok, meta} when is_map(meta) <- Jason.decode(body),
           uid when is_integer(uid) <- meta["author_id"],
           tid when is_integer(tid) <- meta["title_id"] do
        susp = Access.active_suspension(uid, tid)

        [
          meta
          |> Map.put("suspended", susp != nil)
          |> Map.put("suspend_reason", susp && susp.reason)
          |> Map.delete("note")
        ]
      else
        _ -> []
      end
    end)
  end

  @doc "閲覧数を1増やす（同じ IP は1時間に1回まで。Python 版 increment_view_count と同じ）"
  def increment_view_count(settings_path, client_ip) do
    key = "#{settings_path}:#{client_ip}"

    if PlatformEx.ViewCounts.ready?(key) do
      counted =
        SettingsLock.with_lock(fn ->
          case File.read(settings_path) do
            {:ok, body} ->
              case Jason.decode(body) do
                {:ok, meta} when is_map(meta) ->
                  meta = Map.put(meta, "view_count", (meta["view_count"] || 0) + 1)
                  save_settings(settings_path, meta)
                  true

                _ ->
                  false
              end

            _ ->
              false
          end
        end)

      if counted, do: PlatformEx.ViewCounts.mark(key)
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # ファイル名の自然順（Python 版 natural_keys と同じ：数字の並びは数として、
  # 文字は小文字化して比べる）
  # ---------------------------------------------------------------------------

  def natural_key(name) do
    ~r/(\d+)/
    |> Regex.split(name, include_captures: true)
    |> Enum.map(fn chunk ->
      if chunk =~ ~r/^\d+$/ do
        {:n, String.to_integer(chunk)}
      else
        {:s, String.downcase(chunk)}
      end
    end)
  end
end
