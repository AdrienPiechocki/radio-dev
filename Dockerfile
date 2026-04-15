# =============================================================================
# Dockerfile — Service Radio Locale
# =============================================================================
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg \
    curl \
    bash \
    coreutils \
    procps \
    python3 \
    python3-pip \
    python3-venv \
    wget \
    git \
    libgomp1 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /radio

COPY radio.sh /radio/radio.sh
RUN chmod +x /radio/radio.sh

CMD ["/radio/radio.sh"]
