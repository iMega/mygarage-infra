# ansible-vault and htpasswd for the workstation, so that neither has to be
# installed there. Used by scripts/vault.sh, which tags the image by the
# hash of this file. Keep the ansible-core version in sync with the workflows.
FROM python:3.12-slim-bookworm

RUN apt-get update \
    && apt-get install -y --no-install-recommends apache2-utils \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir ansible-core==2.21.5

WORKDIR /work
