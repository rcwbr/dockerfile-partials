"""Apply cleanup from mounted gitignore-style target files.

Run inside the Dockerfile RUN layer after hermes-agent is installed.
Uses the agent venv's python (which has pathspec already installed).

Discovers all cleanup files via pathlib.Path.rglob, derives the
base directory from each file's parent path, loads gitignore-style
patterns via pathspec.GitIgnoreSpec.from_lines(f), and removes matched
entries in two phases (files first, then dirs deepest-first) using
match_tree_entries with follow_links=False to avoid venv lib64 symlink
duplicates.
"""
import os
import shutil
from pathlib import Path

import pathspec

CT = Path('/tmp/cleanup-targets')

for cleanup_file in CT.rglob('cleanup'):
    base = '/' + cleanup_file.parent.relative_to(CT).as_posix()
    with open(cleanup_file) as f:
        spec = pathspec.GitIgnoreSpec.from_lines(f)
    entries = list(spec.match_tree_entries(base, follow_links=False))
    # Phase 1: delete files
    for entry in entries:
        if entry.is_file():
            os.remove(os.path.join(base, entry.path))
    # Phase 2: delete directories (deepest first) so we don't try to
    # remove a parent before its children are gone.
    for entry in sorted(
        (e for e in entries if e.is_dir()),
        key=lambda e: len(e.path),
        reverse=True,
    ):
        shutil.rmtree(os.path.join(base, entry.path), ignore_errors=True)
