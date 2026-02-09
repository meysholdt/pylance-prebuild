FROM mcr.microsoft.com/devcontainers/python:3.12

# Chromium dependencies for Puppeteer (used by Pylance prebuild indexing)
RUN apt-get update && export DEBIAN_FRONTEND=noninteractive \
    && apt-get -y install --no-install-recommends \
       libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 libxkbcommon0 \
       libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libgbm1 \
       libpango-1.0-0 libcairo2 libasound2 libnspr4 libnss3 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*
