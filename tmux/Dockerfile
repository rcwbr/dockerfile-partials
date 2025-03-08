# Set base_context in the downstream Bake file
# hadolint ignore=DL3006
FROM base_context

# hadolint ignore=SC2034
RUN DEBIAN_FRONTEND=noninteractive \
  && apt-get update \
  && if ! dpkg-query --status tmux ; then \
    apt-get install --allow-unauthenticated --no-install-recommends -y \
      tmux=3.3a* ; \
  fi \
  && apt-get clean \
  && apt-get autoclean \
  && apt-get autoremove \
  && rm -rf /var/cache/debconf \
  && rm -rf /var/lib/apt/lists/*
