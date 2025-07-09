# sc
A slight upgrade to standard shell process control and systemd user services.

Run them processe in an execution pool and attach to them later.

## Install
Install to ~/.local/bin (recommended)
```sh
zig build install --prefix ~/.local/ -Doptimize=ReleaseSmall
```
Only 84kB on Linux!

## Usage
```sh
id=$(sc bg tail -f /var/log/syslog)
sc fg $id
sc kill $id
```

## TODO
- [x] Implement server-side PTY
- [x] Implement client RPC
- [ ] Client-site display
- [ ] Testing
- [ ] Neovim integration
