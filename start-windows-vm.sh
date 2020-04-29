#!/bin/bash

set -e

[[ "$EUID" -ne 0 ]] && echo "Please run with sudo" && exit 1

[[ ! -f config ]] && echo "config does not exist" && exit 1

source config

QEMU_PARAMS="-machine q35 \
    -cpu host,kvm=off \
    -enable-kvm \
    -smp $CORES,sockets=1,cores=$CORES,threads=1 \
    -m ${MEMORY}G \
    -mem-path /dev/hugepages \
    -mem-prealloc \
    -device virtio-balloon \
    -drive if=pflash,format=raw,readonly,file=/usr/share/ovmf/x64/OVMF_CODE.fd \
    -drive if=pflash,format=raw,file=/usr/share/ovmf/x64/OVMF_VARS.fd \
    -nic user,model=virtio-net-pci,smb=$SHARE \
    -device ich9-intel-hda \
    -device hda-micro,audiodev=hda \
    -audiodev pa,id=hda,server=unix:/run/user/1000/pulse/native,timer-period=100 \
    -rtc base=localtime,clock=host"


# drives
n=1
for path in $DRIVES; do
    QEMU_PARAMS="$QEMU_PARAMS \
        -object iothread,id=io$n \
        -device virtio-blk-pci,drive=disk$n,iothread=io$n \
        -drive id=disk$n,if=none,cache=none,format=raw,aio=native,file=$path"

    n=$((n+1))
done


# inputs
n=1
for path in $INPUTS; do
    QEMU_PARAMS="$QEMU_PARAMS \
        -object input-linux,id=id$n,evdev=$path"

    n=$((n+1))
done


# vga
enable_vga_passthrough() {
    VGA_PASSTHROUGH_ENABLED=true
    QEMU_PARAMS="$QEMU_PARAMS \
        -device vfio-pci,host=$VFIO_VIDEO,bus=pcie.0,multifunction=on$VGA_PASSTHROUGH_ADDITION \
        -device vfio-pci,host=$VFIO_AUDIO,bus=pcie.0 \
        -vga none \
        -nographic"
}


if [[ "$VGA" = "passthrough" ]]; then
    # vga passtrough while having another gpu on the host
    enable_vga_passthrough

elif [[ "$VGA" = "passthrough-single" ]]; then
    # vga passthrough with single gpu

    [[ ! -f VBIOS.rom ]] && echo "VBIOS.rom does not exist" && exit 1

    VGA_PASSTHROUGH_SINGLE=true
    VGA_PASSTHROUGH_ADDITION=",x-vga=on,romfile=VBIOS.rom"
    enable_vga_passthrough

elif [[ "$VGA" = "passthrough-lg" ]]; then
    # vga passthrough with looking-glass setup
    enable_vga_passthrough
    QEMU_PARAMS="$QEMU_PARAMS \
        -device ivshmem-plain,memdev=ivshmem,bus=pcie.0 \
        -object memory-backend-file,id=ivshmem,share=on,mem-path=/dev/shm/looking-glass,size=32M"

    sudo -u $SUDO_USER touch /dev/shm/looking-glass

else
    # virtual vga device
    QEMU_PARAMS="$QEMU_PARAMS \
        -vga qxl \
        -monitor stdio"

fi

echo $QEMU_PARAMS

# setup vga passthrough state
if [[ -v VGA_PASSTHROUGH_ENABLED ]]; then

    source vfio.sh

    if [[ -v VGA_PASSTHROUGH_SINGLE ]]; then
        console_framebuffer_unbind
    fi

    rmmod_nvidia || true
    vfio_bind "$VFIO_VIDEO $VFIO_AUDIO"
fi

# allocate needed amount of 2 MB hugepages
echo $(($MEMORY * 1024 / 2)) > /proc/sys/vm/nr_hugepages

# actual qemu invocation
$QEMU_BINARY $QEMU_PARAMS

# release allocated hugepages
echo 0 > /proc/sys/vm/nr_hugepages

# restore from vga passthrough state
if [[ -v VGA_PASSTHROUGH_ENABLED ]]; then
    vfio_unbind "$VFIO_VIDEO $VFIO_AUDIO"
    modprobe_nvidia

    if [[ -v VGA_PASSTHROUGH_SINGLE ]]; then
        console_framebuffer_bind
    fi
fi
