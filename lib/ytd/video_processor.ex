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
        port = Porcelain.spawn(@youtube_dl_cmd, [
          "-f",
          format_id,
          "-o",
          Path.join(download_dir, "%(title)s.%(ext)s"),
          "--newline",
          "--progress",
          url
        ], out: {:send, self()})

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
            filepath = find_latest_download(download_dir)
            send(client_pid, {:download_complete, filepath})

          _ ->
            monitor_download(port, client_pid, download_id, download_dir)
        end

      {_, :result, %{status: 0}} ->
        filepath = find_latest_download(download_dir)
        send(client_pid, {:download_complete, filepath})

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
    dir
    |> File.ls!()
    |> Enum.map(&Path.join(dir, &1))
    |> Enum.sort_by(
      fn file ->
        stat = File.stat!(file)
        # Convert Erlang datetime tuple to Unix timestamp for comparison
        calendar = stat.mtime
        :calendar.datetime_to_gregorian_seconds(calendar)
      end,
      :desc
    )
    |> List.first()
  end

  defp process_formats(formats) do
    formats
    |> Enum.filter(&filter_format/1)
    |> Enum.map(&format_info/1)
    |> Enum.sort_by(& &1.quality_index, :desc)
    |> select_best_formats()
  end

  defp filter_format(format) do
    # Filter out formats we don't want
    format["vcodec"] != "none" || format["acodec"] != "none"
  end

  defp format_info(format) do
    type =
      cond do
        format["vcodec"] != "none" && format["acodec"] != "none" -> "Video"
        format["vcodec"] != "none" -> "Video (no audio)"
        format["acodec"] != "none" -> "Audio only"
      end

    quality =
      case type do
        "Audio only" -> "#{format["abr"]}kbps"
        _ -> "#{format["height"]}p"
      end

    quality_index =
      case type do
        "Audio only" -> format["abr"] || 0
        _ -> format["height"] || 0
      end

    %{
      id: format["format_id"],
      type: type,
      quality: quality,
      quality_index: quality_index,
      size: format_size(format["filesize"] || 0),
      ext: format["ext"] || "mp4"
    }
  end

  defp select_best_formats(formats) do
    video_formats = Enum.filter(formats, &(&1.type == "Video"))
    audio_formats = Enum.filter(formats, &(&1.type == "Audio only"))

    # Select highest, middle, and lowest quality video formats
    selected_videos =
      case video_formats do
        [] -> []
        [single] -> [single]
        videos ->
          [
            Enum.at(videos, 0),
            Enum.at(videos, div(length(videos), 2)),
            Enum.at(videos, -1)
          ]
      end

    # Select best audio format
    best_audio = List.first(audio_formats)

    (selected_videos ++ [best_audio])
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
