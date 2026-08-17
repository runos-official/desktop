# RunOS Desktop operating contract

Read `AGENTS.md` before making changes.

The application displays CLI state and sends CLI commands.
The application does not implement authentication, VPN, installation, or update policy.
Keep all process execution inside `CLIRunner`.
Keep all action serialization inside `RefreshCoordinator`.

Use `.claude/skills/release-desktop/SKILL.md` for a development release.
Use `.claude/skills/deploy-prod/SKILL.md` for a production release.
Use `scripts/release.sh` as the only release entry point.
