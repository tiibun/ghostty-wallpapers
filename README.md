# ghostty-wallpapers

Rotate Ghostty background images on macOS by updating a managed config overlay and scheduling the script with `launchd`.

## Requirements

- macOS
- Ghostty
- A directory of images (`png`, `jpg`, `jpeg`, `webp`, `gif`, `bmp`)

## One-off usage

First run (required):

```sh
./ghostty-wallpaper.sh --wallpaper-dir ~/Pictures/Ghostty
```

Subsequent runs (wallpaper directory is now remembered):

```sh
./ghostty-wallpaper.sh
```

Useful options:

- `--mode sequential` cycles through sorted files in order.
- `--mode random` picks a different wallpaper at random.
- `--reload-method sigusr2` asks running Ghostty processes to reload their config with `SIGUSR2` (default).
- `--reload-method none` updates Ghostty's config without trying to live-reload the app.
- `--print-selection` prints the image path that was selected.

The script:

1. Chooses a wallpaper from the provided directory.
2. Ensures your main Ghostty config includes a managed overlay file.
3. Writes `background-image = ...` to that overlay file.
4. If Ghostty is running, sends `SIGUSR2` so Ghostty reloads its configuration without GUI scripting.

If you are on an older Ghostty build that does not support `SIGUSR2`, use `--reload-method applescript` as a fallback or `--reload-method none` to skip live reloads.

If a photo relies on EXIF orientation metadata (common for camera and phone portraits), the script writes a managed cache file with the pixels rotated for Ghostty before any optional square crop. This keeps portrait photos upright even when Ghostty ignores the embedded orientation flag, including when `--no-square-crop` is used.

## Periodic rotation with launchd

After the first run (when the wallpaper directory is saved), you can schedule automatic rotation.

1. Generate a LaunchAgent plist for your machine:

   ```sh
   ./ghostty-wallpaper.sh --print-launchd-plist > ~/Library/LaunchAgents/net.tiibun.ghostty-wallpaper.plist
   ```
   Alternatively, to override the saved directory or other settings:

   ```sh
   ./ghostty-wallpaper.sh \
     --wallpaper-dir ~/Pictures/wallpapers \
     --print-launchd-plist \
     > ~/Library/LaunchAgents/net.tiibun.ghostty-wallpaper.plist
   ```

2. Load the agent:

   ```sh
   launchctl bootout "gui/$(id -u)" ~/Library/LaunchAgents/net.tiibun.ghostty-wallpaper.plist 2>/dev/null || true
   launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/net.tiibun.ghostty-wallpaper.plist
   ```

3. Run it immediately without waiting for the next interval:

   ```sh
   launchctl kickstart -k gui/$(id -u)/net.tiibun.ghostty-wallpaper
   ```

## Managed files

- Main Ghostty config: existing macOS config (`~/Library/Application Support/com.mitchellh.ghostty/config`) if present, otherwise XDG config (`~/.config/ghostty/config`)
- Managed overlay: `~/.config/ghostty-wallpapers/wallpaper.conf`
- Rotation state: `~/.config/ghostty-wallpapers/state`

## Validation

```sh
bash test-ghostty-wallpaper.sh
bash -n ghostty-wallpaper.sh
./ghostty-wallpaper.sh --help
tmp_plist="$(mktemp -t ghostty-wallpaper.plist)" && \
  ./ghostty-wallpaper.sh --wallpaper-dir ~/Pictures/Ghostty --print-launchd-plist > "$tmp_plist" && \
  plutil -lint "$tmp_plist" && \
  rm -f "$tmp_plist"
```
