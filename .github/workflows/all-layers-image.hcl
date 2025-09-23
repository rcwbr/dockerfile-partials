// This image is used only to analyze image space efficiency in the CI pipeline

variable "devcontainer_layers" {
  default = [
    "docker-client",
    "pyenv",
    "zsh-base",
    "zsh-thefuck-pyenv",
    "zsh",
    "tmux",
    "uv-project",
    "useradd",
    "pre-commit-base",
    "pre-commit-tool-image",
    "pre-commit"
  ]
}

target "docker-client" {
  contexts = {
    base_context = "docker-image://python:3.12.4"
  }
}


target "uv-project" {
  contexts = {
    local_context = "uv-project/dummy_pkg"
  }
  args = {
    UV_PACKAGE_NAME = "dummy_pkg"
  }
}

// Base the pre-commit caller on the tool layer for analysis
target "pre-commit" {
  contexts = {
    base_context = "target:pre-commit-tool-image"
  }
}
