# Sc
A slight upgrade to standard shell process control and systemd user services.

Run them processe in an execution pool and attach to them later.

## Install
```sh
zig build install -p ~/.local
```

## Usage
```sh
id=$(sc bg tail -f /var/log/syslog)
sc fg $id
sc kill $id
```

## TODO
- [ ] Implement server-side PTY
- [ ] Implement client RPC
- [ ] Neovim integration
- [ ] Testing?
