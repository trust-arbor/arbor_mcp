defmodule McpAppsHostWeb.Layouts do
  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!doctype html>
    <html lang="en" data-theme="light">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <title>Arbor · Apps Studio</title>
        <link rel="stylesheet" href="/assets/host.css" />
        <script defer src="/assets/host.js">
        </script>
      </head>
      <body>{@inner_content}</body>
    </html>
    """
  end
end
