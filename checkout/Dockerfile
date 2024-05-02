FROM debian:bookworm-slim

RUN set -eux; \
	apt-get update; \
	apt-get install -y \
		git \
		curl \
	; \
	rm -rf /var/lib/apt/lists/*

WORKDIR /tmp

COPY checkout.sh cleanup.sh /usr/local/bin/
