# hadolint ignore=DL3006
FROM docker_image AS docker_image

# Set base_context in the downstream Bake file
# hadolint ignore=DL3006
FROM base_context

# hadolint ignore=DL3002
USER root

SHELL [ "/bin/bash", "-eo", "pipefail", "-c" ]
RUN <<EOF

curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  | tee /usr/share/keyrings/githubcli-archive-keyring.gpg > /dev/null
chmod 644 /usr/share/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
  | tee /etc/apt/sources.list.d/github-cli.list > /dev/null
apt-get update
if ! dpkg-query --status gh ; then
  apt-get install --allow-unauthenticated --no-install-recommends -y gh=2.97.0 ;
fi
apt-get clean
apt-get autoclean
apt-get autoremove
rm -rf /var/cache/debconf
rm -rf /var/lib/apt/lists/*

EOF
