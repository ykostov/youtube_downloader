defmodule YtdWeb.DownloadController do
  use YtdWeb, :controller

  def download(conn, %{"filename" => filename}) do
    downloads_dir = Path.join(System.tmp_dir!(), "ytd_downloads")
    file_path = Path.join(downloads_dir, filename)

    if File.exists?(file_path) do
      conn
      |> put_resp_content_type("application/octet-stream")
      |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
      |> send_file(200, file_path)
    else
      conn
      |> put_status(:not_found)
      |> text("File not found")
    end
  end
end
