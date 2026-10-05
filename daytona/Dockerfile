# The syla-worker snapshot — everything run-syla.sh would otherwise
# install at run time, prebaked so a fire turns into a working agent in
# seconds. syla-fire normally builds this itself (its SNAPSHOT_DOCKERFILE
# mirrors this file — keep them in lockstep, and bump AUTO_SNAPSHOT's
# name suffix on any change); this file is the reference recipe and the
# manual-build path (README.md step 3) for keys that cannot create
# snapshots.
FROM node:22-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       git curl ca-certificates jq \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g opencode-ai@latest
