// This image is used only to analyze image space efficiency in the CI pipeline

variable "devcontainer_layers" {
  default = [
    "docker-client",
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

// Base the pre-commit caller on the tool layer for analysis
target "pre-commit" {
  contexts = {
    base_context = "target:pre-commit-tool-image"
  }
}
