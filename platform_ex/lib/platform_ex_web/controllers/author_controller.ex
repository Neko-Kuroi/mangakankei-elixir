defmodule PlatformExWeb.AuthorController do
  @moduledoc """
  作者まわりの API。URL・状態コード・文言は Python 版の /api/author/* と揃える。
  preview/thumb/cover だけは Bearer でなく ?token= で認証する（Python 版と同じ）。
  """
  use PlatformExWeb, :controller

  alias PlatformEx.{Accounts, Jobs, Storage, Works}

  plug PlatformExWeb.Plugs.CurrentUser
       when action in [:works, :upload, :progress, :settings, :delete_episode]

  plug PlatformExWeb.Plugs.RequireAuthor
       when action in [:works, :upload, :progress, :settings, :delete_episode]

  @allowed_tile_sizes [8, 16, 32]

  # ---------------------------------------------------------------------------
  # GET /api/author/works
  # ---------------------------------------------------------------------------

  def works(conn, _params) do
    json(conn, Works.list_works(conn.assigns.current_user))
  end

  # ---------------------------------------------------------------------------
  # POST /api/author/titles/:title_id/episodes/:episode_id/upload-and-zip
  # ---------------------------------------------------------------------------

  def upload(conn, %{"title_id" => tid_s, "episode_id" => eid_s}) do
    # do_scramble / tile_size は FastAPI 側ではクエリパラメータ扱い
    # （フォームで送っても読まれず既定値になる。Python 版の実挙動に合わせる）
    with {:ok, title_id} <- path_int(conn, "title_id", tid_s),
         {:ok, episode_id} <- path_int(conn, "episode_id", eid_s),
         :ok <- check_files_present(conn),
         {:ok, do_scramble} <- form_bool(conn.query_params, conn, "do_scramble", true),
         {:ok, tile_size} <- form_int(conn.query_params, conn, "tile_size", 16),
         :ok <- check_tile_size(conn, tile_size) do
      files = upload_files(conn)
      cover = upload_cover(conn)

      case Works.start_upload(
             conn.assigns.current_user,
             title_id,
             episode_id,
             files,
             cover,
             do_scramble,
             tile_size
           ) do
        {:ok, job_id, total_files} ->
          json(conn, %{job_id: job_id, total_files: total_files})

        {:error, status, message} ->
          conn |> put_status(status) |> json(%{detail: message})
      end
    else
      {:error, conn} -> conn
    end
  end

  # ---------------------------------------------------------------------------
  # GET /api/author/upload-progress/:job_id
  # ---------------------------------------------------------------------------

  def progress(conn, %{"job_id" => job_id}) do
    case Jobs.get(job_id) do
      :error ->
        conn |> put_status(404) |> json(%{detail: "job not found"})

      {:ok, progress} ->
        if progress["phase"] in ["done", "error"] do
          Jobs.pop(job_id)
        end

        json(conn, progress)
    end
  end

  # ---------------------------------------------------------------------------
  # PATCH /api/author/titles/:title_id/episodes/:episode_id/settings
  # ---------------------------------------------------------------------------

  def settings(conn, %{"title_id" => tid_s, "episode_id" => eid_s}) do
    with {:ok, title_id} <- path_int(conn, "title_id", tid_s),
         {:ok, episode_id} <- path_int(conn, "episode_id", eid_s),
         {:ok, settings} <- validate_settings(conn),
         :ok <- check_tile_size(conn, settings["tile_size"]) do
      case Works.update_settings(conn.assigns.current_user, title_id, episode_id, settings) do
        :ok ->
          json(conn, %{status: "success"})

        {:error, status, message} ->
          conn |> put_status(status) |> json(%{detail: message})
      end
    else
      {:error, conn} -> conn
    end
  end

  # ---------------------------------------------------------------------------
  # DELETE /api/author/titles/:title_id/episodes/:episode_id
  # ---------------------------------------------------------------------------

  def delete_episode(conn, %{"title_id" => tid_s, "episode_id" => eid_s}) do
    with {:ok, title_id} <- path_int(conn, "title_id", tid_s),
         {:ok, episode_id} <- path_int(conn, "episode_id", eid_s) do
      case Works.delete_episode(conn.assigns.current_user, title_id, episode_id) do
        {:ok, deleted} ->
          json(conn, %{status: "success", deleted: deleted})

        {:error, status, message} ->
          conn |> put_status(status) |> json(%{detail: message})
      end
    else
      {:error, conn} -> conn
    end
  end

  # ---------------------------------------------------------------------------
  # GET /api/author/preview/:title_id/:episode_id.cbz（?token= 認証）
  # ---------------------------------------------------------------------------

  def preview(conn, %{"title_id" => tid_s, "episode_id_cbz" => eid_cbz}) do
    # ルートでは .cbz 付きの断片として受ける（Phoenix のパス変数は接尾辞を持てないため）
    eid_s = String.replace_suffix(eid_cbz, ".cbz", "")

    if eid_s == eid_cbz do
      conn |> put_status(404) |> json(%{detail: "Not Found"})
    else
      preview_cbz(conn, tid_s, eid_s)
    end
  end

  defp preview_cbz(conn, tid_s, eid_s) do
    with {:ok, user} <- query_user(conn),
         {:ok, title_id} <- path_int(conn, "title_id", tid_s),
         {:ok, episode_id} <- path_int(conn, "episode_id", eid_s) do
      path = Storage.cbz_path(user.id, title_id, episode_id)

      if File.exists?(path) do
        conn
        |> put_resp_header("content-type", "application/zip")
        |> put_resp_header(
          "content-disposition",
          ~s(attachment; filename="preview_t#{title_id}_ep#{episode_id}.cbz")
        )
        |> put_resp_header("cache-control", "no-store")
        |> send_file(200, path)
      else
        conn |> put_status(404) |> json(%{detail: "CBZファイルが見つかりません"})
      end
    else
      {:error, conn} -> conn
    end
  end

  # ---------------------------------------------------------------------------
  # GET /api/author/thumb/:title_id/:episode_id/:index（?token= 認証）
  # ---------------------------------------------------------------------------

  def thumb(conn, %{"title_id" => tid_s, "episode_id" => eid_s, "index" => idx_s}) do
    with {:ok, user} <- query_user(conn),
         {:ok, title_id} <- path_int(conn, "title_id", tid_s),
         {:ok, episode_id} <- path_int(conn, "episode_id", eid_s),
         {:ok, index} <- path_int(conn, "index", idx_s) do
      path = Storage.thumb_path(user.id, title_id, episode_id, index)

      if File.exists?(path) do
        conn
        |> put_resp_header("content-type", "image/jpeg")
        |> put_resp_header("cache-control", "max-age=86400")
        |> send_file(200, path)
      else
        conn |> put_status(404) |> json(%{detail: "サムネイルが見つかりません"})
      end
    else
      {:error, conn} -> conn
    end
  end

  # ---------------------------------------------------------------------------
  # GET /api/author/cover/:title_id/:episode_id（?token= 認証）
  # ---------------------------------------------------------------------------

  def cover(conn, %{"title_id" => tid_s, "episode_id" => eid_s}) do
    with {:ok, user} <- query_user(conn),
         {:ok, title_id} <- path_int(conn, "title_id", tid_s),
         {:ok, episode_id} <- path_int(conn, "episode_id", eid_s) do
      path = Storage.cover_path(user.id, title_id, episode_id)

      if File.exists?(path) do
        conn
        |> put_resp_header("content-type", "image/jpeg")
        |> put_resp_header("cache-control", "max-age=86400")
        |> send_file(200, path)
      else
        conn |> put_status(404) |> json(%{detail: "カバー画像が見つかりません"})
      end
    else
      {:error, conn} -> conn
    end
  end

  # ---------------------------------------------------------------------------
  # ?token= 認証（preview/thumb/cover 用）
  # ---------------------------------------------------------------------------

  defp query_user(conn) do
    case conn.query_params["token"] do
      nil ->
        {:error,
         conn
         |> put_status(422)
         |> json(%{
           detail: [
             %{
               "type" => "missing",
               "loc" => ["query", "token"],
               "msg" => "Field required",
               "input" => nil
             }
           ]
         })}

      token ->
        case Accounts.user_from_token(token) do
          {:ok, user} ->
            if user.account_type == "reader" do
              {:error,
               conn
               |> put_status(403)
               |> json(%{detail: "読者アカウントでは利用できません"})}
            else
              {:ok, user}
            end

          {:error, message} ->
            {:error, conn |> put_status(401) |> json(%{detail: message})}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # パラメータ検証（pydantic の 422 の形を模す）
  # ---------------------------------------------------------------------------

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

  defp check_files_present(conn) do
    case conn.params["files"] do
      nil ->
        {:error, unprocessable(conn, [missing_error("files", nil)])}

      %Plug.Upload{} ->
        :ok

      list when is_list(list) ->
        if Enum.all?(list, &match?(%Plug.Upload{}, &1)),
          do: :ok,
          else: {:error, unprocessable(conn, [missing_error("files", nil)])}

      _ ->
        {:error, unprocessable(conn, [missing_error("files", nil)])}
    end
  end

  defp upload_files(conn) do
    case conn.params["files"] do
      %Plug.Upload{} = upload -> [upload]
      list when is_list(list) -> list
    end
  end

  defp upload_cover(conn) do
    case conn.params["cover"] do
      %Plug.Upload{} = upload -> upload
      _ -> nil
    end
  end

  # アップロードのスカラー値はクエリ由来なので、422 の loc も ["query", _] になる
  defp form_bool(params, conn, name, default) do
    case params[name] do
      nil ->
        {:ok, default}

      value when is_boolean(value) ->
        {:ok, value}

      value when is_binary(value) ->
        case String.downcase(String.trim(value)) do
          v when v in ["true", "1", "yes", "on", "y", "t"] -> {:ok, true}
          v when v in ["false", "0", "no", "off", "n", "f"] -> {:ok, false}
          _ -> {:error, unprocessable(conn, [bool_error(name, value, "query")])}
        end

      value ->
        {:error, unprocessable(conn, [bool_error(name, value, "query")])}
    end
  end

  defp form_int(params, conn, name, default) do
    case params[name] do
      nil ->
        {:ok, default}

      value when is_integer(value) ->
        {:ok, value}

      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {n, ""} -> {:ok, n}
          _ -> {:error, unprocessable(conn, [int_error(name, value, "query")])}
        end

      value ->
        {:error, unprocessable(conn, [int_error(name, value, "query")])}
    end
  end

  defp check_tile_size(conn, tile_size) do
    if tile_size in @allowed_tile_sizes do
      :ok
    else
      {:error,
       conn
       |> put_status(400)
       |> json(%{
         detail: "tile_size は (8, 16, 32) のいずれかにしてください（受信値: #{tile_size}）"
       })}
    end
  end

  # --- settings の検証 ---

  @settings_strings_required ["status", "access_level"]
  @settings_strings_optional ["title_name", "episode_name", "caption", "comment", "note"]
  @settings_bools [{"scrambled", true}, {"webhook_enabled", false}, {"age_restricted", false}]

  defp validate_settings(conn) do
    body = conn.body_params

    if is_map(body) do
      errors =
        Enum.flat_map(@settings_strings_required, fn name ->
          cond do
            not Map.has_key?(body, name) -> [missing_error(name, body)]
            not is_binary(body[name]) -> [string_type_error(name, body[name])]
            true -> []
          end
        end) ++
          Enum.flat_map(@settings_strings_optional, fn name ->
            cond do
              not Map.has_key?(body, name) -> []
              not is_binary(body[name]) -> [string_type_error(name, body[name])]
              true -> []
            end
          end) ++
          Enum.flat_map(@settings_bools, fn {name, _default} ->
            cond do
              not Map.has_key?(body, name) -> []
              is_boolean(body[name]) -> []
              is_binary(body[name]) and parse_bool(body[name]) != :error -> []
              true -> [bool_error(name, body[name])]
            end
          end) ++
          case Map.fetch(body, "tile_size") do
            :error ->
              []

            {:ok, v} when is_integer(v) ->
              []

            {:ok, v} when is_binary(v) ->
              if int_string?(v), do: [], else: [int_error("tile_size", v)]

            {:ok, v} ->
              [int_error("tile_size", v)]
          end

      if errors == [] do
        settings =
          %{
            "status" => body["status"],
            "access_level" => body["access_level"],
            "scrambled" => bool_value(body["scrambled"], true),
            "tile_size" => int_value(body["tile_size"], 16),
            "webhook_enabled" => bool_value(body["webhook_enabled"], false),
            "age_restricted" => bool_value(body["age_restricted"], false)
          }
          |> Map.merge(
            Map.new(@settings_strings_optional, fn name -> {name, body[name] || ""} end)
          )

        {:ok, settings}
      else
        {:error, unprocessable(conn, errors)}
      end
    else
      {:error, unprocessable(conn, missing_errors(body, @settings_strings_required))}
    end
  end

  defp parse_bool(value) do
    case String.downcase(String.trim(value)) do
      v when v in ["true", "1", "yes", "on", "y", "t"] -> true
      v when v in ["false", "0", "no", "off", "n", "f"] -> false
      _ -> :error
    end
  end

  defp bool_value(nil, default), do: default
  defp bool_value(value, _default) when is_boolean(value), do: value

  defp bool_value(value, default) when is_binary(value),
    do:
      parse_bool(value)
      |> then(fn
        :error -> default
        parsed -> parsed
      end)

  defp int_string?(value) do
    case Integer.parse(String.trim(value)) do
      {_, ""} -> true
      _ -> false
    end
  end

  defp int_value(nil, default), do: default
  defp int_value(value, _default) when is_integer(value), do: value

  defp int_value(value, _default) when is_binary(value),
    do: value |> String.trim() |> String.to_integer()

  # --- 422 の部品 ---

  defp unprocessable(conn, errors) do
    conn |> put_status(422) |> json(%{detail: errors})
  end

  defp missing_error(name, input) do
    %{
      "type" => "missing",
      "loc" => ["body", name],
      "msg" => "Field required",
      "input" => input
    }
  end

  defp missing_errors(input, names) do
    Enum.map(names, fn name ->
      %{
        "type" => "missing",
        "loc" => ["body", name],
        "msg" => "Field required",
        "input" => input
      }
    end)
  end

  defp string_type_error(name, value) do
    %{
      "type" => "string_type",
      "loc" => ["body", name],
      "msg" => "Input should be a valid string",
      "input" => value
    }
  end

  defp int_error(name, value, loc_root \\ "body") do
    %{
      "type" => "int_parsing",
      "loc" => [loc_root, name],
      "msg" => "Input should be a valid integer, unable to parse string as an integer",
      "input" => value
    }
  end

  defp bool_error(name, value, loc_root \\ "body") do
    %{
      "type" => "bool_parsing",
      "loc" => [loc_root, name],
      "msg" => "Input should be a valid boolean, unable to interpret input",
      "input" => value
    }
  end
end
