// This file prepares only basic target configurations, handling the default base_contexts and output.
// All other config for a target must be overridden by accompanying bake files.
// It also configures a default group with each target listed.

variable "DEVCONTAINER_CACHE_FROMS" {
  default = ""
}
variable "DEVCONTAINER_CACHE_TOS" {
  default = ""
}
variable "DEVCONTAINER_OUTPUTS" {
  default = ""
}

target "layer" {
  name = "${layer.name}"
  matrix = {
    layer = [
      for index, input_layer in devcontainer_layers : {
        name  = input_layer,
        index = index
      }
    ]
  }

  // Apply the contexts from options and context
  contexts = merge(
    {
      // Establish default base_context from layer order
      base_context = (
        // A default base_context can be inferred only for the second layer and later
        layer.index >= 1
        ? "target:${element(devcontainer_layers, layer.index - 1)}"
        : "no_base_context_provided"
      )
    },
    {
      // Directly depend on each previous layer as workaround for https://github.com/docker/buildx/issues/414
      for dep_index, dep_layer in devcontainer_layers :
      "dep_${dep_layer}" => "target:${dep_layer}"
      if dep_index < layer.index
    }
  )

  // Apply cache args from the devcontainer context
  cache-from = [
    for cache_from in split(" ", trimspace("${DEVCONTAINER_CACHE_FROMS}")) :
    "${cache_from}-${layer.name}"
  ]
  cache-to = [
    for cache_to in split(" ", trimspace("${DEVCONTAINER_CACHE_TOS}")) :
    "${cache_to}-${layer.name}"
  ]

  // Apply the default output to the final layer
  output = (
    layer.index == length(devcontainer_layers) - 1
    ? split(" ", trimspace("${DEVCONTAINER_OUTPUTS}"))
    : null
  )
}

group "default" {
  targets = devcontainer_layers
}
