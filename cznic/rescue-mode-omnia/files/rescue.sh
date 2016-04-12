#!/bin/sh
#
# Turris Omnia rescue script
# (C) 2016 CZ.NIC, z.s.p.o.
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.


DEBUG=1

I2C_BUS="1"
I2C_ADDR="0x2a"
I2C_REG="0x9"

DEV="/dev/mmcblk0"
FS_DEV="${DEV}p1"
FS_MOUNTPOINT="/mnt"
SRCFS_MOUNTPOINT="/srcmnt"
MEDKIT_FILENAME="omnia-medkit.tar.gz"
FACTORY_SNAPNAME="@factory"

BIN_I2CGET="/usr/sbin/i2cget"
BIN_BTRFS="/usr/bin/btrfs"
BIN_MKFS="/usr/bin/mkfs.btrfs"
BIN_MOUNT="/bin/mount"
BIN_GREP="/bin/grep"
BIN_UMOUNT="/bin/umount"
BIN_SYNC="/bin/sync"
BIN_AWK="/usr/bin/awk"
BIN_MV="/bin/mv"
BIN_DATE="/bin/date"
BIN_DD="/bin/dd"
BIN_FDISK="/usr/sbin/fdisk"
BIN_BLOCKDEV="/sbin/blockdev"
BIN_MKDIR="/bin/mkdir"
BIN_HWCLOCK="/sbin/hwclock"
BIN_SLEEP="/bin/sleep"
BIN_TAR="/bin/tar"
BIN_LS="/bin/ls"
BIN_SORT="/usr/bin/sort"
BIN_TAIL="/usr/bin/tail"
BIN_REBOOT="/sbin/reboot"
BIN_MDEV="`which mdev`"
[ -z "$BIN_MDEV" ] || BIN_MDEV="$BIN_MDEV -s"

d() {
	if [ $DEBUG -gt 0 ]; then
		echo "$@"
	fi
}

e() {
	echo "Error: $@" >&2
}

mount_fs() {
	d "mount_fs $1 $2"
	if ! [ -d $2 ]; then
		$BIN_MKDIR -p "$2"
	fi

	if $BIN_MOUNT | $BIN_GREP -E "on $2 ">/dev/null; then
		e "Mountpoint $2 already used. Exit."
		exit 21
	fi

	$BIN_MOUNT $1 $2
	if [ $? -ne 0 ]; then
		e "Mount $1 on $2 failed. Exit."
		exit 22
	fi
}

umount_fs() {
	d "umount_fs $1"
	$BIN_UMOUNT $1
	if $BIN_MOUNT | $BIN_GREP -E "on $1 ">/dev/null; then
		$BIN_UMOUNT -f $1
	fi
	if $BIN_MOUNT | $BIN_GREP -E "on $1 ">/dev/null; then
		$BIN_MOUNT -o remount,ro $1
	fi
	$BIN_SYNC
}

rollback () {
	# precondition: $FS_DEV mounted to $FS_MOUNTPOINT

	d "Rollback the root snapshot ${FS_MOUNTPOINT}/@ to "

	D=`$BIN_DATE +%s`
	BCK="${FS_MOUNTPOINT}/@backup-${D}"
	while test -d $BCK; do
		$BIN_SLEEP 2
		D=`$BIN_DATE +%s`
		BCK="${FS_MOUNTPOINT}/@backup-${D}"
	done

	if ! [ -e "${FS_MOUNTPOINT}/$1" ]; then
		umount_fs $FS_MOUNTPOINT
		e "Source snapshot ${FS_MOUNTPOINT}/$1 does not exist. Exit."
		exit 21
	fi

	d "Backing up root ${FS_MOUNTPOINT}/@ to $BCK"
	$BIN_MV "${FS_MOUNTPOINT}/@" "$BCK"

	d "Restoring ${FS_MOUNTPOINT}/$1 to root ${FS_MOUNTPOINT}/@"
	$BIN_BTRFS subvolume snapshot "${FS_MOUNTPOINT}/$1" "${FS_MOUNTPOINT}/@"

	umount_fs $FS_MOUNTPOINT

	d "Rollback succeeded."
}

rollback_last () {
	mount_fs $FS_DEV $FS_MOUNTPOINT

	SRCSNAP=`$BIN_LS ${FS_MOUNTPOINT} | $BIN_AWK '/@[0-9]+/ { print $1 }' | $BIN_SORT -n | $BIN_TAIL -1`
	if [ -z "${SRCSNAP}" ]; then
		e "Missing source snapshot. Setting factory default snapshot."
		SRCSNAP="${FACTORY_SNAPNAME}"
	fi

	rollback "$SRCSNAP"
}

rollback_first () {
	mount_fs $FS_DEV $FS_MOUNTPOINT

	rollback "${FACTORY_SNAPNAME}"
}

reflash () {
	IMG=""
	# find image (give it 10 tries with 1 sec delay)
	for i in `seq 1 10`; do
		$BIN_MDEV
		for dev in `$BIN_AWK '$4 ~ /sd[a-z]+[0-9]+/ { print $4 }' /proc/partitions`; do
			d "Testing FS on device $dev"
			[ -b "/dev/$dev" ] || continue
			mount_fs "/dev/$dev" $SRCFS_MOUNTPOINT
			d "Searching for ${SRCFS_MOUNTPOINT}/${MEDKIT_FILENAME} on $dev"
			if [ -f ${SRCFS_MOUNTPOINT}/${MEDKIT_FILENAME} ]; then
				IMG="${SRCFS_MOUNTPOINT}/${MEDKIT_FILENAME}"
				d "Found medkit file $IMG on device $dev"
				break
			else
				d "Medkit file not found on device $dev"
				umount_fs $SRCFS_MOUNTPOINT
			fi
		done
		[ -z "${IMG}" ] || break
		sleep 1
	done

	if [ -n "${IMG}" ]; then

		$BIN_DD if=/dev/zero of=$DEV bs=512 count=1
		$BIN_FDISK $DEV <<EOF
n
p
1


p
w
EOF

		$BIN_BLOCKDEV --rereadpt $DEV
		$BIN_MDEV
		$BIN_SLEEP 1
		if ! [ -e $FS_DEV ]; then
			e "Partition $FS_DEV missing. Exit."
			umount_fs $SRCFS_MOUNTPOINT
			exit 23
		fi
		$BIN_MKFS -f $FS_DEV
		mount_fs $FS_DEV $FS_MOUNTPOINT
		$BIN_BTRFS subvolume create "${FS_MOUNTPOINT}/@"
		ROOTDIR="${FS_MOUNTPOINT}/@"
		d "Rootdir is $ROOTDIR"
		cd $ROOTDIR
		$BIN_TAR zxf $IMG
		cd /
		$BIN_BTRFS subvolume snapshot "${FS_MOUNTPOINT}/@" "${FS_MOUNTPOINT}/@factory"
		umount_fs $FS_MOUNTPOINT
		umount_fs $SRCFS_MOUNTPOINT
	else
		d "No medkit image found. Exit to shell."
		exit 0
	fi

	d "Reflash succeeded."
}

reset_clock () {
	$BIN_DATE 201603010000
	$BIN_HWCLOCK -w
}




# main
MODE=`$BIN_I2CGET -y $I2C_BUS $I2C_ADDR $I2C_REG b`
MODE=$(( $MODE ))
d "MODE=$MODE"

if [ -z "${MODE}" ]; then
	e "Invalid (empty) mode."
	exit -10
fi

case "$MODE" in
	0)
		e "Invalid mode 0 - normal boot expected. Exit to shell."
		exit 11
		;;
	1)
		d "Mode: Rollback to the last snapshot..."
		rollback_last
		;;

	2)
		d "Mode: Rollback to first snapshot..."
		rollback_first
		;;
	3)
		d "Mode: Reflash..."
		reset_clock
		reflash
		;;
	*)
		e "Invalid mode $MODE. Exit to shell."
		exit 12
esac

exit 0

