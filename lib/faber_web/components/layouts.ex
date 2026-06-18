defmodule FaberWeb.Layouts do
  @moduledoc "The root HTML document. CSS/JS are vendored static files, kept out of the template."
  use FaberWeb, :html

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
        <title>Faber — friction dashboard</title>
        <link rel="stylesheet" href={~p"/assets/app.css"} />
        <script defer src={~p"/assets/phoenix.min.js"}>
        </script>
        <script defer src={~p"/assets/phoenix_live_view.min.js"}>
        </script>
        <script defer src={~p"/assets/app.js"}>
        </script>
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end
end
