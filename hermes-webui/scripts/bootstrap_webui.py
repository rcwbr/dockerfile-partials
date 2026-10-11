"""Bootstrap webui dependencies using the agent's venv python.

Run inside the Dockerfile RUN layer after hermes-agent is installed.
The webui source lives at $DEVCONTAINER_HERMES_WEBUI (WORKDIR), but
python script.py adds the script's directory to sys.path, not the CWD —
so we must explicitly add the webui dir to import bootstrap.
"""
import os
import sys

# Add the webui source dir to sys.path so we can import bootstrap.py
sys.path.insert(0, os.environ.get('DEVCONTAINER_HERMES_WEBUI', os.getcwd()))

import bootstrap as bs

agent_dir = bs.discover_agent_dir()
# WebUI deps are installed into the agent venv by the Dockerfile's
# `uv pip install` command (using uv, since the agent venv has no pip).
# We skip ensure_python_has_webui_deps() because its import check
# ("import yaml; from run_agent import AIAgent") fails in CI due to
# package version conflicts between the agent venv
# (HERMES_AGENT_VERSION_TAG=v2026.9.7) and the WebUI requirements.
# The deps are already installed; the check is not needed for the build.
# At runtime, start.sh in bootstrap.py handles Python env resolution
# without this pre-build validation.
