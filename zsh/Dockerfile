# hadolint ignore=DL3006
FROM pyenv_context AS pyenv

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
  && if ! dpkg-query --status fzf ; then \
    apt-get install --allow-unauthenticated --no-install-recommends -y \
      fzf=0.38.0* ; \
  fi \
  && apt-get clean \
  && apt-get autoclean \
  && apt-get autoremove \
  && rm -rf /var/cache/debconf \
  && rm -rf /var/lib/apt/lists/*

ARG THEFUCK_VENV=/opt/devcontainers/virtualenvs/thefuck
ENV THEFUCK_VENV=${THEFUCK_VENV}
COPY --from=pyenv /opt/devcontainers/pyenv /opt/devcontainers/pyenv
COPY --from=pyenv ${THEFUCK_VENV} ${THEFUCK_VENV}
SHELL [ "/bin/bash", "-c" ]
# hadolint ignore=SC1091
RUN \
  source "${THEFUCK_VENV}/bin/activate" \
  && pip install --no-cache-dir thefuck==3.32 \
  && echo "PATH=\"${THEFUCK_VENV}/bin:\$PATH\" \"${THEFUCK_VENV}/bin/thefuck\" \"\$@\"" > /usr/local/bin/thefuck && chmod a+x /usr/local/bin/thefuck

# Include Oh My Zsh initialization in config for devcontainers onCreateCommand
COPY common/on_create_command /opt/devcontainers/on_create_command
COPY zsh/on_create_command /opt/devcontainers/on_create_commands/zsh
