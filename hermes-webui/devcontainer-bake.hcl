variable "HERMES_WEBUI_VERSION" {
  default = "v0.52.106"
}

variable "HERMES_WEBUI_SOURCE" {
  default = "https://github.com/nesquena/hermes-webui.git#${HERMES_WEBUI_VERSION}"
}

target "hermes-webui" {
  dockerfile = "hermes-webui/Dockerfile"
  contexts = {
    hermes_webui = "${HERMES_WEBUI_SOURCE}"
  }
}
