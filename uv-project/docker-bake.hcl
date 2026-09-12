target "uv-project" {
  dockerfile = "uv-project/Dockerfile"
  context    = "."
  contexts = {
    local_context = BAKE_CMD_CONTEXT
  }
  target = "release"
}
