#!/bin/bash

wait_network() {
    echo "Waiting for network to be ready..."
    while true; do
        ping -c 1 -W 5 canonical.com && break > /dev/null 2>&1
        sleep 1
    done
}

install_python() {
    tests.pkgs install python3 python3-pip python3-venv
}

bootstrap_python_venv() {
    install_python
    python3 -m venv "${PROJECT_PATH}/.venv"
    source "${PROJECT_PATH}/.venv/bin/activate"
    pip3 install -U pip setuptools tox poetry
}

install_charmcraft() {
    snap install charmcraft --classic --channel "$CHARMCRAFT_CHANNEL"
}

install_lxd() {
    snap install lxd --channel "$LXD_CHANNEL"
    lxd waitready
    lxd init --auto
    chmod a+wr /var/snap/lxd/common/lxd/unix.socket
    lxc network set lxdbr0 ipv6.address none
    usermod -a -G lxd "$USER"

    # Work-around clash between docker and lxd on jammy
    # https://github.com/docker/for-linux/issues/1034
    iptables -F FORWARD
    iptables -P FORWARD ACCEPT
}


install_microk8s() {
    if [[ "${JUJU_CHANNEL}" == 2* ]]; then
        MICROK8S_CLASSIC=1
    fi
    snap install microk8s --channel "$MICROK8S_CHANNEL" ${MICROK8S_CLASSIC:+--classic}

    # microk8s needs some additional things done to ensure
    #it's ready for Juju.
    microk8s status --wait-ready

    if [ ! -z "$MICROK8S_ADDONS" ]; then
        microk8s enable $MICROK8S_ADDONS
    fi

    local version=$(snap list microk8s | grep microk8s | awk '{ print $2 }')

    # workarounds for https://bugs.launchpad.net/juju/+bug/1937282
    retry microk8s kubectl -n kube-system rollout status deployment/coredns
    retry microk8s kubectl -n kube-system rollout status deployment/hostpath-provisioner

    retry microk8s kubectl auth can-i create pods

    mkdir -p "${HOME}/.kube"
    microk8s config > "${HOME}/.kube/config"
}

uninstall_microk8s() {
    microk8s stop || true
    snap remove microk8s --purge
}

install_juju() {
    snap install juju --classic --channel "$JUJU_CHANNEL"
    mkdir -p "$HOME"/.local/share/juju
}


bootstrap_juju() {
    # Bootstraping often hangs on downloading images, so we retry a few times
    for i in $(seq 1 3); do
        juju bootstrap --verbose "$PROVIDER" "$CONTROLLER_NAME" \
            $JUJU_BOOTSTRAP_OPTIONS $JUJU_EXTRA_BOOTSTRAP_OPTIONS \
            --bootstrap-constraints=$JUJU_BOOTSTRAP_CONSTRAINTS \
            --config bootstrap-timeout=$JUJU_BOOTSTRAP_TIMEOUT \
            && break || restore_juju
        sleep 3
    done
}


restore_juju() {
     juju controllers --refresh ||:
     juju destroy-controller -v --no-prompt --show-log \
       --destroy-storage --destroy-all-models "$CONTROLLER_NAME" || \
       juju kill-controller -v --no-prompt --show-log "$CONTROLLER_NAME" ||:
}

uninstall_juju() {
    restore_juju
    snap remove juju --purge
}

install_tools() {
    snap install jq
    snap install charm --classic --channel "$CHARM_CHANNEL"
    snap install juju-bundle --classic --channel "$JUJU_BUNDLE_CHANNEL"
    snap install juju-crashdump --classic --channel "$JUJU_CRASHDUMP_CHANNEL"
}