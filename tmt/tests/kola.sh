cat <<EOF > $HOME/utils.sh
export COSA_DIR=\$HOME/workspace/build;
cosa ()
{
    env | grep --color=auto COREOS_ASSEMBLER;
    local -r COREOS_ASSEMBLER_CONTAINER_LATEST="quay.io/coreos-assembler/coreos-assembler:latest";
    set -x;
    podman run --rm -ti --security-opt=label=disable --privileged --uidmap=1000:0:1 --uidmap=0:1:1000 --uidmap=1001:1001:64536 -v=\${COSA_DIR}:/srv/ --device=/dev/kvm --device=/dev/fuse --tmpfs=/tmp -v=/var/tmp:/var/tmp --name=cosa \${COREOS_ASSEMBLER_CONFIG_GIT:+-v=\$COREOS_ASSEMBLER_CONFIG_GIT:/srv/src/config/:ro} \${COREOS_ASSEMBLER_GIT:+-v=\$COREOS_ASSEMBLER_GIT/src/:/usr/lib/coreos-assembler/:ro} \${COREOS_ASSEMBLER_ADD_CERTS:+-v=/etc/pki/ca-trust:/etc/pki/ca-trust:ro} \${COREOS_ASSEMBLER_CONTAINER_RUNTIME_ARGS} \${COREOS_ASSEMBLER_CONTAINER:-\$COREOS_ASSEMBLER_CONTAINER_LATEST} "\$@";
    rc=\$?;
    set +x;
    return \$rc
}
EOF
set -x
source $HOME/utils.sh
mkdir -p $COSA_DIR
echo $TMT_TEST_DATA
cosa init --force https://github.com/coreos/fedora-coreos-config

echo $IMAGE_URL
cosa import docker://$IMAGE_URL
CONFIG_COMMIT=$(jq -r ".\"coreos-assembler.oci-imported-labels\".vcs-ref" ${COSA_DIR}/builds/latest/$(arch)/meta.json)
pushd ${COSA_DIR}/src/config
git checkout $CONFIG_COMMIT
popd
cosa buildextend-qemu
cosa kola run rpmostree.status --rerun --allow-rerun-success=tags=needs-internet --build=latest --on-warn-failure-exit-77 --arch=x86_64 '--tag=!reprovision' --parallel=5
mv $COSA_DIR/tmp/kola $TMT_TEST_DATA
