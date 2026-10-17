#!/bin/sh
# Bridges the container's eth0 to a tap so the VM sits directly on the Docker network.
set -eu

ip link add br0 type bridge
ip addr flush dev eth0
ip link set eth0 master br0
ip tuntap add tap0 mode tap
ip link set tap0 master br0
ip link set tap0 up
ip link set br0 up
# Pin the VM MAC to tap0: Docker's bridge hairpins broadcasts back into eth0, which
# would otherwise move the learned entry there and drop all unicast to the VM.
bridge fdb replace "$VM_MAC" dev tap0 master static sticky

[ -f /vm/disk.qcow2 ] || qemu-img create -f qcow2 /vm/disk.qcow2 "$VM_DISK"
[ -f /vm/vars.fd ] || cp /usr/share/AAVMF/AAVMF_VARS.fd /vm/vars.fd

exec qemu-system-aarch64 \
    -machine virt -cpu max -accel tcg,thread=multi -smp "$VM_CPUS" -m "$VM_MEM" \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/AAVMF/AAVMF_CODE.fd \
    -drive if=pflash,format=raw,file=/vm/vars.fd \
    -drive if=none,id=disk0,file=/vm/disk.qcow2 -device virtio-blk-pci,drive=disk0,bootindex=0 \
    -netdev tap,id=net0,ifname=tap0,script=no,downscript=no \
    -device virtio-net-pci,netdev=net0,mac="$VM_MAC",romfile=,bootindex=1 \
    -smbios type=1,serial="$VM_SERIAL" -uuid "$VM_UUID" \
    -nographic
