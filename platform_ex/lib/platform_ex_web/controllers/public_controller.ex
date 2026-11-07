defmodule PlatformExWeb.PublicController do
  @moduledoc """
  公開まわりの API（カタログ・CBZ・サムネイル・表紙・設定情報）。
  URL・状態コード・文言・執行の順序は Python 版の /api/public/* と揃える。
  """
  use PlatformExWeb, :controller

  alias PlatformEx.{Access, Accounts, Storage, Works}
  alias PlatformExWeb.{RateLimit, RateLimitKey}

  # ---------------------------------------------------------------------------
  # GET /api/config
  # ---------------------------------------------------------------------------

  def config(conn, _params) do
    json(conn, %{platform_base_url: base_url(conn)})
  end

  # ---------------------------------------------------------------------------
  # GET /api/public/catalog（5/分、内部は免除）
  # ---------------------------------------------------------------------------

  def catalog(conn, _params) do
    case RateLimit.check_unless_internal(conn, "catalog", 60_000, 5) do
      :ok -> json(conn, Works.public_catalog(base_url(conn)))
      {:error, conn} -> conn
    end
  end

  # ---------------------------------------------------------------------------
  # GET /api/public/cbz/:user_id/:title_id/:episode_id.cbz（10/分、内部は免除）
  # ---------------------------------------------------------------------------

  def cbz(conn, %{"user_id" => uid_s, "title_id" => tid_s, "episode_id_cbz" => eid_cbz}) do
    eid_s = String.replace_suffix(eid_cbz, ".cbz", "")

    if eid_s == eid_cbz do
      conn |> put_status(404) |> json(%{detail: "Not Found"})
    else
      serve_cbz(conn, uid_s, tid_s, eid_s)
    end
  end

  defp serve_cbz(conn, uid_s, tid_s, eid_s) do
    with {:ok, user_id} <- path_int(conn, "user_id", uid_s),
         {:ok, title_id} <- path_int(conn, "title_id", tid_s),
         {:ok, episode_id} <- path_int(conn, "episode_id", eid_s),
         :ok <- rate(conn, "cbz", 10),
         {:ok, meta} <- settings_or_404(conn, user_id, title_id, episode_id),
         :ok <- published(conn, meta, "この作品は非公開です"),
         :ok <- enforce(conn, Access.enforce_not_suspended(user_id, title_id)),
         {:ok, reader} <- optional_reader(conn),
         :ok <-
           enforce(conn, Access.enforce_premium(meta, user_id, title_id, reader)),
         :ok <- enforce(conn, Access.enforce_age(meta, user_id, reader, age_verified?(conn))) do
      cbz_path = Storage.cbz_path(user_id, title_id, episode_id)

      if File.exists?(cbz_path) do
        settings_path = Storage.settings_path(user_id, title_id, episode_id)
        Works.increment_view_count(settings_path, RateLimitKey.client_ip(conn))

        conn
        |> put_resp_header("content-type", "application/zip")
        |> put_resp_header(
          "content-disposition",
          ~s(attachment; filename="title#{title_id}_ep#{episode_id}.cbz")
        )
        |> put_resp_header("cache-control", "public, max-age=3600")
        |> send_file(200, cbz_path)
      else
        conn |> put_status(404) |> json(%{detail: "CBZファイルが見つかりません"})
      end
    else
      {:error, conn} -> conn
    end
  end

  # ---------------------------------------------------------------------------
  # GET /api/public/thumb/:user_id/:title_id/:episode_id/:index
  # ---------------------------------------------------------------------------

  def thumb(conn, %{
        "user_id" => uid_s,
        "title_id" => tid_s,
        "episode_id" => eid_s,
        "index" => idx_s
      }) do
    with {:ok, user_id} <- path_int(conn, "user_id", uid_s),
         {:ok, title_id} <- path_int(conn, "title_id", tid_s),
         {:ok, episode_id} <- path_int(conn, "episode_id", eid_s),
         {:ok, index} <- path_int(conn, "index", idx_s),
         {:ok, meta} <- settings_or_404(conn, user_id, title_id, episode_id),
         :ok <- published(conn, meta, "非公開です"),
         :ok <- enforce(conn, Access.enforce_not_suspended(user_id, title_id)),
         {:ok, reader} <- optional_reader(conn),
         :ok <-
           enforce(conn, Access.enforce_premium(meta, user_id, title_id, reader)),
         :ok <- enforce(conn, Access.enforce_age(meta, user_id, reader, age_verified?(conn))) do
      thumb_path = Storage.thumb_path(user_id, title_id, episode_id, index)

      if File.exists?(thumb_path) do
        conn
        |> put_resp_header("content-type", "image/jpeg")
        |> put_resp_header("cache-control", "max-age=86400")
        |> send_file(200, thumb_path)
      else
        conn |> put_status(404) |> json(%{detail: "サムネイルが見つかりません"})
      end
    else
      {:error, conn} -> conn
    end
  end

  # ---------------------------------------------------------------------------
  # GET /api/public/cover/:user_id/:title_id/:episode_id
  # ---------------------------------------------------------------------------

  def cover(conn, %{"user_id" => uid_s, "title_id" => tid_s, "episode_id" => eid_s}) do
    with {:ok, user_id} <- path_int(conn, "user_id", uid_s),
         {:ok, title_id} <- path_int(conn, "title_id", tid_s),
         {:ok, episode_id} <- path_int(conn, "episode_id", eid_s),
         {:ok, meta} <- settings_or_404(conn, user_id, title_id, episode_id),
         :ok <- published(conn, meta, "非公開です"),
         :ok <- enforce(conn, Access.enforce_not_suspended(user_id, title_id)),
         :ok <- cover_age(conn, meta) do
      cover_path = Storage.cover_path(user_id, title_id, episode_id)

      if File.exists?(cover_path) do
        conn
        |> put_resp_header("content-type", "image/jpeg")
        |> put_resp_header("cache-control", "public, max-age=86400")
        |> send_file(200, cover_path)
      else
        conn |> put_status(404) |> json(%{detail: "カバー画像が見つかりません"})
      end
    else
      {:error, conn} -> conn
    end
  end

  defp cover_age(conn, meta) do
    if meta["age_restricted"] do
      {:error,
       conn
       |> put_status(403)
       |> json(%{detail: "年齢確認が必要な作品の表紙は表示できません"})}
    else
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # 部品
  # ---------------------------------------------------------------------------

  defp base_url(conn) do
    host =
      case get_req_header(conn, "host") do
        [h | _] -> h
        [] -> conn.host
      end

    "#{conn.scheme}://#{host}"
  end

  defp rate(conn, bucket, limit) do
    case RateLimit.check_unless_internal(conn, "public_" <> bucket, 60_000, limit) do
      :ok -> :ok
      {:error, conn} -> {:error, conn}
    end
  end

  defp settings_or_404(conn, user_id, title_id, episode_id) do
    case Works.read_settings(user_id, title_id, episode_id) do
      {:ok, meta} -> {:ok, meta}
      :missing -> {:error, conn |> put_status(404) |> json(%{detail: "作品が見つかりません"})}
    end
  end

  defp published(conn, meta, message) do
    if meta["status"] == "published" do
      :ok
    else
      {:error, conn |> put_status(403) |> json(%{detail: message})}
    end
  end

  defp enforce(_conn, :ok), do: :ok

  defp enforce(conn, {:error, status, message}) do
    {:error, conn |> put_status(status) |> json(%{detail: message})}
  end

  # Authorization があれば検証し、無ければ匿名（nil）。
  # あるのに無効なら 401（Python 版 _optional_reader と同じ）
  defp optional_reader(conn) do
    case get_req_header(conn, "authorization") do
      [] ->
        {:ok, nil}

      [auth | _] ->
        if String.starts_with?(auth, "Bearer ") do
          token = binary_part(auth, 7, byte_size(auth) - 7)

          case Accounts.user_from_token(token) do
            {:ok, user} -> {:ok, user}
            {:error, message} -> {:error, error_conn(conn, 401, message)}
          end
        else
          {:error, error_conn(conn, 401, "トークンが無効または期限切れです")}
        end
    end
  end

  defp age_verified?(conn) do
    RateLimitKey.internal?(conn) and
      get_req_header(conn, "x-age-verified") == ["1"]
  end

  defp error_conn(conn, status, message) do
    conn |> put_status(status) |> json(%{detail: message})
  end

  defp path_int(conn, name, value) do
    case Integer.parse(value) do
      {n, ""} ->
        {:ok, n}

      _ ->
        {:error,
         conn
         |> put_status(422)
         |> json(%{
           detail: [
             %{
               "type" => "int_parsing",
               "loc" => ["path", name],
               "msg" => "Input should be a valid integer, unable to parse string as an integer",
               "input" => value
             }
           ]
         })}
    end
  end
end
