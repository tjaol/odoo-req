# bt-odoo-ops bundle - Ubuntu 22.04.5 LTS

## 1) System deps
```bash
sudo apt update
sudo apt install -y python3 python3-venv python3-pip rsync curl jq openssh-client
```

## 2) Enter project dir
```bash
cd bt-odoo-ops-ubuntu2204-bundle
```

## 3) Init runtime env (venv + deps)
```bash
bash ./bootstrap_ubuntu2204.sh
source .venv/bin/activate
```

## 4) Quick checks
```bash
python --version
pip --version
bash -n ./ssh_key_inject.sh
bash -n ./deploy_log_policy_once_password.sh
bash -n ./deploy_log_policy_key_only.sh
```

## Notes
- This bundle intentionally excludes secrets/private files.
- If needed, create your own `.env` locally.
- For key-based deployments, ensure your private key is in `~/.ssh/` on the target machine.
