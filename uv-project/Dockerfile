ARG UV_PACKAGE_NAME
ARG WORKSPACE="/tmp/${UV_PACKAGE_NAME}"

FROM ghcr.io/astral-sh/uv:0.8.17 AS uv
# hadolint ignore=DL3006
FROM local_context AS local_context


# hadolint ignore=DL3006
FROM base_context AS deps
ARG WORKSPACE

ENV UV_PROJECT_ENVIRONMENT=/usr/local
ENV UV_COMPILE_BYTECODE=1
WORKDIR ${WORKSPACE}

RUN --mount=type=bind,from=uv,source=/uv,target=/bin/uv \
    --mount=type=bind,from=local_context,source=uv.lock,target=uv.lock \
    --mount=type=bind,from=local_context,source=pyproject.toml,target=pyproject.toml \
    uv sync --locked --no-editable --no-install-project


# hadolint ignore=DL3006
FROM deps AS builder

COPY --from=local_context uv.lock uv.lock
COPY --from=local_context pyproject.toml pyproject.toml
COPY --from=local_context src src
RUN --mount=type=bind,from=uv,source=/uv,target=/bin/uv \
    uv build --wheel .


# hadolint ignore=DL3006
FROM deps AS dev
ARG UV_PACKAGE_NAME

RUN --mount=type=bind,from=uv,source=/uv,target=/bin/uv \
    --mount=type=bind,from=local_context,source=uv.lock,target=uv.lock \
    --mount=type=bind,from=local_context,source=pyproject.toml,target=pyproject.toml \
    uv sync --locked --no-editable --no-install-project --extra dev

RUN --mount=type=bind,from=uv,source=/uv,target=/bin/uv \
    --mount=type=bind,from=local_context,source=uv.lock,target=uv.lock \
    --mount=type=bind,from=local_context,source=pyproject.toml,target=pyproject.toml \
    --mount=type=bind,from=local_context,source=src,target=src,rw \
    uv sync --locked --extra dev

RUN --mount=type=bind,source=uv-project/on_create_command,target=/tmp/on_create_command \
    echo '#!/bin/bash' > /opt/devcontainers/on_create_commands/${UV_PACKAGE_NAME} \
    && echo "UV_PACKAGE_NAME=${UV_PACKAGE_NAME}" >> /opt/devcontainers/on_create_commands/${UV_PACKAGE_NAME} \
    && cat /tmp/on_create_command > /opt/devcontainers/on_create_commands/${UV_PACKAGE_NAME}


FROM deps AS release
ARG WORKSPACE
ARG UV_PACKAGE_NAME

RUN --mount=type=bind,from=builder,source=${WORKSPACE}/dist,target=/tmp,rw \
    pip install --no-cache-dir /tmp/${UV_PACKAGE_NAME}-*-none-any.whl
