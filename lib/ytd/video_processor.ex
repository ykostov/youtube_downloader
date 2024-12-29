defmodule Ytd.VideoProcessor do
  @moduledoc """
  A GenServer module that handles YouTube video processing and downloading functionality.
  Uses yt-dlp under the hood for fetching video information and downloading content.
  Manages concurrent downloads and provides real-time progress updates.
  """
  use GenServer
  require Logger

  alias Ytd.TransliterateHelper

  @youtube_dl_cmd "yt-dlp"
  @cookies_file "/tmp/youtube.cookies"

  @doc """
  Starts the VideoProcessor as a named GenServer.

  ## Parameters
    * _ - Unused argument for start_link

  ## Returns
    * {:ok, pid} if server starts successfully
    * {:error, reason} if server fails to start
  """
  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc """
  Fetches available formats for a given YouTube URL.
  Returns both video and audio formats with quality information.

  ## Parameters
    * url - String containing the YouTube URL

  ## Returns
    * {:ok, formats} where formats is a list of available download options
    * {:error, message} if format fetching fails
  """
  def get_formats(url) do
    GenServer.call(__MODULE__, {:get_formats, url})
  end

  @doc """
  Initiates a video/audio download for the specified format.
  Manages download process and sends progress updates to the caller.

  ## Parameters
    * url - String containing the YouTube URL
    * format_id - String specifying the desired format ID
    * download_dir - String path where files should be saved
    * pid - Optional Process ID to receive progress updates (defaults to self())

  ## Returns
    * Asynchronously sends messages to the caller process:
      - {:download_progress, percentage}
      - {:download_complete, filename}
      - {:download_error, message}
  """

  def start_download(url, format_id, download_dir, pid \\ self()) do
    GenServer.cast(__MODULE__, {:start_download, url, format_id, download_dir, pid})
  end

  @doc """
  GenServer callback for initialization.
  Sets up initial state and ensures download directory exists.

  ## Parameters
    * _ - Unused argument for init

  ## Returns
    * {:ok, state} with initial empty downloads map
  """
  @impl true
  def init(_) do
    downloads_dir = Path.join([File.cwd!(), "priv", "static", "downloads"])
    File.mkdir_p!(downloads_dir)
    {:ok, %{downloads: %{}}}
  end

  @doc """
  Handles format fetching requests.
  Uses yt-dlp to get video information and process available formats.

  ## Parameters
    * {:get_formats, url} - Tuple containing the YouTube URL
    * _from - Caller information
    * state - Current server state

  ## Returns
    * {:reply, {:ok, formats}, state} on success
    * {:reply, {:error, message}, state} on failure
  """
  @impl true
  def handle_call({:get_formats, url}, _from, state) do
    case System.cmd(@youtube_dl_cmd, [
      "--dump-json",
      "--cookies", @cookies_file,
      "--extractor-args", "youtube:player_client=android",  # Use android client
      "--no-check-certificates",                           # Skip HTTPS certificate validation
      "--user-agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36",
      url
    ]) do
      {output, 0} ->
        video_json = Jason.decode!(output)
        formats = process_formats(video_json)
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

  @doc """
  Handles download start requests.
  Initiates download process and monitors progress.

  ## Parameters
    * {:start_download, url, format_id, download_dir, pid} - Download parameters
    * state - Current server state

  ## Returns
    * {:noreply, new_state} with updated downloads map
  """
  @impl true
  def handle_cast({:start_download, url, format_id, download_dir, pid}, state) do
    download_id = generate_download_id()
    File.mkdir_p!(download_dir)

    Task.start(fn ->
      try do
        # Instead of appending +bestaudio, we'll use specific format syntax
        format_arg = if format_id =~ ~r/^\d+$/ do
          # If format_id is just numbers, merge with best audio
          "#{format_id}+bestaudio/best"
        else
          format_id
        end

        # Get video title with updated parameters
        {title_output, 0} = System.cmd(@youtube_dl_cmd, [
          "--print", "title",
          "--cookies", @cookies_file,
          "--extractor-args", "youtube:player_client=android",
          "--no-check-certificates",
          "--user-agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36",
          url
        ])

        safe_title =
          title_output
          |> String.trim()
          |> transliterate()
          |> String.replace(~r/[^a-zA-Z0-9\s-]/, "")
          |> String.replace(~r/\s+/, "-")

        output_template = Path.join(download_dir, "#{safe_title}-%(height)sp.%(ext)s")

        port =
          Porcelain.spawn(
            @youtube_dl_cmd,
            [
              "-f", format_arg,
              "--cookies", @cookies_file,
              "--extractor-args", "youtube:player_client=android",
              "--no-check-certificates",
              "--user-agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36",
              "-o", output_template,
              "--newline",
              "--progress",
              "--merge-output-format", "mp4",    # Ensure we're merging to mp4
              "--audio-quality", "0",            # Best audio quality
              "--audio-format", "aac",           # Use AAC audio codec
              url
            ],
            out: {:send, self()}
          )

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

  """
  Private helper to transliterate text for filename safety.
  Converts special characters to their ASCII equivalents.

  ## Parameters
    * text - String to be transliterated

  ## Returns
    * String with special characters converted to ASCII
  """

  defp transliterate(text) do
    text
    |> String.graphemes()
    |> Enum.map(&TransliterateHelper.transliterate_char/1)
    |> Enum.join()
  end

  @doc """
  Handles download progress updates.
  Updates state and forwards progress to requesting process.

  ## Parameters
    * {:download_update, download_id, progress} - Progress information
    * state - Current server state

  ## Returns
    * {:noreply, new_state} with updated progress
  """
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

  @doc """
  Handles download completion.
  Cleans up state and notifies requesting process.

  ## Parameters
    * {:download_complete, download_id, filepath} - Completion information
    * state - Current server state

  ## Returns
    * {:noreply, new_state} with download removed from state
  """
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

  defp monitor_download(port, client_pid, download_id, download_dir) do
    receive do
      {_, :data, :out, data} ->
        cond do
          String.contains?(data, "Destination:") ->
            filename =
              data
              |> String.split("Destination: ")
              |> List.last()
              |> String.trim()
              |> Path.basename()

            monitor_download(port, client_pid, download_id, download_dir, filename)

          true ->
            monitor_download(port, client_pid, download_id, download_dir)
        end

      {_, :result, %{status: 0}} ->
        Logger.error("Download ended without capturing filename")
        send(client_pid, {:download_error, "Could not determine downloaded file"})

      {_, :result, %{status: status}} ->
        send(client_pid, {:download_error, "Download failed with status #{status}"})

      other ->
        Logger.debug("Unexpected message in initial monitor_download: #{inspect(other)}")
        monitor_download(port, client_pid, download_id, download_dir)
    end
  end

  """
  Private helper to monitor download progress.
  Processes yt-dlp output and sends appropriate messages.

  ## Parameters
    * port - Port running the yt-dlp process
    * client_pid - PID to receive updates
    * download_id - Unique identifier for this download
    * download_dir - Directory where file is being saved
    * filename - Optional previously captured filename

  ## Returns
    * Recursively processes messages until download completes
  """

  defp monitor_download(port, client_pid, download_id, download_dir, filename) do
    receive do
      {_, :data, :out, data} ->
        case parse_progress(data) do
          {:ok, progress} ->
            send(client_pid, {:download_progress, progress})
            monitor_download(port, client_pid, download_id, download_dir, filename)

          :complete ->
            send(client_pid, {:download_complete, filename})

          _ ->
            monitor_download(port, client_pid, download_id, download_dir, filename)
        end

      {_, :result, %{status: 0}} ->
        send(client_pid, {:download_complete, filename})

      {_, :result, %{status: status}} ->
        send(client_pid, {:download_error, "Download failed with status #{status}"})

      other ->
        Logger.debug("Unexpected message in monitor_download: #{inspect(other)}")
        monitor_download(port, client_pid, download_id, download_dir, filename)
    end
  end

  """
  Private helper to parse progress information from yt-dlp output.
  Extracts percentage information from output string.

  ## Parameters
    * data - String containing yt-dlp output

  ## Returns
    * {:ok, progress} with progress percentage
    * :complete when download is finished
    * :error for unparseable data
  """

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

  """
  Private helper to process available formats from yt-dlp output.
  Filters and organizes format information for client use.

  ## Parameters
    * video_json - Decoded JSON data from yt-dlp

  ## Returns
    * List of processed format information
  """

  defp process_formats(video_json) do
    formats = video_json["formats"]

    formats
    |> Enum.filter(&filter_format/1)
    |> Enum.map(&format_info(&1, video_json))
    |> Enum.sort_by(& &1.quality_index, :desc)
    |> select_best_formats()
  end

  """
  Private helper to filter useful formats from yt-dlp output.
  Removes formats without video or audio content.

  ## Parameters
    * format - Individual format information from yt-dlp

  ## Returns
    * Boolean indicating if format should be included
  """

  defp filter_format(format) do
    has_video = format["vcodec"] != "none"
    has_audio = format["acodec"] != "none"

    # Include if it has video (we'll merge with best audio) or if it's an audio-only format
    has_video || (has_audio && !has_video)
  end

  """
  Private helper to extract format information.
  Processes raw format data into structured information.

  ## Parameters
    * format - Individual format information
    * video_info - Complete video information

  ## Returns
    * Map containing processed format information
  """

  defp format_info(format, video_info) do
    type =
      cond do
        format["vcodec"] != "none" && format["acodec"] != "none" -> "Video"
        format["vcodec"] != "none" -> "Video"
        format["acodec"] != "none" -> "Audio MP3"
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
      ext: if(type == "Audio MP3", do: "mp3", else: "mp4"),
      is_audio: type == "Audio MP3",
      thumbnail: video_info["thumbnail"],
      title: video_info["title"]
    }
  end

  """
  Private helper to select best available formats.
  Identifies highest quality video and audio options.
  Special handling for 1080p format when higher quality exists.

  ## Parameters
    * formats - List of all available formats

  ## Returns
    * List of best video and audio formats
  """

  defp select_best_formats(formats) do
    # Get all video formats
    video_formats =
      formats
      |> Enum.filter(&(&1.type == "Video"))
      |> Enum.sort_by(& &1.quality_index, :desc)

    # Get 1080p format if it exists
    format_1080p = Enum.find(video_formats, &(&1.quality_index == 1080))

    # Get the best video format
    best_video = List.first(video_formats)

    # Get audio formats
    audio_formats =
      formats
      |> Enum.filter(&(&1.type == "Audio MP3"))
      |> Enum.sort_by(& &1.quality_index, :desc)

    # Get the best audio format
    best_audio = List.first(audio_formats)

    # If best video is higher than 1080p and 1080p exists, include both
    video_formats_to_include =
      if best_video && format_1080p && best_video.quality_index > 1080 do
        [best_video, format_1080p]
      else
        [best_video]
      end

    # Combine with best audio and remove nils
    (video_formats_to_include ++ [best_audio])
    |> Enum.reject(&is_nil/1)
  end

  """
  Private helper to format file sizes.
  Converts bytes to human-readable format.

  ## Parameters
    * bytes - Integer number of bytes

  ## Returns
    * String with formatted size (GB, MB, or KB)
  """

  defp format_size(bytes) when bytes > 1_000_000_000 do
    "#{Float.round(bytes / 1_000_000_000, 1)} GB"
  end

  defp format_size(bytes) when bytes > 1_000_000 do
    "#{Float.round(bytes / 1_000_000, 1)} MB"
  end

  defp format_size(bytes) do
    "#{Float.round(bytes / 1_000, 1)} KB"
  end

  """
  Private helper to generate unique download IDs.
  Creates random identifier for tracking downloads.

  ## Returns
    * String containing unique identifier
  """

  defp generate_download_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end
end
