FROM mysql:8.4.13-oraclelinux9@sha256:76f0358884cb92d9a086d24e5671c38048d3fef40f2588703d73eb55392d6b69

ARG TARGETARCH
ARG LEGO_VERSION=4.35.2
ARG LEGO_SHA256_AMD64=ee5be4bf457de8e3efa86a51651c75c87f0ee0e4e9f3ae14f6034d68365770f3
ARG LEGO_SHA256_ARM64=e1f153179098d27ce044aaaa168c0e323d50ae71b0f1a147aa8ae49ac6b14d89
ARG CURL_VERSION=8.23.0
ARG CURL_SHA256_AMD64=049f982cb7db34e745cc0be0bdce2246b51fbf7ef17fc95ce37980f711ca91bb
ARG CURL_SHA256_ARM64=4db6c9b5e7f61f6a8cfa7f83e8c24e54259334bbb46743f6207ffb67bc0d1c3a
ARG TINI_VERSION=0.19.0
ARG TINI_SHA256_AMD64=c5b0666b4cb676901f90dfcb37106783c5fe2077b04590973b885950611b30ee
ARG TINI_SHA256_ARM64=eae1d3aa50c48fb23b8cbdf4e369d0910dfc538566bfd09df89a774aa84a48b9

COPY percona-xtrabackup.repo /etc/yum.repos.d/percona-xtrabackup.repo

RUN microdnf install -y mysql-router-community-8.4.10 percona-xtrabackup-84-8.4.0-7.1.el9 zstd jq tar gzip xz findutils procps-ng util-linux-core glibc-langpack-en \
    && microdnf clean all \
    && case "$TARGETARCH" in \
        amd64) machine=x86_64 lego_sha=$LEGO_SHA256_AMD64 curl_sha=$CURL_SHA256_AMD64 tini_sha=$TINI_SHA256_AMD64 ;; \
        arm64) machine=aarch64 lego_sha=$LEGO_SHA256_ARM64 curl_sha=$CURL_SHA256_ARM64 tini_sha=$TINI_SHA256_ARM64 ;; \
        *) exit 1 ;; \
    esac \
    && curl -fsSL -o /tmp/curl.tar.xz "https://github.com/stunnel/static-curl/releases/download/$CURL_VERSION/curl-linux-$machine-musl-$CURL_VERSION.tar.xz" \
    && echo "$curl_sha  /tmp/curl.tar.xz" | sha256sum -c - \
    && tar -xJf /tmp/curl.tar.xz -C /usr/local/bin curl \
    && curl -fsSL -o /tmp/lego.tar.gz "https://github.com/go-acme/lego/releases/download/v$LEGO_VERSION/lego_v${LEGO_VERSION}_linux_$TARGETARCH.tar.gz" \
    && echo "$lego_sha  /tmp/lego.tar.gz" | sha256sum -c - \
    && tar -xzf /tmp/lego.tar.gz -C /usr/local/bin lego \
    && curl -fsSL -o /usr/local/bin/tini "https://github.com/krallin/tini/releases/download/v$TINI_VERSION/tini-static-$TARGETARCH" \
    && echo "$tini_sha  /usr/local/bin/tini" | sha256sum -c - \
    && chmod 755 /usr/local/bin/tini \
    && rm -f /tmp/lego.tar.gz /tmp/curl.tar.xz \
    && install -d -o mysql -g mysql -m 700 /router /acme /tls \
    && install -d -o mysql -g mysql -m 755 /etc/mysql/conf.d

COPY my.cnf /etc/my.cnf
COPY lib/ /usr/local/lib/mysql-cluster/
COPY --chmod=755 bin/ /usr/local/bin/

ENV MYSQL_BUFFER_POOL_PERCENT=50 \
    CLUSTER_NAME=main \
    CLUSTER_SEED=false \
    ROUTER_PORT=6446 \
    BACKUP_ENABLED=true \
    BACKUP_INTERVAL_SECONDS=3600 \
    BACKUP_RETRY_SECONDS=300 \
    BACKUP_RETENTION=168 \
    BACKUP_PATH=mysql \
    BACKUP_TMP_DIR=/var/lib/mysql-backup \
    RESTORE_ON_EMPTY=true \
    ACME_STAGING=false \
    MYSQLSH_USER_CONFIG_HOME=/tmp/mysqlsh \
    LANG=en_US.UTF-8

VOLUME /var/lib/mysql
EXPOSE 3306 6446

HEALTHCHECK --interval=15s --timeout=5s --start-period=120s --retries=3 CMD ["healthcheck"]

STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/local/bin/tini", "--", "entrypoint"]
