variable "devcontainer_layers" {
  default = [
    "docker-client",
    "zsh-base",
    "zsh-thefuck-pyenv",
    "zsh",
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

// Skip useradd layer for pre-commit tool image to maximize caching
target "pre-commit-tool-image" {
  contexts = {
    base_context = "target:docker-client"
  }
}
