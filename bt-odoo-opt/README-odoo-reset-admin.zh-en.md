# Odoo Admin Reset Helper / Odoo 管理员密码重置工具

## EN

### What this is
This folder contains a stable helper for resetting an Odoo admin password on a remote host when the only reliable remote entry path is:

```bash
ssh -tt ... 'sudo -S -p "" -iu odoo'
```

The current stable implementation is **expect-driven**. It logs into the remote `odoo` shell first, uploads a temporary script, and executes it there. This avoids fragile `bash -c` / stdin transport edge cases that appeared during testing.

### Stable files
- `reset-odoo-admin-via-stdin.sh` — main user-facing entrypoint
- `odoo-reset-admin.expect` — low-level expect driver used by the main script

### Legacy / experimental case
Older execution-chain experiments are preserved under:
- `experimental/reset-odoo-admin-via-stdin.legacy.sh`
- `experimental/odoo-reset-admin.legacy.expect`

These are kept for debugging/reference only. They are **not** the recommended production path.

### Supported command styles

#### 1) Simple style
```bash
./reset-odoo-admin-via-stdin.sh probe
./reset-odoo-admin-via-stdin.sh reset 'NEW_PASSWORD'
```

#### 2) Parameterized style
```bash
./reset-odoo-admin-via-stdin.sh \
  --target adminfpd@203.150.106.153 \
  --ssh-option='-p 14321' \
  --instance-name odoo19-prd \
  --db v19_production_horizon_06032026 \
  action probe
```

```bash
./reset-odoo-admin-via-stdin.sh \
  --target adminfpd@203.150.106.153 \
  --ssh-option='-p 14321' \
  --instance-name odoo19-prd \
  --db v19_production_horizon_06032026 \
  action reset-admin-pass 'CUSolution03012026@!01'
```

### Design notes
- Uses pinned values when known-good paths are already confirmed
- Prefers the live Odoo venv Python when detectable
- Forces:
  - `PYTHONNOUSERSITE=1`
  - `python -s`
  - `--no-http`
- Keeps output minimal:
  - hides noisy transport details
  - still shows meaningful success messages and real tracebacks

### Requirements
- macOS `security` CLI (for reading sudo password from Keychain)
- `ssh`
- `expect`

### Important note
This helper is designed around a very specific field-tested path. If your remote host uses a different sudo/shell behavior, treat this as a base implementation and adjust conservatively.

---

## 中文

### 这是什么
这个目录里放的是一个**稳定版** Odoo 管理员密码重置工具，适用于那种远端环境里**唯一可靠入口**是下面这条链路的情况：

```bash
ssh -tt ... 'sudo -S -p "" -iu odoo'
```

当前稳定版采用 **expect 驱动**：先进入远端 `odoo` shell，再上传一个临时脚本到远端执行。这样可以避开之前测试中遇到的 `bash -c`、stdin 传输、交互 shell 吃输入等各种不稳定问题。

### 稳定版文件
- `reset-odoo-admin-via-stdin.sh` — 主入口脚本
- `odoo-reset-admin.expect` — expect 驱动层

### 旧执行链路 / 实验 case
旧版本和实验链路保存在：
- `experimental/reset-odoo-admin-via-stdin.legacy.sh`
- `experimental/odoo-reset-admin.legacy.expect`

这些文件只是**留档和排障参考**，不建议继续作为生产主路径使用。

### 支持的命令格式

#### 1）简写风格
```bash
./reset-odoo-admin-via-stdin.sh probe
./reset-odoo-admin-via-stdin.sh reset '新密码'
```

#### 2）参数化风格
```bash
./reset-odoo-admin-via-stdin.sh \
  --target adminfpd@203.150.106.153 \
  --ssh-option='-p 14321' \
  --instance-name odoo19-prd \
  --db v19_production_horizon_06032026 \
  action probe
```

```bash
./reset-odoo-admin-via-stdin.sh \
  --target adminfpd@203.150.106.153 \
  --ssh-option='-p 14321' \
  --instance-name odoo19-prd \
  --db v19_production_horizon_06032026 \
  action reset-admin-pass 'CUSolution03012026@!01'
```

### 设计说明
- 如果已经确认过稳定路径，会优先使用固定值
- 如果能从 live process 里探测到 Odoo 的 venv Python，则优先使用它
- 强制加入：
  - `PYTHONNOUSERSITE=1`
  - `python -s`
  - `--no-http`
- 输出尽量收敛：
  - 隐去无意义的传输细节
  - 保留真正有用的成功提示和 traceback

### 依赖
- macOS `security` 命令（从 Keychain 读取 sudo 密码）
- `ssh`
- `expect`

### 注意
这个工具是基于一条已经在现场验证过的特殊执行链路封出来的。如果你的远端 sudo / shell 行为不同，请把它当成基础模板，小步调整，不要大改。
