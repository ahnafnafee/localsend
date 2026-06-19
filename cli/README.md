# LocalSend CLI

A small command-line companion to the LocalSend app. Currently it provides a
**headless receiver** — a server that speaks the LocalSend v2 protocol and saves
incoming files to a folder, with no GUI. Useful as an always-on drop target (e.g.
on a homelab box or a Raspberry Pi reachable over Tailscale).

## Build / run

```sh
cd cli
dart pub get
dart run bin/cli.dart receive --dir ./inbox
```

Or compile a self-contained binary:

```sh
dart compile exe bin/cli.dart -o localsend
./localsend receive --dir ./inbox
```

## `receive` options

| Option | Default | Description |
|---|---|---|
| `--alias <name>` | this host's name | Device name shown to senders |
| `-p, --port <n>` | `53317` | Port to listen on |
| `-d, --dir <path>` | `./localsend` | Where received files are saved |
| `--pin <pin>` | _(none)_ | Require this PIN for incoming transfers |
| `--http` | off (HTTPS) | Serve plain HTTP instead of HTTPS |

The receiver **auto-accepts** every transfer (there is no prompt in headless mode),
so point `--dir` somewhere sensible and, if exposing it beyond a trusted network,
set a `--pin`.

## Discovery

The receiver does not multicast-announce, and multicast does not cross a Tailscale
tailnet anyway. To reach it, **add it as a favorite by IP** on your other devices
(the startup banner prints the reachable `https://<ip>:<port>` URLs). It generates a
fresh self-signed certificate on each start (the printed fingerprint is its device
identity), exactly like the app.

## Notes

- The receive server is a pure-`dart:io` reimplementation of the app's server
  (`app/lib/provider/network/server/...`), since that one is Flutter-coupled. It
  reuses the shared DTOs/routes/constants from the `common` package.
- Sending from the CLI is not implemented yet (`receive` only).
