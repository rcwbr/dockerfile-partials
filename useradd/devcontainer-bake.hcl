variable "EXTRA_GID_ARGS" {
  default = try(DOCKER_CLIENT_EXTRA_GID_ARGS, "")
}
variable "USER" {
  default = "root"
}
variable "UID" {
  default = 0
}
variable "GID" {
  // Use the user id as group id unless set
  default = "${UID}"
}

target "useradd" {
  dockerfile = "useradd/Dockerfile"
  args = {
    EXTRA_GID_ARGS = "${EXTRA_GID_ARGS}"
    USER           = "${USER}"
    USER_UID       = "${UID}"
    USER_GID       = "${GID}"
  }
}
