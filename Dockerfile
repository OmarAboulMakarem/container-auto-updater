FROM alpine:3.20

RUN apk add --no-cache \
      bash \
      curl \
      jq \
      docker-cli \
      docker-cli-compose \
      docker-buildx \
      python3 \
      py3-pip \
      groff \
      less \
      unzip \
    && pip3 install --no-cache-dir --break-system-packages awscli \
    && rm -rf /var/cache/apk/*

WORKDIR /app
COPY scripts/ ./scripts/
RUN chmod +x ./scripts/*.sh

ENTRYPOINT ["/app/scripts/entrypoint.sh"]
