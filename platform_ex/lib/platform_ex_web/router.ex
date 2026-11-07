defmodule PlatformExWeb.Router do
  use PlatformExWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {PlatformExWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug PlatformExWeb.Plugs.FetchWebUser
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", PlatformExWeb do
    pipe_through :browser

    post "/session", SessionController, :create
    post "/session/signup", SessionController, :signup
    post "/session/logout", SessionController, :delete
    post "/viewer-url", SessionController, :viewer_url

    get "/login", LoginController, :show

    live_session :public, on_mount: [{PlatformExWeb.UserAuth, :mount_current_user}] do
      live "/", CatalogLive
    end

    live_session :author, on_mount: [{PlatformExWeb.UserAuth, :require_user}] do
      live "/author", AuthorLive
    end

    live_session :admin, on_mount: [{PlatformExWeb.UserAuth, :require_admin}] do
      live "/admin", AdminLive
    end
  end

  scope "/api", PlatformExWeb do
    pipe_through :api

    post "/auth/signup", AuthController, :signup
    post "/auth/token", AuthController, :login
    get "/auth/me", AuthController, :me
    get "/auth/grants", AuthController, :grants
    post "/auth/declare-adult", AuthController, :declare_adult

    get "/author/works", AuthorController, :works
    post "/author/titles/:title_id/episodes/:episode_id/upload-and-zip", AuthorController, :upload
    get "/author/upload-progress/:job_id", AuthorController, :progress
    patch "/author/titles/:title_id/episodes/:episode_id/settings", AuthorController, :settings
    delete "/author/titles/:title_id/episodes/:episode_id", AuthorController, :delete_episode
    get "/author/preview/:title_id/:episode_id_cbz", AuthorController, :preview
    get "/author/thumb/:title_id/:episode_id/:index", AuthorController, :thumb
    get "/author/cover/:title_id/:episode_id", AuthorController, :cover

    get "/author/titles/:title_id/grants", AdminController, :grants
    post "/author/titles/:title_id/grants", AdminController, :create_grant
    delete "/author/titles/:title_id/grants/:user_id", AdminController, :delete_grant

    get "/admin/works", AdminController, :works
    post "/admin/titles/:author_id/:title_id/suspend", AdminController, :suspend
    post "/admin/titles/:author_id/:title_id/resume", AdminController, :resume

    get "/config", PublicController, :config
    get "/public/catalog", PublicController, :catalog
    get "/public/cbz/:user_id/:title_id/:episode_id_cbz", PublicController, :cbz
    get "/public/thumb/:user_id/:title_id/:episode_id/:index", PublicController, :thumb
    get "/public/cover/:user_id/:title_id/:episode_id", PublicController, :cover
  end
end
