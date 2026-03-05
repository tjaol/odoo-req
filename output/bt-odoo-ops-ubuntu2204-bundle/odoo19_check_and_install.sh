#!/usr/bin/env bash
# odoo19_check_and_install.sh
# 功能：检测 Odoo 19 requirements.txt 中的 Python 包是否已安装，缺少的自动补装
# 用法：直接在目标服务器上以 root 执行，或通过 ssh_key_inject.sh --action auto 调用

set -euo pipefail

REQUIREMENTS_URL="https://raw.githubusercontent.com/odoo/odoo/refs/heads/19.0/requirements.txt"
TMP_REQ="/tmp/odoo19_requirements.txt"
LOG_FILE="/tmp/odoo19_check_$(date +%Y%m%d_%H%M%S).log"

echo "============================================"
echo " Odoo 19 Library 检测 & 补装脚本"
echo " $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================"
echo ""

# 检测 Python 环境
detect_python() {
  # 优先找 Odoo 的 venv
  for candidate in \
    /opt/odoo/venv/bin/python3 \
    /opt/odoo/.venv/bin/python3 \
    /home/odoo/venv/bin/python3 \
    /home/odoo/.venv/bin/python3 \
    /usr/local/lib/python3*/dist-packages/../../../bin/python3 \
    $(which python3 2>/dev/null || true); do
    if [ -f "$candidate" ]; then
      echo "$candidate"
      return
    fi
  done
  # 回退到系统 python3
  which python3
}

detect_pip() {
  local py="$1"
  local pip_candidate="${py%python3}pip3"
  if [ -f "$pip_candidate" ]; then
    echo "$pip_candidate"
  elif command -v pip3 &>/dev/null; then
    which pip3
  else
    echo "$py -m pip"
  fi
}

PYTHON=$(detect_python)
PIP=$(detect_pip "$PYTHON")
PY_VERSION=$($PYTHON -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")

echo "[env] Python: $PYTHON ($PY_VERSION)"
echo "[env] Pip:    $PIP"
echo "[env] Log:    $LOG_FILE"
echo ""

# 下载 requirements.txt
echo "[step 1/3] 下载 Odoo 19 requirements.txt..."
if command -v curl &>/dev/null; then
  curl -fsSL "$REQUIREMENTS_URL" -o "$TMP_REQ"
elif command -v wget &>/dev/null; then
  wget -q "$REQUIREMENTS_URL" -O "$TMP_REQ"
else
  echo "ERROR: curl 和 wget 都不可用，无法下载 requirements.txt"
  exit 1
fi
echo "[step 1/3] 下载完成 ($(wc -l < "$TMP_REQ") 行)"
echo ""

# 解析出 package 名（忽略注释、条件标记、平台限制）
parse_packages() {
  # 提取 package 名（去掉版本号、条件、注释）
  python3 -c "
import re, sys
pkgs = []
for line in open('$TMP_REQ'):
    line = line.strip()
    if not line or line.startswith('#'):
        continue
    # 去掉行内注释
    line = line.split('#')[0].strip()
    # 处理条件 marker（; 之后）
    name_part = line.split(';')[0].strip()
    # 去掉版本限制
    pkg = re.split(r'[>=<!~\[]', name_part)[0].strip()
    if pkg:
        pkgs.append(pkg.lower())
# 去重
seen = set()
for p in pkgs:
    if p not in seen:
        seen.add(p)
        print(p)
"
}

echo "[step 2/3] 检测已安装状态..."
echo ""

MISSING=()
INSTALLED=()

while IFS= read -r pkg; do
  [ -z "$pkg" ] && continue
  # 跳过平台专属包
  [[ "$pkg" == "pypiwin32" ]] && continue

  if $PYTHON -c "import importlib; importlib.import_module('$(echo $pkg | tr '-' '_')')" 2>/dev/null; then
    INSTALLED+=("$pkg")
    echo "  ✅ $pkg"
  else
    # 二次验证：用 pip show
    if $PIP show "$pkg" &>/dev/null 2>&1; then
      INSTALLED+=("$pkg")
      echo "  ✅ $pkg"
    else
      MISSING+=("$pkg")
      echo "  ❌ $pkg (缺失)"
    fi
  fi
done < <(parse_packages)

echo ""
echo "============================================"
echo " 检测结果：已安装 ${#INSTALLED[@]} 个，缺失 ${#MISSING[@]} 个"
echo "============================================"

if [ ${#MISSING[@]} -eq 0 ]; then
  echo ""
  echo "✅ 所有 Odoo 19 依赖已正确安装，无需补装。"
  exit 0
fi

echo ""
echo "缺失的包："
for pkg in "${MISSING[@]}"; do
  echo "  - $pkg"
done

echo ""
echo "[step 3/3] 开始补装缺失的包..."
echo ""

FAILED=()
for pkg in "${MISSING[@]}"; do
  echo -n "  安装 $pkg ... "
  if $PIP install "$pkg" >> "$LOG_FILE" 2>&1; then
    echo "✅"
  else
    # 尝试从 apt 安装（Ubuntu/Debian）
    apt_pkg="python3-$(echo $pkg | tr '[:upper:]' '[:lower:]' | tr '_' '-')"
    if apt-get install -y "$apt_pkg" >> "$LOG_FILE" 2>&1; then
      echo "✅ (via apt: $apt_pkg)"
    else
      echo "❌ 失败"
      FAILED+=("$pkg")
    fi
  fi
done

echo ""
echo "============================================"
echo " 补装完成"
echo "============================================"

if [ ${#FAILED[@]} -gt 0 ]; then
  echo ""
  echo "⚠️  以下包安装失败，需要手动处理："
  for pkg in "${FAILED[@]}"; do
    echo "  - $pkg"
  done
  echo ""
  echo "详细日志：$LOG_FILE"
  exit 1
else
  echo ""
  echo "✅ 所有缺失包补装成功！"
  echo "详细日志：$LOG_FILE"
fi
