defmodule FaberWeb.Layouts do
  @moduledoc "The root HTML document. CSS/JS are vendored static files, kept out of the template."
  use FaberWeb, :html

  # Cache-bust the two files we hand-edit by tagging their URL with the file's mtime. There's no
  # asset build/digest here (vendored, no-build) and dev has no live-reload, so without this a
  # browser silently serves a stale app.css/app.js after an edit. Read per full-page render only
  # (not per LiveView update); stable in prod where the files don't change, so caching still holds.
  defp asset_vsn(file) do
    path = Application.app_dir(:faber, "priv/static/assets/#{file}")

    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} -> Integer.to_string(mtime)
      _ -> "0"
    end
  end

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
        <title>Faber — friction dashboard</title>
        <link rel="stylesheet" href={~p"/assets/app.css?#{[v: asset_vsn("app.css")]}"} />
        <script defer src={~p"/assets/phoenix.min.js"}>
        </script>
        <script defer src={~p"/assets/phoenix_live_view.min.js"}>
        </script>
        <script defer src={~p"/assets/app.js?#{[v: asset_vsn("app.js")]}"}>
        </script>
      </head>
      <body>
        <.flash_group flash={@flash} />
        {@inner_content}
      </body>
    </html>
    """
  end

  @doc "Minimal flash renderer so `put_flash/3` messages aren't silently dropped. Click to dismiss."
  attr :flash, :map, default: %{}

  def flash_group(assigns) do
    ~H"""
    <div
      :for={{kind, msg} <- @flash}
      class={"flash flash-#{kind}"}
      role="alert"
      phx-click={Phoenix.LiveView.JS.push("lv:clear-flash", value: %{key: kind})}
    >
      {msg}
    </div>
    """
  end
end
