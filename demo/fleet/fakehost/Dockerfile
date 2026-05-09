# =============================================================================
# fakehost — a "device" in the demo cluster.
#
# Runs:
#   - Docker daemon (DinD; isolates per-host containers from the operator's
#     Docker Desktop, so each fakehost truly hosts its own services)
#   - OpenSSH server, key-auth only, user `portoser` with passwordless sudo
#
# Why DinD: Portoser drives remote hosts via SSH + `docker compose`. To exercise
# those code paths honestly (and to render isolated per-host service lists in
# the UI), each fakehost needs its own Docker engine. A shared socket would
# collapse all "hosts" onto the operator's daemon and lie about the cluster.
# =============================================================================
FROM docker:27-dind

RUN apk add --no-cache --upgrade \
        openssh \
        bash \
        curl \
        ca-certificates \
        sudo \
        shadow \
        tini \
    && ssh-keygen -A \
    && adduser -D -s /bin/bash portoser \
    # adduser -D leaves /etc/shadow with `*` (no password set, treated as
    # "locked" by Alpine's sshd). We disable password auth in sshd_config
    # below; clear the password field so sshd lets key-auth proceed.
    && sed -i 's|^portoser:[^:]*:|portoser::|' /etc/shadow \
    && echo 'portoser ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers \
    && addgroup portoser docker \
    && mkdir -p /home/portoser/.ssh /etc/docker /srv \
    && chown -R portoser:portoser /home/portoser \
    && chmod 700 /home/portoser/.ssh

# sshd config: key auth only, no root, no password
RUN sed -i \
        -e 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' \
        -e 's/^#\?PermitRootLogin.*/PermitRootLogin no/' \
        -e 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' \
        -e 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' \
        /etc/ssh/sshd_config

COPY entrypoint.sh /usr/local/bin/fakehost-entrypoint.sh
RUN chmod +x /usr/local/bin/fakehost-entrypoint.sh

EXPOSE 22

# tini reaps the dockerd + sshd children cleanly on stop
ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/fakehost-entrypoint.sh"]
