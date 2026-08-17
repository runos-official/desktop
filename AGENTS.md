# RunOS Desktop operating contract

RunOS Desktop is a permanent facade over the `runos` CLI.

- Keep VPN and authentication logic in the CLI.
- Execute one configured absolute CLI path.
- Never resolve the CLI through `PATH`.
- Keep stdout JSON decoding compatible with released CLI versions.
- Send user-visible CLI errors without rewriting them.
- Use no third-party Swift packages.
- Support macOS 15 and newer.
- Run `make verify` before each release.
- Do not add assistant co-author trailers to commits.
