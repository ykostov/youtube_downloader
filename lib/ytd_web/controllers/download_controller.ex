defmodule YtdWeb.DownloadController do
  @moduledoc """
  Controller responsible for handling file downloads in the YouTube downloader application.
  Manages serving video and audio files from the temporary downloads directory.
  """
  use YtdWeb, :controller
  require Logger

  @doc """
  Handles file download requests.
  Attempts to find and serve the requested file, with fallback to alternative filenames.
  Includes logging for debugging download issues.

  ## Parameters
    * conn - The connection struct
    * %{"filename" => filename} - Map containing the requested filename

  ## Returns
    * conn - Modified connection sending either:
      - 200 status with file stream if found
      - 404 status with error message if file not found

  ## Examples
    First tries to find exact filename match.
    If not found, attempts to find file without format ID.
    Logs detailed debugging information about file search process.

  ## File Search Logic
    1. Looks for exact match in downloads directory
    2. If not found, tries alternative filename (base name + .mp4)
    3. Returns 404 if neither exists
  """
  def download(conn, %{"filename" => filename}) do
    downloads_dir = Path.join([File.cwd!(), "priv", "static", "downloads"])
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
        base_filename =
          filename
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
