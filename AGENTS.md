# Local development rules

- The user authorized GitHub auto-updates and the next release on 2026-10-18. Publish only after relevant validation; later releases require fresh authorization.
- Use `Scripts/local.sh` for the current local app. It replaces `.build/local` only after a successful build and removes obsolete generated Clipboard copies and installers from this workspace.
- Never remove clipboard history, user preferences, backups, source files, or a running installed app as part of build cleanup.
- Keep the compact AppKit popup and native framework architecture. Automatic paste requires event-posting access; do not request Input Monitoring, Screen Recording, or Full Disk Access to compensate for a focus bug.
