# RunOS Desktop operating contract

Read `AGENTS.md` before making changes.

The application displays CLI state and sends CLI commands.
The application does not implement authentication, VPN, installation, or update policy.
Keep all process execution inside `CLIRunner`.
Keep all action serialization inside `RefreshCoordinator`.
