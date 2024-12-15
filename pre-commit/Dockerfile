# Set base_context in the downstream Bake file
FROM base_context
ARG USER=root
USER root
# Install git to spoof pre-commit environment
RUN DEBIAN_FRONTEND=noninteractive \
  apt-get update \
  && apt-get install --allow-unauthenticated --no-install-recommends -y \
    git \
  && rm -rf /var/lib/apt/lists/*
COPY pre-commit /usr/local/bin
# Assume root role for installs
USER ${USER}
SHELL [ "/bin/bash", "-c" ]
# Create a temp repo and install the hooks from the config
# Load the config file from the downstream context
RUN \
  --mount=type=bind,from=local_context,source=.pre-commit-config.yaml,target=/tmp/.pre-commit-config.yaml \
  python -m venv $HOME/pre-commit-venv \
  && source $HOME/pre-commit-venv/bin/activate \
  && mkdir $HOME/tmp_repo \
  && cd $HOME/tmp_repo \
  && cp /tmp/.pre-commit-config.yaml . \
  && git init . \
  && pip install pre-commit \
  && pre-commit install-hooks \
  && cd \
  && rm -rf $HOME/tmp_repo
