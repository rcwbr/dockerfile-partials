# hadolint ignore=DL3006
FROM docker_image AS docker_image

# Set base_context in the downstream Bake file
# hadolint ignore=DL3006
FROM base_context

# hadolint ignore=DL3002
USER root
COPY --from=docker_image /usr/local/bin/docker /usr/local/bin/docker
COPY --from=docker_image /usr/local/libexec/docker/cli-plugins/docker-buildx /usr/local/libexec/docker/cli-plugins/docker-buildx
COPY --from=docker_image /usr/local/libexec/docker/cli-plugins/docker-compose /usr/local/libexec/docker/cli-plugins/docker-compose
ARG DOCKER_GID=800
RUN groupadd --gid $DOCKER_GID docker
