defmodule PlatformEx.Storage do
  @moduledoc """
  storage 配置（Python 版と同じ、カレント相対の ./storage）。
  テストではアプリ設定 :storage_dir で差し替えられる。
  """

  def root do
    Application.get_env(:platform_ex, :storage_dir) ||
      Path.join(File.cwd!(), "storage")
  end

  def zips_dir, do: Path.join(root(), "zips")
  def tmp_dir, do: Path.join(root(), "tmp")

  def title_dir(user_id, title_id),
    do: Path.join([zips_dir(), "user_#{user_id}", "title_#{title_id}"])

  def cbz_path(user_id, title_id, episode_id),
    do: Path.join(title_dir(user_id, title_id), "episode_#{episode_id}.cbz")

  def settings_path(user_id, title_id, episode_id),
    do: Path.join(title_dir(user_id, title_id), "episode_#{episode_id}_settings.json")

  def cover_path(user_id, title_id, episode_id),
    do: Path.join(title_dir(user_id, title_id), "episode_#{episode_id}_cover.jpg")

  def thumbs_dir(user_id, title_id, episode_id),
    do: Path.join(title_dir(user_id, title_id), "episode_#{episode_id}_thumbs")

  def thumb_path(user_id, title_id, episode_id, index) do
    Path.join(
      thumbs_dir(user_id, title_id, episode_id),
      "thumb_#{pad4(index)}.jpg"
    )
  end

  def pad4(n), do: n |> Integer.to_string() |> String.pad_leading(4, "0")
end
