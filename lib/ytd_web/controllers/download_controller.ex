defmodule YtdWeb.DownloadController do
  use YtdWeb, :controller
  require Logger

  def download(conn, %{"filename" => filename}) do
    downloads_dir = Path.join(System.tmp_dir!(), "ytd_downloads")
    file_path = Path.join(downloads_dir, filename)

    Logger.debug("Looking for file: #{file_path}")
    Logger.debug("Directory contents: #{inspect(File.ls!(downloads_dir))}")

    case File.exists?(file_path) do
      true ->
        conn
        |> put_resp_content_type("application/octet-stream")
        |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
        |> send_file(200, file_path)

      false ->
        # Try to find the file without the format ID if it's present
        base_filename = filename
                       |> String.split(".")
                       |> List.first()
                       |> Kernel.<>(".mp4")

        alternative_path = Path.join(downloads_dir, base_filename)

        if File.exists?(alternative_path) do
          conn
          |> put_resp_content_type("application/octet-stream")
          |> put_resp_header("content-disposition", ~s(attachment; filename="#{base_filename}"))
          |> send_file(200, alternative_path)
        else
          Logger.error("File not found at path: #{file_path}")
          Logger.error("Alternative path also not found: #{alternative_path}")
          Logger.error("Available files in directory: #{inspect(File.ls!(downloads_dir))}")

          conn
          |> put_status(:not_found)
          |> text("File not found")
        end
    end
  end
end
