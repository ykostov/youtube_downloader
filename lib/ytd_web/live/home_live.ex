defmodule YtdWeb.HomeLive do
  use YtdWeb, :live_view
  alias Ytd.VideoProcessor

  require Logger

  @impl true
  def mount(_params, _session, socket) do
     # Create a temporary downloads directory if it doesn't exist
     downloads_dir = Path.join(System.tmp_dir!(), "ytd_downloads")
     File.mkdir_p!(downloads_dir)
    {:ok,
     assign(socket,
       url: "",
       formats: nil,
       error: nil,
       downloading: false,
       selected_format: nil,
       download_progress: 0,
       download_path: nil,
       show_directory_picker: false,
       downloads_dir: downloads_dir
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="main page Home min-h-screen bg-gray-100 py-12 px-4 sm:px-6 lg:px-8">
      <div class="max-w-xl mx-auto">
        <h1 class="text-3xl font-bold text-center text-gray-900 mb-8">
          YouTube Video Downloader
        </h1>

        <div class="bg-white shadow rounded-lg p-6">
          <!-- URL input form remains the same -->
          <form phx-submit="fetch_formats" class="space-y-4">
            <div>
              <label for="url" class="block text-sm font-medium text-gray-700">
                YouTube URL
              </label>
              <div class="mt-1">
                <input
                  type="text"
                  name="url"
                  id="url"
                  value={@url}
                  phx-keyup="validate_url"
                  class="shadow-sm focus:ring-indigo-500 focus:border-indigo-500 block w-full sm:text-sm border-gray-300 rounded-md"
                  placeholder="https://youtube.com/..."
                  required
                />
              </div>
            </div>

            <button
              type="submit"
              class="w-full flex justify-center py-2 px-4 border border-transparent rounded-md shadow-sm text-sm font-medium text-white bg-indigo-600 hover:bg-indigo-700 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-indigo-500"
            >
              Fetch Formats
            </button>
          </form>

          <%= if @error do %>
            <div class="mt-4 bg-red-50 border-l-4 border-red-400 p-4">
              <div class="flex">
                <div class="ml-3">
                  <p class="text-sm text-red-700"><%= @error %></p>
                </div>
              </div>
            </div>
          <% end %>

          <%= if @formats do %>
            <div class="mt-6 space-y-4">
              <h2 class="text-lg font-medium text-gray-900">Available Formats</h2>
              <%= for format <- @formats do %>
                <div class="border rounded-lg p-4 hover:bg-gray-50">
                  <button
                    phx-click="select_format"
                    phx-value-id={format.id}
                    phx-value-ext={format.ext}
                    class="w-full text-left"
                  >
                    <div class="flex justify-between items-center">
                      <div>
                        <p class="font-medium text-gray-900">
                          <%= format.quality %> <%= format.type %>
                        </p>
                        <p class="text-sm text-gray-500">
                          <%= format.size %>
                        </p>
                      </div>
                      <span class="text-indigo-600 text-sm">Download</span>
                    </div>
                  </button>
                </div>
              <% end %>
            </div>
          <% end %>

          <%= if @downloading do %>
            <div class="mt-6">
              <div class="relative pt-1">
                <div class="flex mb-2 items-center justify-between">
                  <div>
                    <span class="text-xs font-semibold inline-block py-1 px-2 uppercase rounded-full text-indigo-600 bg-indigo-200">
                      Downloading
                    </span>
                  </div>
                  <div class="text-right">
                    <span class="text-xs font-semibold inline-block text-indigo-600">
                      <%= @download_progress %>%
                    </span>
                  </div>
                </div>
                <div class="overflow-hidden h-2 mb-4 text-xs flex rounded bg-indigo-200">
                  <div
                    style={"width: #{@download_progress}%"}
                    class="shadow-none flex flex-col text-center whitespace-nowrap text-white justify-center bg-indigo-500 transition-all duration-500"
                  >
                  </div>
                </div>
              </div>
            </div>
          <% end %>

          <%= if @download_path do %>
            <div class="mt-4">
              <.link
          href={~p"/downloads/#{@download_path}"}
          class="inline-flex items-center px-4 py-2 border border-transparent text-sm font-medium rounded-md text-white bg-indigo-600 hover:bg-indigo-700 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-indigo-500"
        >
          Save File
        </.link>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("choose_location", %{"id" => format_id}, socket) do
    {:noreply, assign(socket, selected_format: format_id, show_directory_picker: true)}
  end

  @impl true
  def handle_event("start_download", %{"format_id" => format_id, "directory" => directory}, socket) do
    Logger.info("Starting download for format: #{format_id} to directory: #{directory}")
    VideoProcessor.start_download(socket.assigns.url, format_id, directory)
    {:noreply, assign(socket, downloading: true, download_progress: 0, show_directory_picker: false)}
  end

  @impl true
  def handle_event("open_directory", _, socket) do
    if socket.assigns.download_path do
      directory = Path.dirname(socket.assigns.download_path)
      case :os.type() do
        {:unix, :linux} -> System.cmd("xdg-open", [directory])
        {:unix, :darwin} -> System.cmd("open", [directory])
        {:win32, _} -> System.cmd("explorer", [directory])
      end
    end

    {:noreply, socket}
  end

  @impl true
  def handle_event("validate_url", %{"value" => url}, socket) do
    # Basic URL validation
    case validate_youtube_url(url) do
      :ok -> {:noreply, assign(socket, error: nil, url: url)}
      {:error, message} -> {:noreply, assign(socket, error: message, url: url)}
    end
  end

  @impl true
  def handle_event("fetch_formats", %{"url" => url}, socket) do
    case VideoProcessor.get_formats(url) do
      {:ok, formats} ->
        {:noreply, assign(socket, formats: formats, error: nil)}

      {:error, message} ->
        {:noreply, assign(socket, error: message, formats: nil)}
    end
  end

  @impl true
  def handle_event("select_format", %{"id" => format_id}, socket) do
    VideoProcessor.start_download(socket.assigns.url, format_id, socket.assigns.downloads_dir)
    {:noreply, assign(socket, downloading: true, selected_format: format_id)}
  end


  @impl true
  def handle_event("directory_selected", %{"directory" => directory}, socket) do
    Logger.info("Starting download for format: #{socket.assigns.selected_format} to directory: #{directory}")
    VideoProcessor.start_download(socket.assigns.url, socket.assigns.selected_format, directory)
    {:noreply, assign(socket, downloading: true, download_progress: 0, show_directory_picker: false)}
  end

  @impl true
  def handle_info({:download_progress, progress}, socket) do
    Logger.debug("Download progress: #{progress}%")
    {:noreply, assign(socket, download_progress: progress)}
  end

  @impl true
  def handle_info({:download_complete, path}, socket) do
    Logger.info("Download complete: #{path}")
    filename = Path.basename(path) # This will now be the actual filename without format_id

    {:noreply,
     socket
     |> assign(downloading: false, download_progress: 100, download_path: filename)
     |> put_flash(:info, "Download completed successfully!")}
  end

  @impl true
  def handle_info({:download_error, message}, socket) do
    Logger.error("Download error: #{message}")
    {:noreply,
     socket
     |> assign(downloading: false)
     |> put_flash(:error, message)}
  end

  defp validate_youtube_url(url) do
    cond do
      String.match?(url, ~r/^https?:\/\/(www\.)?(youtube\.com|youtu\.be)/) ->
        :ok

      String.length(url) == 0 ->
        {:error, "Please enter a URL"}

      true ->
        {:error, "Invalid YouTube URL"}
    end
  end
end
