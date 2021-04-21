#!/bin/bash
set -x

ODROID_KERNEL_BRANCH="$1"

if [ "$ODROID_KERNEL_BRANCH" == "" ]; then
  ODROID_KERNEL_BRANCH=master
fi

if [ "$ODROID_KERNEL_BRANCH" != "master" ] && [ "$ODROID_KERNEL_BRANCH" != "develop" ]; then
  >&2 echo "wrong usage of $0"
  echo "Usage: $0 [BRANCH]"
  echo "BRANCH [master|develop]"
  exit 1
fi

SELF_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
BUILD_DIR=$SELF_DIR/build
ROOTFS_DIR=$BUILD_DIR/rootfs
BOOT_DIR=$ROOTFS_DIR/boot
EXTLINUX_DIR=$BOOT_DIR/extlinux
LINUX_STABLE_DIR=$BUILD_DIR/linux-stable
ODROID_KERNEL_DIR=$BUILD_DIR/linux-mainline-and-mali-generic-stable-kernel
DIST_DIR=$SELF_DIR/dist

# Based on https://github.com/RKaczmarek/linux-mainline-and-mali-generic-stable-kernel/blob/master/readme.exy
export CROSS_COMPILE=arm-linux-gnueabihf-
export ARCH=arm
export INSTALL_MOD_PATH=$ROOTFS_DIR
export KERNEL_VERSION=5.4.20

apt-get -y install gcc-arm-linux-gnueabihf flex bison libssl-dev libncurses-dev bc tree

if [ ! -d $BUILD_DIR ]; then
  mkdir -p $BUILD_DIR
fi

# cleanup before rerun build
if [ -d $ROOTFS_DIR ]; then
  rm -R $ROOTFS_DIR
else
  mkdir -p $ROOTFS_DIR
fi

if [ ! -d $ODROID_KERNEL_DIR ]; then
  cd $BUILD_DIR
  git clone --branch $ODROID_KERNEL_BRANCH https://github.com/RKaczmarek/linux-mainline-and-mali-generic-stable-kernel.git
else
  cd $ODROID_KERNEL_DIR
  git fetch origin $ODROID_KERNEL_BRANCH
  git reset --hard origin/$ODROID_KERNEL_BRANCH
fi

if [ ! -d $LINUX_STABLE_DIR ]; then
  cd $BUILD_DIR
  git clone --depth 1 --single-branch --branch v$KERNEL_VERSION git://git.kernel.org/pub/scm/linux/kernel/git/stable/linux-stable.git
else
  cd $LINUX_STABLE_DIR
  git fetch origin v$KERNEL_VERSION
  git reset --hard origin/v$KERNEL_VERSION
fi

##########################################################################################################
# Working on (git root)/linux-stable/
cd $LINUX_STABLE_DIR

# Patches
#
# add cmdline option to set a fixed ethernet mac address on the kernel cmdline to avoid getting a randomone on each boot
patch -N -p1 < $ODROID_KERNEL_DIR/misc.exy/eth-hw-addr.patch

# fix thermal cpu cooling for the odroid u3 and x2
# patch -N -p1 < $ODROID_KERNEL_DIR/misc.exy/fix-odroid-u3-cpu-cooling.patch

# add mali support
patch -N -p1 < $ODROID_KERNEL_DIR/misc.exy/exynos4412-mali-complete.patch
cp -rv         $ODROID_KERNEL_DIR/misc.exy/exynos4412-mali-complete/drivers/gpu/arm drivers/gpu
patch -N -p1 < $ODROID_KERNEL_DIR/misc.exy/devfreq-turbo-for-mali-gpu-driver.patch
patch -N -p1 < $ODROID_KERNEL_DIR/misc.exy/export-cma-symbols.patch
patch -N -p1 < $ODROID_KERNEL_DIR/misc.exy/dts-add-gpu-node-for-exynos4412.patch
patch -N -p1 < $ODROID_KERNEL_DIR/misc.exy/dts-add-gpu-opp-table.patch
patch -N -p1 < $ODROID_KERNEL_DIR/misc.exy/dts-setup-gpu-node.patch
patch -N -p1 < $ODROID_KERNEL_DIR/misc.exy/dts-exynos-remove-new-gpu-node-v5.3.patch
cp -v          $ODROID_KERNEL_DIR/config.exy $LINUX_STABLE_DIR/.config

make oldconfig

# See https://linoxide.com/firewall/configure-nftables-serve-internet/
make menuconfig

echo CONFIG_NET_IPVTI=m >> .config
echo CONFIG_NET_FOU=m >> .config

make -j 4 zImage dtbs modules
export kver=`make kernelrelease`
echo ${kver}
make modules_install

##########################################################################################################
# Working on (git root)/rootfs/
cd $ROOTFS_DIR

# This section based on http://odroid.us/mediawiki/index.php?title=Step-by-step_Cross-compiling_a_Kernel
# Remove symlinks that point to files we do not need in root file system
find . -name source | xargs rm
find . -name build | xargs rm

##########################################################################################################
# Working on (git root)/

mkdir -p $BOOT_DIR/dtb-${kver}
cp -v $LINUX_STABLE_DIR/.config $BOOT_DIR/config-${kver}
cp -v $LINUX_STABLE_DIR/arch/arm/boot/zImage $BOOT_DIR/zImage-${kver}
cp -v $LINUX_STABLE_DIR/arch/arm/boot/dts/exynos4412-odroidu3.dtb $BOOT_DIR/dtb-${kver}
cp -v $LINUX_STABLE_DIR/arch/arm/boot/dts/exynos4412-odroidx2.dtb $BOOT_DIR/dtb-${kver}
cp -v $LINUX_STABLE_DIR/System.map $BOOT_DIR/System.map-${kver}

mkdir -p $EXTLINUX_DIR
cat > $EXTLINUX_DIR/extlinux.conf << EOF
TIMEOUT 30
DEFAULT v${KERNEL_VERSION//\./}

MENU TITLE odroid u3 boot options

LABEL v${KERNEL_VERSION//\./}
      MENU LABEL v$KERNEL_VERSION mali kernel mmcblk0
      LINUX ../zImage-$KERNEL_VERSION-stb-exy+
      # odroid u3
      FDT ../dtb-$KERNEL_VERSION-stb-exy+/exynos4412-odroidu3.dtb
      # odroid x2
      #FDT ../dtb-$KERNEL_VERSION-stb-exy+/exynos4412-odroidx2.dtb
      # odroid x
      #FDT ../dtb-$KERNEL_VERSION-stb-exy+/exynos4412-odroidx.dtb
      APPEND console=ttySAC1,115200n8 console=tty1 mem=2047M smsc95xx.macaddr=ba:5d:6d:41:68:6f root=/dev/mmcblk0p3 ro loglevel=8 rootwait net.ifnames=0 ipv6.disable=1 fsck.repair=yes video=HDMI-A-1:e drm.edid_firmware=edid/1024x768.bin
EOF

##########################################################################################################
# Working on (git root)/rootfs

cat > $ROOTFS_DIR/README.odroid-u3 << EOF
README.odroid-u3

* The following commands must be executed:

	update-initramfs -c -k ${kver}
	mkimage -A arm -O linux -T ramdisk -a 0x0 -e 0x0 -n initrd.img-${kver} -d initrd.img-${kver} uInitrd-${kver}

EOF


if [ -d $DIST_DIR ]; then
  rm $DIST_DIR/${kver}.tar.gz
else
  mkdir -p $DIST_DIR
fi

cd $ROOTFS_DIR

tar -cvzf $DIST_DIR/${kver}.tar.gz ./*
tree -L 5 $ROOTFS_DIR
