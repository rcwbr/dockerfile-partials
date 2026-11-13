# hadolint ignore=DL3006
FROM hermes_webui AS hermes_webui

# hadolint ignore=DL3006
FROM base_context AS base

ENV DEVCONTAINER_HERMES_WEBUI=/opt/devcontainers/hermes-webui

WORKDIR /opt/devcontainers/hermes-webui
COPY --from=hermes_webui . $DEVCONTAINER_HERMES_WEBUI

ENV HERMES_WEBUI_HOST=0.0.0.0
ENV HERMES_WEBUI_PORT=8787
ENV HERMES_AGENT_VERSION_TAG=v0.23.0
ENV HERMES_HOME=/root/.hermes
# Install Hermes Agent, bootstrap, then clean up — all in a single RUN layer
# so removed files don't persist as Docker layers.
SHELL ["/bin/bash", "-eo", "pipefail", "-c"]
# hadolint ignore=SC1091
RUN --mount=type=bind,source=hermes-webui/cleanup-targets,target=/tmp/cleanup-targets \
    --mount=type=bind,source=hermes-webui/scripts,target=/tmp/scripts \
    <<EOF
# Install hermes-agent with minimal flags
curl --retry 3 --retry-delay 5 --retry-max-time 60 -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/${HERMES_AGENT_VERSION_TAG}/scripts/install.sh | bash -s -- --skip-browser --skip-setup --non-interactive --branch "${HERMES_AGENT_VERSION_TAG}"

AGENT_VENV_PYTHON="$(command -v python3)"

# Install faster-whisper (voice/STT) so that local speech-to-text is
# available without a lazy first-use install. The voice extra pins match
# lazy_deps.LAZY_DEPS["stt.faster_whisper"].
# install.sh v0.23.0 stages uv under $HERMES_HOME/tools/uv-*/uv.
uv_bin=""
for _candidate in "$HERMES_HOME/tools/uv-"*/uv "$(command -v uv 2>/dev/null || true)"; do
  if [ -x "$_candidate" ]; then uv_bin="$_candidate"; break; fi
done
if [ -n "$uv_bin" ]; then
  "$uv_bin" pip install --python "$AGENT_VENV_PYTHON" \
    "faster-whisper==1.2.1" "sounddevice==0.5.5" "numpy==2.4.3"
else
  echo "WARNING: uv not found — falling back to pip for faster-whisper install" >&2
  python3 -m pip install --break-system-packages --no-cache-dir \
    "faster-whisper==1.2.1" "sounddevice==0.5.5" "numpy==2.4.3" || \
  echo "WARNING: pip install of faster-whisper also failed — STT will fall back to lazy installation on first use" >&2
fi

# Skip bootstrap_webui.py — no single Python in the image satisfies its
# _python_can_run_webui_and_agent() check (needs both `run_agent` and `yaml`).
rm -rf "$DEVCONTAINER_HERMES_WEBUI/venv"

# Install webui requirements into system python3 (cleanup.py needs pathspec).
python3 -m pip install --break-system-packages --quiet --no-cache-dir pyyaml==6.0.3 pathspec==0.12.1 2>/dev/null || true

"$AGENT_VENV_PYTHON" /tmp/scripts/cleanup.py
EOF

COPY common/post_start_command /opt/devcontainers/post_start_command
COPY hermes-webui/post_start_command /opt/devcontainers/post_start_commands/hermes-webui
COPY hermes-webui/scripts /opt/devcontainers/hermes-webui/scripts
