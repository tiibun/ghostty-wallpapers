# Build, test, and lint commands

- There is no package-level build, test, or lint toolchain yet.
- Manual validation commands:
  - `bash -n bin/ghostty-wallpaper.sh`
  - `bin/ghostty-wallpaper.sh --help`
  - `plutil -lint launchd/net.tiibun.ghostty-wallpaper.plist`
- There is no automated full-suite or single-test command yet.

# High-level architecture

- `bin/ghostty-wallpaper.sh` is the core utility. It selects an image from a wallpaper directory, updates a managed Ghostty config overlay with `background-image`, stores rotation state, and optionally triggers Ghostty's reload action through AppleScript.
- `launchd/net.tiibun.ghostty-wallpaper.plist` shows how to schedule the script to run at a fixed interval on macOS.
- `README.md` is the operational doc for setup, launchd installation, and manual validation.

# Key conventions

- Keep Ghostty config changes narrowly scoped: the script manages a dedicated include block plus an overlay file instead of rewriting unrelated Ghostty settings.
- The project is intentionally macOS-oriented: recurring execution is handled with `launchd`, and live reload depends on AppleScript UI scripting.
- Prefer lightweight manual validation over invented tooling; if new automation is added later, update this file with exact commands.
