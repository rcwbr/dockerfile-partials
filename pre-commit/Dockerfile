# Set base_context in the downstream Bake file
# hadolint ignore=DL3006
FROM base_context
# Act as root in this image
# hadolint ignore=DL3002
USER root
# Install git (if not already available) to spoof pre-commit environment
SHELL [ "/bin/bash", "-c" ]
RUN DEBIAN_FRONTEND=noninteractive \
  apt-get update \
  && if ! dpkg-query --status git ; then \
    apt-get install --allow-unauthenticated --no-install-recommends -y \
      git=1:2.39.5* ; \
  fi \
  && apt-get clean \
  && apt-get autoclean \
  && apt-get autoremove \
  && rm -rf /var/cache/debconf \
  && rm -rf /var/lib/apt/lists/*

# Prep folder for pre-commit
ENV DEVCONTAINER_PRE_COMMIT=/opt/devcontainers/pre-commit
# Apply wrapper executable
# hadolint ignore=SC2016
RUN echo 'PATH="$DEVCONTAINER_PRE_COMMIT/venv/bin:$DEVCONTAINER_PRE_COMMIT/node_venv/bin:$PATH" "$DEVCONTAINER_PRE_COMMIT/venv/bin/pre-commit" "$@"' > /usr/local/bin/pre-commit && chmod a+x /usr/local/bin/pre-commit
# Create a temp repo and install the hooks from the config
# Load the config file from the downstream context
# hadolint ignore=DL3003,SC1091
RUN \
  --mount=type=bind,from=local_context,source=.pre-commit-config.yaml,target=/tmp/.pre-commit-config.yaml \
  mkdir -p "$DEVCONTAINER_PRE_COMMIT" \
  && python -m venv "$DEVCONTAINER_PRE_COMMIT/venv" \
  && source "$DEVCONTAINER_PRE_COMMIT/venv/bin/activate" \
  && pip install --no-cache-dir nodeenv==1.9.1 \
  && nodeenv "$DEVCONTAINER_PRE_COMMIT/node_venv" \
  && source "$DEVCONTAINER_PRE_COMMIT/node_venv/bin/activate" \
  && mkdir "$DEVCONTAINER_PRE_COMMIT/tmp_repo" \
  && cd "$DEVCONTAINER_PRE_COMMIT/tmp_repo" \
  && cp /tmp/.pre-commit-config.yaml . \
  && git init . \
  && git add .pre-commit-config.yaml \
  && git config --global user.email "you@example.com" \
  && git config --global user.name "Your Name" \
  && git commit -m "chore: trigger commit to install hooks" \
  && pip install --no-cache-dir pre-commit==4.0.1 \
  && pre-commit install-hooks \
  && cd "$DEVCONTAINER_PRE_COMMIT" \
  && rm -rf "$DEVCONTAINER_PRE_COMMIT/tmp_repo"
