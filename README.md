# RunOS Desktop

RunOS Desktop is the macOS menu-bar facade for the RunOS CLI.

Install the application with `runos desktop install`.
Browser downloads are not a supported installation method.

The application requires macOS 15 or newer.
The application has separate Apple Silicon and Intel release archives.
Public builds use an ad hoc Apple signature.
Public builds are not signed with an Apple Developer ID.

Run `make verify` to build and test the application.

## Releases

Run `make release VERSION=vX.Y.Z-rc.N CHECK=1` to check a release candidate.
Use the repository release skills for development and production releases.
The release script keeps `main` under human control.
