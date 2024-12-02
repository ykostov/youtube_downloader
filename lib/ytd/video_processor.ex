defmodule Ytd.VideoProcessor do
  use GenServer
  require Logger

  @youtube_dl_cmd "yt-dlp"

  # Client API
  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def get_formats(url) do
    GenServer.call(__MODULE__, {:get_formats, url})
  end

  def start_download(url, format_id, download_dir, pid \\ self()) do
    GenServer.cast(__MODULE__, {:start_download, url, format_id, download_dir, pid})
  end

  # Server Callbacks
  @impl true
  def init(_) do
    download_path = Path.join(System.tmp_dir!(), "youtube_download")
    File.mkdir_p!(download_path)
    {:ok, %{downloads: %{}}}
  end

  @impl true
  def handle_call({:get_formats, url}, _from, state) do
    case System.cmd(@youtube_dl_cmd, ["--dump-json", url]) do
      {output, 0} ->
        formats =
          output
          |> Jason.decode!()
          |> Map.get("formats")
          |> process_formats()

        {:reply, {:ok, formats}, state}

      {error, _} ->
        Logger.error("Error fetching video formats: #{error}")
        {:reply, {:error, "Could not fetch video formats"}, state}
    end
  rescue
    e in ErlangError ->
      Logger.error("System command failed: #{inspect(e)}")
      {:reply, {:error, "yt-dlp is not installed. Please install it first."}, state}
  end

  @impl true
  def handle_cast({:start_download, url, format_id, download_dir, pid}, state) do
    download_id = generate_download_id()
    File.mkdir_p!(download_dir)

    Task.start(fn ->
      try do
        # Determine if this is an audio-only download
        format_info =
          case System.cmd(@youtube_dl_cmd, ["--dump-json", url]) do
            {output, 0} ->
              formats =
                output
                |> Jason.decode!()
                |> Map.get("formats")
                |> process_formats()

              Enum.find(formats, &(&1.id == format_id))
          end

        args = if format_info && format_info.is_audio do
          [
            "-f",
            format_id,
            "-o",
            Path.join(download_dir, "%(title)s.%(ext)s"),
            "--newline",
            "--progress",
            "--extract-audio",
            "--audio-format", "mp3",
            "--audio-quality", "0",  # Best quality
            url
          ]
        else
          format_arg = if String.contains?(format_id, "+bestaudio"), do: format_id, else: "#{format_id}+bestaudio"
          [
            "-f",
            format_arg,
            "-o",
            Path.join(download_dir, "%(title)s.mp4"),
            "--newline",
            "--progress",
            "--merge-output-format", "mp4",
            url
          ]
        end

        port = Porcelain.spawn(@youtube_dl_cmd, args, out: {:send, self()})
        monitor_download(port, pid, download_id, download_dir)
      catch
        kind, error ->
          Logger.error("Download failed: #{inspect(kind)} - #{inspect(error)}")
          send(pid, {:download_error, "Download failed: Please try again"})
      end
    end)

    new_downloads = Map.put(state.downloads, download_id, %{
      pid: pid,
      status: :downloading,
      progress: 0,
      url: url,
      format_id: format_id,
      directory: download_dir
    })

    {:noreply, %{state | downloads: new_downloads}}
  end


  @impl true
  def handle_info({:download_update, download_id, progress}, state) do
    case Map.get(state.downloads, download_id) do
      nil ->
        {:noreply, state}

      download_info ->
        send(download_info.pid, {:download_progress, progress})
        new_downloads = put_in(state.downloads[download_id].progress, progress)
        {:noreply, %{state | downloads: new_downloads}}
    end
  end

  @impl true
  def handle_info({:download_complete, download_id, filepath}, state) do
    case Map.get(state.downloads, download_id) do
      nil ->
        {:noreply, state}

      download_info ->
        send(download_info.pid, {:download_complete, filepath})
        new_downloads = Map.delete(state.downloads, download_id)
        {:noreply, %{state | downloads: new_downloads}}
    end
  end

  # Private Functions
  defp monitor_download(port, client_pid, download_id, download_dir) do
    receive do
      {_, :data, :out, data} ->
        case parse_progress(data) do
          {:ok, progress} ->
            send(client_pid, {:download_progress, progress})
            monitor_download(port, client_pid, download_id, download_dir)

          :complete ->
            case find_latest_download(download_dir) do
              nil ->
                send(client_pid, {:download_error, "Could not find downloaded file"})
              filepath ->
                # Here's where we ensure we get just the final filename
                filename = Path.basename(filepath)
                send(client_pid, {:download_complete, filename})
            end

          _ ->
            monitor_download(port, client_pid, download_id, download_dir)
        end

      {_, :result, %{status: 0}} ->
        case find_latest_download(download_dir) do
          nil ->
            send(client_pid, {:download_error, "Could not find downloaded file"})
          filepath ->
            filename = Path.basename(filepath)
            send(client_pid, {:download_complete, filename})
        end

      {_, :result, %{status: status}} ->
        send(client_pid, {:download_error, "Download failed with status #{status}"})

      other ->
        Logger.debug("Unexpected message in monitor_download: #{inspect(other)}")
        monitor_download(port, client_pid, download_id, download_dir)
    end
  end

  defp parse_progress(data) do
    Logger.debug("Parsing progress data: #{inspect(data)}")
    cond do
      String.contains?(data, "100%") ->
        :complete

      String.match?(data, ~r/\s*(\d+\.?\d*)%/) ->
        case Regex.run(~r/\s*(\d+\.?\d*)%/, data) do
          [_, progress] ->
            {progress, _} = Float.parse(progress)
            {:ok, progress}
          _ ->
            :error
        end

      true ->
        :error
    end
  end

  defp find_latest_download(dir) do
    case File.ls!(dir) do
      [] -> nil
      files ->
        files
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.sort_by(fn file ->
          case File.stat(file) do
            {:ok, stat} -> stat.mtime
            {:error, _} -> {{1970,1,1},{0,0,0}}
          end
        end, :desc)
        |> List.first()
    end
  end


  defp process_formats(formats) do
    formats
    |> Enum.filter(&filter_format/1)
    |> Enum.map(&format_info/1)
    |> Enum.sort_by(& &1.quality_index, :desc)
    |> select_best_formats()
  end

  defp filter_format(format) do
    has_video = format["vcodec"] != "none"
    has_audio = format["acodec"] != "none"

    # Include if it has video or if it's an audio format
    has_video || has_audio
  end

  defp format_info(format) do
    type =
      cond do
        format["vcodec"] != "none" && format["acodec"] != "none" -> "Video"
        format["vcodec"] != "none" -> "Video"
        format["acodec"] != "none" -> "Audio MP3"  # Changed label
      end

    quality =
      case type do
        "Audio MP3" -> "#{format["abr"]}kbps"
        _ -> "#{format["height"]}p"
      end

    quality_index =
      case type do
        "Audio MP3" -> format["abr"] || 0
        _ -> format["height"] || 0
      end

    %{
      id: format["format_id"],
      type: type,
      quality: quality,
      quality_index: quality_index,
      size: format_size(format["filesize"] || 0),
      ext: "mp3",  # Force mp3 for audio
      is_audio: type == "Audio MP3"  # Add flag for audio
    }
  end

  defp select_best_formats(formats) do
    # Get all video formats
    video_formats =
      formats
      |> Enum.filter(&(&1.type == "Video"))
      |> Enum.sort_by(&(&1.quality_index), :desc)

    # Get audio formats
    audio_formats =
      formats
      |> Enum.filter(&(&1.type == "Audio MP3"))
      |> Enum.sort_by(&(&1.quality_index), :desc)

    # Get the best video and audio formats
    best_video = List.first(video_formats)
    best_audio = List.first(audio_formats)

    [best_video, best_audio]
    |> Enum.reject(&is_nil/1)
  end

  defp format_size(bytes) when bytes > 1_000_000_000 do
    "#{Float.round(bytes / 1_000_000_000, 1)} GB"
  end

  defp format_size(bytes) when bytes > 1_000_000 do
    "#{Float.round(bytes / 1_000_000, 1)} MB"
  end

  defp format_size(bytes) do
    "#{Float.round(bytes / 1_000, 1)} KB"
  end

  defp generate_download_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end
end
