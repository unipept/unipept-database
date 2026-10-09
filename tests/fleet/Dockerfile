# One image for every host of the fleet: what Ubuntu 24.04, the release the servers run, has before
# anyone installs anything, plus systemd as PID 1 and sshd. What makes a host a server, a build host
# or a load balancer is what the real installs put on it.
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
      systemd systemd-sysv dbus libpam-systemd openssh-server sudo curl ca-certificates gnupg \
      iptables procps zip \
 && rm -rf /var/lib/apt/lists/* \
 && systemctl enable ssh

# sshd on 2222 only, so a script that assumes port 22 rather than following ~/.ssh/config cannot
# pass by landing on it. zip above is the harness's own, to pack the fixtures as the sources come.
RUN printf 'Port 2222\n' > /etc/ssh/sshd_config.d/fleet.conf

STOPSIGNAL SIGRTMIN+3
CMD ["/lib/systemd/systemd"]
