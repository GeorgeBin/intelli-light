# intelli-light Linux headless service

The Rust core has no GTK, D-Bus, or systemd library dependency. It reads the same
Codex and Claude status directories as the macOS implementation and can run directly
on Debian, Ubuntu, or Fedora.

```sh
cargo build --release
install -Dm755 target/release/intelli-light-linux ~/.local/bin/intelli-light-linux
install -Dm644 ../packaging/linux/intelli-light.service \
  ~/.config/systemd/user/intelli-light.service

intelli-light-linux hooks install
systemctl --user daemon-reload
systemctl --user enable --now intelli-light.service
```

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
```

Effect names are `working`, `actionRequired`, `error`, and `done`. Hook provider
changes take effect after `intelli-light-linux hooks sync`.
