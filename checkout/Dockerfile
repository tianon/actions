FROM debian:trixie-slim

RUN set -eux; \
	apt-get update; \
	apt-get install -y \
		git \
		curl \
	; \
	apt-get dist-clean

WORKDIR /tmp

COPY checkout.sh cleanup.sh /usr/local/bin/
