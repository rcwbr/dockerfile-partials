variable "DOCKER_GID" {
  default = "800"
}
// Define an extra GID arg with the Docker group ID in case the useradd partial will be included
variable "DOCKER_CLIENT_EXTRA_GID_ARGS" {
  default = "--gid ${DOCKER_GID}"
}

target "docker-client" {
  dockerfile = "docker-client/Dockerfile"
  contexts = {
    docker_image = "docker-image://docker:27.5.1-cli"
  }
}
