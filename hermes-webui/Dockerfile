# hadolint ignore=DL3006
FROM hermes_webui AS hermes_webui

# hadolint ignore=DL3006
FROM base_context AS base

ENV DEVCONTAINER_HERMES_WEBUI=/opt/devcontainers/hermes-webui

WORKDIR /opt/devcontainers/hermes-webui
COPY --from=hermes_webui . $DEVCONTAINER_HERMES_WEBUI

ENV HERMES_WEBUI_HOST=0.0.0.0
ENV HERMES_WEBUI_PORT=8787
# Install Hermes Agent, bootstrap, then clean up — all in a single RUN layer
# so removed files don't persist as Docker layers.
SHELL ["/bin/bash", "-eo", "pipefail", "-c"]
# hadolint ignore=SC1091
RUN --mount=type=bind,source=hermes-webui/cleanup-targets,target=/tmp/cleanup-targets \
    --mount=type=bind,source=hermes-webui/scripts,target=/tmp/scripts \
    <<EOF
# Install hermes-agent with minimal flags
curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/v2026.8.3/scripts/install.sh | bash -s -- --no-skills --skip-browser --skip-setup --non-interactive

# Install faster-whisper (voice/STT) into the agent venv so that local
# speech-to-text is available without a lazy first-use install.
# The voice extra pins match lazy_deps.LAZY_DEPS["stt.faster_whisper"].
# uv is installed by install.sh at $HERMES_HOME/bin/uv (default: /root/.hermes/bin/uv).
uv_bin="${HERMES_HOME:-/root/.hermes}/bin/uv"
[ -x "$uv_bin" ] || uv_bin="$(command -v uv 2>/dev/null || true)"
if [ -x "$uv_bin" ]; then
  "$uv_bin" pip install --python /usr/local/lib/hermes-agent/venv/bin/python \
    "faster-whisper==1.2.1" "sounddevice==0.5.5" "numpy==2.4.3"
else
  echo "WARNING: uv not found — skipping faster-whisper install" >&2
fi

# Bootstrap webui dependencies using the agent's venv python
python -m venv "$DEVCONTAINER_HERMES_WEBUI/venv"
. "$DEVCONTAINER_HERMES_WEBUI/venv/bin/activate"
touch __init__.py
python /tmp/scripts/bootstrap_webui.py

rm -rf "$DEVCONTAINER_HERMES_WEBUI/venv"

/usr/local/lib/hermes-agent/venv/bin/python3 /tmp/scripts/cleanup.py
EOF

COPY common/post_start_command /opt/devcontainers/post_start_command
COPY hermes-webui/post_start_command /opt/devcontainers/post_start_commands/hermes-webui
