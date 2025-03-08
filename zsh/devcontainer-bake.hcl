target "zsh-base" {
  dockerfile-inline = "FROM base_context"
}

target "zsh-thefuck-pyenv" {
  dockerfile = "pyenv/Dockerfile"
  contexts = {
    base_context = "target:zsh-base"
  }
  args = {
    PYTHON_VERSION  = "3.8.20"
    VIRTUALENV_NAME = "thefuck"
  }
}

target "zsh" {
  dockerfile = "zsh/Dockerfile"
  contexts = {
    base_context  = "target:zsh-base"
    pyenv_context = "target:zsh-thefuck-pyenv"
  }
}
