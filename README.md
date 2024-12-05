# YouTube Video Downloader

A Phoenix LiveView application that allows users to download videos and audio from YouTube. Built with Elixir/Phoenix and featuring real-time updates, progress tracking, and multi-format support.

## Features

- Download YouTube videos in various quality formats
- Extract audio from YouTube videos
- Real-time download progress updates
- Support for both video and audio-only downloads
- Automatic quality selection (highest quality + 1080p option when available)
- Page view tracking
- Clean interface with format details and size information

## Prerequisites

Before you begin, ensure you have the following installed:

- Elixir (1.14 or later)
- Phoenix Framework
- PostgreSQL
- [yt-dlp](https://github.com/yt-dlp/yt-dlp) (YouTube-DLP command line tool)
- Node.js (for asset building)

## Installation

1. Clone the repository:
```console
git clone [repository-url]
cd youtube-downloader
```

2. Install dependencies:

```console
mix deps.get
mix deps.compile
cd assets && npm install
```

3. Set up the database:

```console
mix ecto.create
mix ecto.migrate
```

4. Start the Phoenix server:

```console
mix phx.server
```
Now you can visit localhost:4000 from your browser.

## Usage
1. Enter a YouTube URL in the input field
2. Click "Fetch Formats" to see available download options
3. Select your preferred format:
- Video formats show resolution and file size
- Audio formats show bitrate and file size
4.Track download progress in real-time
5. Click "Save File" when download completes

## Features in Detail
### Video Format Selection
- Automatically shows highest quality video option
- When available, also shows 1080p option for better compatibility
- Displays file size and quality information for each format
### Audio Extraction
- Option to download audio-only in high quality
- Automatically converts to MP3 format
### Download Management
- Real-time progress tracking
- Automatic file naming with quality indication
- Downloads stored in project's static directory
- Directory cleaned on new session
### Page View Tracking
- Tracks number of page views
- Persists count in PostgreSQL database
- Updates in real-time across all connected clients
### Project Structure
- `lib/ytd/video_processor.ex` - Core video processing logic
- `lib/ytd_web/live/home_live.ex` - Main LiveView interface
- `lib/ytd_web/controllers/download_controller.ex` - File download handling
- `lib/ytd/tracking/page_view.ex` - Page view tracking functionality
### Configuration
The application stores downloads in priv/static/downloads/. This directory is:

- Created automatically if it doesn't exist
- Cleaned on new sessions
- Served through Phoenix's static file handling

## Contributing

1. Fork the repository
2. Create your feature branch (git checkout -b feature/amazing-feature)
3. Commit your changes (git commit -m 'Add some amazing feature')
4. Push to the branch (git push origin feature/amazing-feature)
5. Open a Pull Request

## License
