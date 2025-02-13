# hadolint ignore=DL3006
FROM common_context AS common_context

# hadolint ignore=DL3006
FROM base_context
ARG USER=root

USER root
RUN DEBIAN_FRONTEND=noninteractive \
  apt-get update \
  && if ! dpkg-query --status locales ; then \
    apt-get install --allow-unauthenticated --no-install-recommends -y \
      locales=2.36* ; \
  fi \
  && echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen \
  && locale-gen \
  && update-locale LANG=en_US.UTF-8 \
  && apt-get clean \
  && apt-get autoclean \
  && apt-get autoremove \
  && rm -rf /var/cache/debconf \
  && rm -rf /var/lib/apt/lists/* \
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

USER $USER
ARG DEVCONTAINER_PRE_COMMIT_IMAGE

# Burn the pre-commit image ref into the image for use in the caller script
ENV DEVCONTAINER_PRE_COMMIT=/opt/devcontainers/pre-commit
ENV DEVCONTAINER_PRE_COMMIT_IMAGE=$DEVCONTAINER_PRE_COMMIT_IMAGE

# Configure pre-commit caller executable
COPY pre-commit/pre-commit /usr/local/bin

# Include pre-commit initialization in config for devcontainers onCreateCommand, postCreateCommand
COPY --from=common_context on_create_command /opt/devcontainers/on_create_command
COPY pre-commit/on_create_command /opt/devcontainers/on_create_command
