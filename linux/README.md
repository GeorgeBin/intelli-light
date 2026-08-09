# intelli-light Linux headless service

The Rust core has no GTK, D-Bus, or systemd library dependency. It reads the same
Codex and Claude status directories as the macOS implementation and can run directly
on Debian, Ubuntu, or Fedora.

```sh
./build.sh
./package-deb.sh
sudo apt install ./dist/intelli-light_0.1.0_$(dpkg --print-architecture).deb
intelli-light-linux setup-user
```

The package installs system files only. `setup-user` creates the current user's
default config, synchronizes only Intelli Light-owned hooks, and enables the
systemd user daemon. See `../docs/linux-debian13.md` for the complete Debian 13
build, install, doctor, and uninstall workflow.

Configuration is stored in `~/.config/intelli-light/config.json`. Supported setters
include:

```sh
intelli-light-linux config set providers codex,claude
intelli-light-linux config set georgeLight.enabled true
intelli-light-linux config set georgeLight.address http://george-light-zero.local
intelli-light-linux config set effects.working.color '#4D8FFF'
intelli-light-linux config set effects.working.modeId 3
intelli-light-linux config set effects.working.durationSec 300
intelli-light-linux config set effects.working.brightness 70
intelli-light-linux doctor
intelli-light-linux uninstall-user
```

Effect names are `working`, `actionRequired`, `error`, and `done`. Hook provider
changes take effect after `intelli-light-linux hooks sync`.

## KDE Plasma desktop

The optional desktop is a separate C++20 Qt6/KF6 application. The daemon remains
the only GeorgeLight owner; the UI communicates over
`$XDG_RUNTIME_DIR/intelli-light/daemon.sock` using newline-delimited JSON.

```sh
cmake -S desktop -B desktop/build -DCMAKE_BUILD_TYPE=Release
cmake --build desktop/build
cmake --install desktop/build
intelli-light-desktop
```

Closing the window hides it to the Plasma system tray. “Quit Desktop” exits only
the UI and leaves `intelli-light.service` running.
