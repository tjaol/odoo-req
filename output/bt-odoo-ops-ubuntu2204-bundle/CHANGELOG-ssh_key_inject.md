# ssh_key_inject.sh change log

## 2026-02-26

### Added
- `--auth-mode auto|password|key` (default `auto`)
- `--no-inject` to skip inject/revoke lifecycle when server already trusts your key

### Behavior changes
- `--rotate-count` is now optional; omit means unlimited file count
- `remote-logrotate` detection logic no longer uses `grep -P` (macOS-compatible)
- Odoo log path fallback includes `/var/log/odoo19/odoo19-cargo-prd.log`

### Auth flow
- `inject/revoke/status` now use auth strategy (`run_ssh_auto`) instead of password-only
- `auto`, `odoo-check`, `remote-logrotate` execute over selected auth mode

### Notes
- In `auth-mode key` with `--no-inject`, script assumes key is already present on server.
- `sudo` operations still depend on remote sudo policy/passwordless sudo.
