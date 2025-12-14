# Use the official VS Code devcontainers base image for Ubuntu 22.04
FROM mcr.microsoft.com/vscode/devcontainers/base:ubuntu-22.04

# Install tools we want available inside the container
RUN apt-get update && export DEBIAN_FRONTEND=noninteractive \
    && apt-get -y install --no-install-recommends \
        git \
        curl \
        zip \
        lua5.1 \
        luarocks \
        openssh-client \
        python3 \
        python3-pip \
    && luarocks install luacheck \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Copy and install Python requirements with pinned versions
COPY requirements.txt /tmp/requirements.txt
RUN pip3 install --no-cache-dir -r /tmp/requirements.txt \
    && rm /tmp/requirements.txt