#!/bin/zsh
set -euo pipefail

APP_SUPPORT="${WIZARDSCROLL_APP_SUPPORT:-$HOME/Library/Application Support/WizardScroll}"
RUNTIME_DIR="$APP_SUPPORT/runtime"
VENV_DIR="$RUNTIME_DIR/.venv"
TOOLS_DIR="$RUNTIME_DIR/bin"
HF_HOME_DIR="$APP_SUPPORT/Models/huggingface"
MODEL_ID="${1:-moona3k/mlx-qwen3-asr-0.6b-4bit}"
# Bump with every package change. RuntimeLocator.runtimeVersion must match,
# so existing installs upgrade their packages on the next launch.
RUNTIME_VERSION="2"

mkdir -p "$RUNTIME_DIR" "$TOOLS_DIR" "$HF_HOME_DIR"
if [[ "$(/bin/cat "$RUNTIME_DIR/.ready" 2>/dev/null)" != "$RUNTIME_VERSION" || ! -x "$VENV_DIR/bin/python3" ]]; then
/bin/rm -f "$RUNTIME_DIR/.ready"
echo 'WIZARDSCROLL_PROGRESS {"stage":"runtime"}'

if [[ -x "$TOOLS_DIR/uv" ]]; then
    UV_BIN="$TOOLS_DIR/uv"
elif command -v uv >/dev/null 2>&1; then
    UV_BIN="$(command -v uv)"
elif [[ -x "$HOME/.local/bin/uv" ]]; then
    UV_BIN="$HOME/.local/bin/uv"
else
    echo "Downloading the isolated runtime installer…"
    /usr/bin/curl --proto '=https' --tlsv1.2 -LsSf \
        "https://astral.sh/uv/0.12.19/install.sh" \
        | env UV_UNMANAGED_INSTALL="$TOOLS_DIR" /bin/sh
    UV_BIN="$TOOLS_DIR/uv"
fi

export UV_CACHE_DIR="$APP_SUPPORT/cache/uv"
export UV_PYTHON_INSTALL_DIR="$RUNTIME_DIR/python"
echo "Creating an isolated Python environment…"
if [[ ! -x "$VENV_DIR/bin/python3" ]]; then
    "$UV_BIN" venv --python 3.12 "$VENV_DIR"
else
    echo "Reusing the existing isolated environment."
fi

echo "Installing the MLX speech and text runtime…"
"$UV_BIN" pip install --python "$VENV_DIR/bin/python3" "mlx-qwen3-asr==0.4.4" "mlx-lm==0.32.0"
print -r -- "$RUNTIME_VERSION" > "$RUNTIME_DIR/.ready"
fi

echo "Downloading $MODEL_ID…"
# Xet transfers stalled for minutes on some connections; plain HTTPS
# downloads from the Hub stay steady and report progress the same way.
HF_HOME="$HF_HOME_DIR" HF_HUB_DISABLE_XET=1 "$VENV_DIR/bin/python3" -u - "$MODEL_ID" <<'PY'
import json
import sys
import threading
import time
from huggingface_hub import snapshot_download
from tqdm.auto import tqdm


def emit_progress(stage, completed=None, total=None):
    print("WIZARDSCROLL_PROGRESS " + json.dumps({
        "stage": stage, "completed": completed, "total": total
    }), flush=True)


class DownloadProgress(tqdm):
    output_lock = threading.Lock()

    def __init__(self, *args, **kwargs):
        self.progress_name = kwargs.pop("name", "")
        self.last_emission = 0
        # Counting must stay enabled even though this app has no terminal.
        kwargs["disable"] = False
        super().__init__(*args, **kwargs)

    def display(self, *args, **kwargs):
        # The Hub has separate transfer, reconstructed-byte and file-count bars.
        # Only the reconstructed bytes represent the whole model download once.
        if self.unit != "B" or self.progress_name.endswith(".transfer"):
            return
        with self.output_lock:
            now = time.monotonic()
            if now - self.last_emission < 0.2 and self.n != self.total:
                return
            self.last_emission = now
            emit_progress("downloading", max(0, int(self.n)), int(self.total or 0))


emit_progress("downloading")
snapshot_download(repo_id=sys.argv[1], tqdm_class=DownloadProgress)
emit_progress("complete")
PY

echo "Local Qwen runtime is ready."
