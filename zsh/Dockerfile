# Set base_context in the downstream Bake file
# hadolint ignore=DL3006
FROM base_context AS base

# hadolint ignore=SC2034
RUN DEBIAN_FRONTEND=noninteractive \
  && apt-get update \
  && if ! dpkg-query --status zsh ; then \
    apt-get install --allow-unauthenticated --no-install-recommends -y \
      zsh=5* ; \
  fi \
  && if ! dpkg-query --status autojump ; then \
    apt-get install --allow-unauthenticated --no-install-recommends -y \
      autojump=22.5.1* ; \
  fi \
  && apt-get clean \
  && apt-get autoclean \
  && apt-get autoremove \
  && rm -rf /var/cache/debconf \
  && rm -rf /var/lib/apt/lists/*


# Include Oh My Zsh initialization in config for devcontainers onCreateCommand
COPY common/on_create_command /opt/devcontainers/on_create_command
COPY zsh/on_create_command /opt/devcontainers/on_create_commands/zsh
