# hadolint ignore=DL3006
FROM base_context AS base

ENV DEVCONTAINER_HERMES_WEBUI=/opt/devcontainers/hermes-webui

COPY --from=hermes_webui . $DEVCONTAINER_HERMES_WEBUI
RUN python -m venv "$DEVCONTAINER_PRE_COMMIT/venv" \
  && source "$DEVCONTAINER_PRE_COMMIT/venv/bin/activate" \
  && python "$DEVCONTAINER_HERMES_WEBUI/bootstrap.py" --no-browser --foreground

# ── Health check ────────────────────────────────────────────────────────────
# Probes /health on the configured port inside the container.
HEALTHCHECK --interval=30s --timeout=8s --start-period=10s --retries=3 \
  CMD bash $DEVCONTAINER_HERMES_WEBUI/scripts/lib/health_probe.sh localhost ${HERMES_WEBUI_PORT} /health 2 >/dev/null || exit 1

COPY common/on_create_command /opt/devcontainers/on_create_command
COPY hermes-webui/on_create_command /opt/devcontainers/on_create_commands/hermes-webui
