# odoo-req

SSH automation toolkit for Odoo 19 server management.

## Features

- **SSH key injection / revocation** — securely inject your public key, run tasks, then remove it
- **Odoo 19 dependency check** — auto-detect and install missing Python packages + C libs
- **Remote log rotation** — detect Odoo log path and configure logrotate on the remote server
- **Auth modes** — supports `password`, `key`, or `auto` authentication
- **No-inject mode** — skip key lifecycle when server already trusts your key
- **Odoo admin reset helper** — expect-driven remote helper for admin password reset (see `README-odoo-reset-admin.zh-en.md`)

## Usage

### Full setup (log rotation + dependency check)
```bash
./ssh_key_inject.sh \
  --host 10.0.0.1 --port 14321 --user adminfpd \
  --auth-mode key \
  --no-inject \
  --key ~/.ssh/id_ed25519 \
  --action odoo-setup \
  --rotate-days 30
```

### Password-based authentication
```bash
./ssh_key_inject.sh \
  --host 10.0.0.1 --port 14321 --user adminfpd \
  --auth-mode password \
  --password 'yourpassword' \
  --key ~/.ssh/id_ed25519 \
  --pubkey-file ~/.ssh/id_ed25519.pub \
  --action odoo-setup \
  --rotate-days 30
```

### Dependency check only
```bash
./ssh_key_inject.sh \
  --host 10.0.0.1 --port 14321 --user adminfpd \
  --auth-mode key --no-inject \
  --key ~/.ssh/id_ed25519 \
  --action odoo-check
```

### Remote log rotation only
```bash
./ssh_key_inject.sh \
  --host 10.0.0.1 --port 14321 --user adminfpd \
  --auth-mode key --no-inject \
  --key ~/.ssh/id_ed25519 \
  --action remote-logrotate \
  --rotate-days 30
```

### Inject / revoke key manually
```bash
./ssh_key_inject.sh --host 10.0.0.1 --password 'pass' --action inject
./ssh_key_inject.sh --host 10.0.0.1 --password 'pass' --action revoke
```

## Options

| Option | Default | Description |
|---|---|---|
| `--host` | required | Remote server IP |
| `--port` | 22 | SSH port |
| `--user` | root | SSH username |
| `--password` | — | SSH password (required for password mode) |
| `--key` | — | Private key path |
| `--pubkey-file` | — | Public key path (auto-detected if omitted) |
| `--auth-mode` | auto | `auto` / `password` / `key` |
| `--no-inject` | off | Skip inject/revoke (use pre-installed key) |
| `--action` | required | `inject` / `revoke` / `status` / `auto` / `odoo-check` / `odoo-setup` / `remote-logrotate` / `logrotate` |
| `--rotate-days` | 30 | Days to retain logs |
| `--rotate-size` | — | Rotate when log exceeds size (e.g. `100M`) |
| `--rotate-count` | unlimited | Max backup file count |
| `--run-cmd` | — | Remote command (for `auto` action) |

## Requirements

- `sshpass` (for password auth): `brew install hudochenkov/sshpass/sshpass`
- `gh` CLI (optional, for GitHub operations)

## Notes

- Log rotation uses `copytruncate` so Odoo does not need to be restarted.
- Sudo is required on the remote server to write `/etc/logrotate.d/odoo`.
- If sudo is unavailable, the script falls back to direct log truncation.
