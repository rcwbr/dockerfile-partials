target "uv-project" {
  dockerfile = "uv-project/Dockerfile"
  contexts = {
    local_context = BAKE_CMD_CONTEXT
  }
  target = "dev"
}
