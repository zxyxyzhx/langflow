#!/usr/bin/env bash
# 用 pyenv(管版本) + venv(管隔离) + pip(管安装) 搭建 Langflow 后端开发环境。
#
# 这是 `uv sync` 的替代方案：uv.exe 在受 IPGuard 管控的机器上会踩到
# 「python.exe 写入(自动加密) -> uv.exe 读取(不受控,读到密文)」的跨进程加解密边界。
# 换成 pip 之后写入和读取都由 venv 里的 python.exe 完成，不跨进程边界。
#
# 用法：
#   bash scripts/pip-setup.sh                  # 核心包 + 14 个默认 bundle + dev 依赖
#   WITH_OPTIONAL_BUNDLES=1 bash scripts/pip-setup.sh   # 再加上 [bundles] extra 里的可选 bundle
#   PY_VERSION=3.11.3 bash scripts/pip-setup.sh         # 换 Python 版本
#   SKIP_DEV=1 bash scripts/pip-setup.sh                # 不装 dev 依赖组
#
# 装完后：
#   source .venv/Scripts/activate     # Windows (Git Bash)
#   source .venv/bin/activate         # Linux / macOS
set -euo pipefail

PY_VERSION="${PY_VERSION:-3.13.1}"
VENV_DIR="${VENV_DIR:-.venv}"
BASE_EXTRAS="${BASE_EXTRAS:-postgresql}"
WITH_OPTIONAL_BUNDLES="${WITH_OPTIONAL_BUNDLES:-0}"
SKIP_DEV="${SKIP_DEV:-0}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

CONSTRAINTS="scripts/pip-constraints.txt"

# 走环境变量而不是命令行参数：构建隔离(build isolation)会为每个包起一个独立的
# pip 子进程，命令行上的 --retries/--timeout 传不进去，环境变量可以。
# 国内镜像偶发 IncompleteRead，重试次数给足。
export PIP_RETRIES="${PIP_RETRIES:-10}"
export PIP_TIMEOUT="${PIP_TIMEOUT:-60}"

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------- 1. pyenv 管版本
log "pyenv: 准备 Python ${PY_VERSION}"
command -v pyenv >/dev/null || { echo "找不到 pyenv，请先安装 pyenv-win 并加入 PATH" >&2; exit 1; }

if ! pyenv versions --bare | grep -qx "${PY_VERSION}"; then
    echo "本机没有 ${PY_VERSION}，开始安装..."
    pyenv install "${PY_VERSION}"
fi

# 写入 .python-version，让本目录下的 pyenv shim 固定到该版本（该文件已被 .gitignore 忽略）
echo "${PY_VERSION}" > .python-version
pyenv rehash >/dev/null 2>&1 || true

PY_BIN="$(pyenv which python)"
echo "解释器: ${PY_BIN}"
"${PY_BIN}" --version

# ---------------------------------------------------------------- 2. venv 管隔离
log "venv: 创建 ${VENV_DIR}"
if [ -d "${VENV_DIR}" ]; then
    echo "${VENV_DIR} 已存在，复用。要重建请先删除该目录。"
else
    "${PY_BIN}" -m venv "${VENV_DIR}"
fi

if [ -x "${VENV_DIR}/Scripts/python.exe" ]; then
    VENV_PY="${VENV_DIR}/Scripts/python.exe"      # Windows
else
    VENV_PY="${VENV_DIR}/bin/python"              # Linux / macOS
fi

PIP=( "${VENV_PY}" -m pip )

# 这台机器上 pip 的 http-v2 缓存经常写到一半被打断（.tmp 孤儿 + 截断的 .body），
# 之后 pip 会稳定报 IncompleteRead —— 重试和换镜像都没用，因为根本没走网络。
# 装之前先体检一次，装的时候再兜一层：失败就绕开缓存重试。
pip_install() {
    if "${PIP[@]}" install "$@"; then
        return 0
    fi
    log "安装失败，疑似 pip 缓存损坏 -> 清理缓存并绕开缓存重试"
    "${VENV_PY}" scripts/pip-cache-doctor.py --fix || true
    env PIP_NO_CACHE_DIR=1 "${PIP[@]}" install --no-cache-dir "$@"
}

# pip >= 25.1 才支持 `--group`（读 pyproject.toml 的 [dependency-groups]）
log "pip: 升级构建工具链"
"${PIP[@]}" install --upgrade "pip>=25.1" setuptools wheel

log "pip: 体检 HTTP 缓存"
"${VENV_PY}" scripts/pip-cache-doctor.py --fix || true

# 工作区里 18+ 个包全部用 hatchling 构建（bundle 统一钉 1.31.0）。先装一遍，
# 把 wheel 灌进 pip 的本地缓存，后面每个包的构建隔离环境就直接命中缓存，
# 不必重复走网络 —— 既快，也避开镜像抖动。
log "pip: 预热构建后端 hatchling"
pip_install "hatchling==1.31.0"

# ---------------------------------------------------------------- 3. pip 管安装
# 本地工作区包必须全部以 editable 方式放进同一次 pip install，
# 这样 pip 的解析器才会用本地源码满足 `langflow-base~=1.13.0` / `lfx-*` 这类声明，
# 而不是去 PyPI 下已发布的 wheel（那样改本地代码就不生效了）。
# 这一步对应 pyproject.toml 里 [tool.uv.sources] 的 `workspace = true`。
EDITABLES=(
    -e "src/lfx"
    -e "src/backend/base[${BASE_EXTRAS}]"
    -e "src/sdk"
    -e "."
)

# 根 pyproject.toml [project].dependencies 直接要求的 14 个 bundle
for b in ibm docling datastax toolguard openai anthropic azure ollama \
         amazon cohere oracle vllm openai-compatible google; do
    EDITABLES+=( -e "src/bundles/${b}" )
done

# 根 pyproject.toml [project.optional-dependencies].bundles 里的可选 bundle。
# 不含 lfx-bundles 元包 —— 它的 [all-no-torch] extra 会拖进极大的依赖树，按需单独装。
if [ "${WITH_OPTIONAL_BUNDLES}" = "1" ]; then
    for b in arxiv confluent duckduckgo empiriolabs exa firecrawl \
             nextplaid paddle serply valkey; do
        EDITABLES+=( -e "src/bundles/${b}" )
    done
fi

log "pip: 安装工作区包（editable，共 $(( ${#EDITABLES[@]} / 2 )) 个）"
pip_install -c "${CONSTRAINTS}" "${EDITABLES[@]}"

if [ "${SKIP_DEV}" != "1" ]; then
    log "pip: 安装 dev 依赖组"
    pip_install -c "${CONSTRAINTS}" --group dev
fi

# ---------------------------------------------------------------- 4. 收尾检查
log "校验"
"${VENV_PY}" -c "import langflow, lfx; print('langflow', langflow.__file__); print('lfx', lfx.__file__)"
"${PIP[@]}" check || echo "(pip check 有告警，多为 bundle 之间的版本区间提示，通常可忽略)"

if [ ! -f .env ]; then
    log ".env 不存在，从 .env.example 复制一份（后端和 vite 都会读它）"
    cp .env.example .env
fi

cat <<EOF

完成。激活环境：
  source ${VENV_DIR}/Scripts/activate      # Windows (Git Bash)
  source ${VENV_DIR}/bin/activate          # Linux / macOS

之后所有命令去掉 \`uv run\` 前缀直接跑，例如：
  uvicorn --factory langflow.main:create_app --host 0.0.0.0 --port 7860 --reload --env-file .env --loop asyncio
  pytest src/backend/tests/unit/...
  ruff format . && ruff check --fix .
EOF
