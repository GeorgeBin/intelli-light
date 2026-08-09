# Intelli Light on Debian 13 KDE Plasma

Intelli Light consists of the headless `intelli-light-linux` Rust daemon/CLI and
the optional native `intelli-light-desktop` C++20 Qt 6/KDE Frameworks 6 UI. The
daemon owns session arbitration, hooks, configuration, and GeorgeLight output.
The desktop communicates with it through a private Unix socket and never drives
GeorgeLight directly.

## Verified platform

- Debian 13.6 (trixie), amd64
- KDE Plasma 6.3.6 on Wayland
- Qt 6.8.2
- KDE Frameworks 6.13.0
- GCC 14.2 and CMake 3.31.6
- Rust/Cargo 1.97.1

The packaging scripts select the native Debian architecture and accept `amd64`
or `arm64`; only amd64 has been built and exercised on hardware so far. They do
not cross-compile or relabel a binary for another architecture.

## Build dependencies

The package names below were confirmed from Debian 13 apt metadata and CMake
package discovery:

```text
build-essential
cargo
rustc
cmake
extra-cmake-modules
qt6-base-dev
libkf6coreaddons-dev
libkf6i18n-dev
libkf6statusnotifieritem-dev
```

Install them with:

```sh
sudo apt install build-essential cargo rustc cmake extra-cmake-modules \
  qt6-base-dev libkf6coreaddons-dev libkf6i18n-dev \
  libkf6statusnotifieritem-dev
```

`./linux/build.sh` runs Rust formatting, Clippy, all Rust/contract tests, a
release Rust build, a fresh CMake configure/build, and Desktop CTest tests.
`./linux/package-deb.sh` runs that build and creates the package under
`linux/dist/`. Set `INTELLI_LIGHT_SKIP_BUILD=1` only when using already verified
artifacts from the same source tree.

## Runtime dependencies

Direct ELF dependencies were determined with `readelf`, `ldd`, and `dpkg -S`;
package relationships were checked with apt metadata. The Debian package
declares:

```text
libc6
libgcc-s1
libstdc++6
libqt6core6t64
libqt6gui6
libqt6network6
libqt6widgets6
libkf6coreaddons6
libkf6i18n6
libkf6statusnotifieritem6
nodejs
systemd
```

Dependencies of those libraries, including Qt D-Bus and KF6 WindowSystem, are
resolved by Debian. Node.js executes the Codex/Claude hook resources. A Plasma
session already provides the session D-Bus and StatusNotifier watcher needed by
the tray; no GNOME AppIndicator extension is required.

## Install and first-user setup

```sh
./linux/package-deb.sh
sudo apt install ./linux/dist/intelli-light_0.1.0_amd64.deb
intelli-light-linux setup-user
```

The package installs only system-owned files under `/usr`. Its maintainer phase
does not inspect or modify any home directory. `setup-user` performs the
per-user work and is safe to repeat:

- creates `~/.config/intelli-light/config.json` when absent;
- synchronizes only Intelli Light-owned Codex and Claude hooks;
- migrates an Intelli Light-owned legacy per-user unit override;
- reloads, enables, and starts `intelli-light.service` with `systemctl --user`.

Existing unrelated hooks and settings remain in place. At least one provider
must stay enabled.

## Desktop and tray

Start the native UI from the application launcher or run:

```sh
intelli-light-desktop
```

Closing the main window hides it in the Plasma tray. The tray menu shows global,
Codex, and Claude states, opens the window, toggles GeorgeLight, and quits only
the Desktop process. The systemd user daemon continues independently.

## Service and IPC

```sh
systemctl --user status intelli-light.service
systemctl --user restart intelli-light.service
journalctl --user -u intelli-light.service
```

The packaged unit is `/usr/lib/systemd/user/intelli-light.service`. Runtime IPC
uses newline-delimited JSON version 1 at
`$XDG_RUNTIME_DIR/intelli-light/daemon.sock`, mode `0600`.

## Configuration and hooks

```sh
intelli-light-linux config show
intelli-light-linux config set providers codex,claude
intelli-light-linux hooks sync
```

User configuration remains under `~/.config/intelli-light/`. State and lifecycle
files retain the cross-platform contract locations:

The default GeorgeLight HTTP address is
`http://george-light-zero.local`. The Desktop displays this value before the
daemon's first snapshot and whenever no saved address is available; an explicit
user-configured address takes precedence.

```text
~/.codex/statusbar/states.d/
~/.codex/statusbar/sessions.d/
~/.claude/statusbar/states.d/
~/.claude/statusbar/sessions.d/
```

The source hook resources are also installed read-only under
`/usr/share/intelli-light/hooks/`; the CLI uses its embedded matching copies when
synchronizing a user.

## Doctor

```sh
intelli-light-linux doctor
```

Doctor reports the OS, architecture, provider executables, hooks, config,
systemd user manager, daemon, session D-Bus, KDE Desktop executable, Plasma tray,
IPC, and GeorgeLight address/connectivity. A missing Codex or Claude executable
is a provider warning rather than a failure of the whole installation.

## Per-user and package uninstall

Run per-user cleanup before removing the package:

```sh
intelli-light-linux uninstall-user
sudo apt remove intelli-light
```

`uninstall-user` disables the user service, removes only Intelli Light-owned
Codex/Claude hooks, and removes the runtime socket. It preserves
`~/.config/intelli-light/config.json` by default. To remove that config too:

```sh
intelli-light-linux uninstall-user --remove-config
```

Package removal deletes the `/usr` files and never edits a user's home.

## Known limitations

- arm64 packaging is architecture-aware but has not yet been physically tested.
- The UI targets KDE Plasma's StatusNotifier implementation; other desktops may
  show the main window but provide different tray behavior.
- The daemon requires a functioning `systemd --user` manager for managed startup.
- GeorgeLight discovery depends on the configured hostname being resolvable from
  the local machine.
