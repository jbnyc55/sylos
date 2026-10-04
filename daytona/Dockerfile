# The syla-worker snapshot — everything run-syla.sh would otherwise
# install at run time, prebaked so a fire turns into a working agent in
# seconds. Build it into a Daytona snapshot once (see README.md) and set
# DAYTONA_SNAPSHOT on the syla-fire function to use it.
FROM node:22-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       git curl ca-certificates jq \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g opencode-ai@latest
