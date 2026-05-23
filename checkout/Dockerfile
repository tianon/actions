FROM debian:trixie-slim

RUN set -eux; \
	apt-get install --update -y --no-install-recommends \
		ca-certificates \
		curl \
		git \
	; \
	apt-get dist-clean

COPY --from=tianon/gosu /gosu /usr/local/bin/
# verify that the binary works
RUN gosu nobody true

WORKDIR /tmp

COPY . /usr/local/bin/
