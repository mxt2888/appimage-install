# appimage-install

Install AppImages like real packages — on any Linux distro.

AppImages run everywhere, but they don't *integrate*: no application-menu entry, no
icon, not on your `PATH`, and no clean way to uninstall. `appimage-install` fixes
that. It copies the AppImage to a stable location, registers a menu entry and icon,
drops a launcher on your `PATH`, and tracks every file it creates so removal is
clean.

It works on every distro because it relies only on the **freedesktop.org (XDG)
standards** that GNOME, KDE, XFCE, Cinnamon, MATE, LXQt, etc. all read — not on
`apt`/`dnf`/`pacman`. No root is needed for the default per-user install.

## Install

```sh
chmod +x appimage-install
sudo mv appimage-install /usr/local/bin/    # optional: put it on your PATH
```

## Usage

```sh
appimage-install install ./MyApp-x86_64.AppImage   # install + integrate
appimage-install ./MyApp.AppImage                  # shorthand for install
appimage-install list                              # list installed apps
appimage-install info myapp                         # show details for one app
appimage-install remove myapp                       # uninstall cleanly
appimage-install install ./MyApp.AppImage --system  # for all users (uses sudo)
```

After installing, launch the app from your application menu, or run its command name
in a terminal.

### Options

| Option          | Description                                                  |
|-----------------|--------------------------------------------------------------|
| `--system`      | Install for all users (writes to `/opt`, `/usr/share`; uses `sudo`). |
| `--name NAME`   | Override the app id / command name.                          |
| `--force`, `-f` | Skip the AppImage sanity check / overwrite without prompt.   |
| `--version`,`-V`| Print the version.                                           |
| `-h`, `--help`  | Show help.                                                   |

## How it works

For each install it:

1. Copies the AppImage to a stable location (`~/.local/share/appimages`, or `/opt`).
2. Extracts the app's `.desktop` entry and icon (using the AppImage's built-in
   `--appimage-extract`, which needs no FUSE) and registers them so the app appears
   in your menu.
3. Generates a small launcher on your `PATH`. The launcher auto-detects a missing
   **FUSE2** library and transparently falls back to extract-and-run — so apps still
   launch on Ubuntu 22.04+, immutable distros, and anywhere `libfuse2` isn't present.
4. Records every file it created, so `remove` deletes exactly those and nothing else.

## Where files go

| Item            | Per-user (default)                  | `--system`                |
|-----------------|-------------------------------------|---------------------------|
| AppImage + icon | `~/.local/share/appimages/`         | `/opt/appimages/`         |
| Launcher        | `~/.local/bin/`                     | `/usr/local/bin/`         |
| Menu entry      | `~/.local/share/applications/`      | `/usr/share/applications/`|

> If `~/.local/bin` isn't on your `PATH`, the menu entry still works; you just won't
> be able to run the app by name in a terminal until you add it.

## Requirements

- **bash** and standard coreutils (`find`, `sed`, `awk`, `od`, `readlink`, …) —
  present on essentially every Linux system.
- The AppImage itself still needs **glibc** to run.
- **FUSE2** is optional — the launcher falls back to extract-and-run without it.
- `update-desktop-database`, `gtk-update-icon-cache`, and `desktop-file-validate`
  are used if available, and skipped gracefully if not.

## Limitations

- **No auto-update.** AppImages have no central repo; to update, re-run `install`
  on the newer file and it replaces the old version.
- **No magic across libc.** A glibc AppImage won't run on a musl-only distro (e.g.
  Alpine) — that's an AppImage limitation, not this tool's.
- It integrates AppImages; it does not sandbox them.

## Uninstall the tool

```sh
sudo rm /usr/local/bin/appimage-install
```

Remove individual apps first with `appimage-install remove <id>` if you want them
gone too.
