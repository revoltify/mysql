FROM docker:28-dind

RUN apk add --no-cache bash coreutils openssh-server procps util-linux \
    && ssh-keygen -A \
    && sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config \
    && passwd -u root 2>/dev/null || true

COPY --chmod=755 start /usr/local/bin/lab-host-start

ENTRYPOINT ["lab-host-start"]
