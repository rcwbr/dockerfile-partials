target "default" {
  dockerfile = "uv-project/Dockerfile"
  context    = "."
  contexts = {
    local_context = BAKE_CMD_CONTEXT
  }
  target = "release"
}
