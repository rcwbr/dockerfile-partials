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
bs.ensure_python_has_webui_deps(bs.discover_launcher_python(agent_dir), agent_dir)
