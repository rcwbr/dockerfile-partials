# hadolint ignore=DL3006
FROM base_context AS base

WORKDIR /tmp/hermes_webui
COPY --from=hermes_webui . /opt/devcontainers/hermes_webui

# ── Health check ────────────────────────────────────────────────────────────
# Probes /health on the configured port inside the container.
HEALTHCHECK --interval=30s --timeout=8s --start-period=10s --retries=3 \
  CMD bash /opt/devcontainers/hermes_webui/scripts/lib/health_probe.sh localhost ${HERMES_WEBUI_PORT} /health 2 >/dev/null || exit 1

COPY common/on_create_command /opt/devcontainers/on_create_command
COPY hermes-webui/on_create_command /opt/devcontainers/on_create_commands/hermes-webui
