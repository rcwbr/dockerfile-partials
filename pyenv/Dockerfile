ARG VIRTUALENV_NAME=venv
ARG VIRTUALENV_PATH=/opt/devcontainers/virtualenvs/"$VIRTUALENV_NAME"
ARG PYENV_ROOT="/opt/devcontainers/pyenv"
ARG USER=root


# Set base_context in the downstream Bake file
# hadolint ignore=DL3006
FROM base_context AS pyenv
ARG PYENV_ROOT
ARG VIRTUALENV_PATH
ARG PYTHON_VERSION=3.12.4

# hadolint ignore=DL3002
USER root
SHELL [ "/bin/bash", "-o", "pipefail", "-c" ]
  # Instructions: curl -fsSL https://pyenv.run | bash
  # Using locked ref for stability
RUN \
  curl -fsSL https://raw.githubusercontent.com/pyenv/pyenv-installer/86a08ac9e38ec3a267e4b5c758891caf1233a2e4/bin/pyenv-installer | bash \
  && "$PYENV_ROOT/bin/pyenv" install "${PYTHON_VERSION}" && "$PYENV_ROOT/bin/pyenv" global "${PYTHON_VERSION}" \
  && pip install --no-cache-dir virtualenv==20.29.2 \
  && virtualenv \
    --python "${PYENV_ROOT}/versions/${PYTHON_VERSION}/bin/python" \
    --always-copy \
    "$VIRTUALENV_PATH" \
  && chmod -R a+r "${PYENV_ROOT}" \
  && chmod -R a+x "${PYENV_ROOT}/bin" \
  && chmod -R a+r "${VIRTUALENV_PATH}" \
  && chmod -R a+x "${VIRTUALENV_PATH}/bin"


# hadolint ignore=DL3006
FROM base_context AS virtualenv
ARG PYENV_ROOT
ARG VIRTUALENV_PATH
ENV PATH="${VIRTUALENV_PATH}:$PATH"
COPY --from=pyenv ${PYENV_ROOT} ${PYENV_ROOT}
COPY --from=pyenv ${VIRTUALENV_PATH} ${VIRTUALENV_PATH}
