#!/bin/sh

# On systems with A/B partition layout, current slot is provided via cmdline parameter.
ab_slot_suffix=$(grep -o 'androidboot\.slot_suffix=..' /proc/cmdline |  cut -d "=" -f2)
[ ! -z "$ab_slot_suffix" ] && echo "A/B slot system detected! Slot suffix is $ab_slot_suffix"

find_partition_path() {
    label=$1
    path="/dev/$label"
    # In case fstab provides /dev/mmcblk0p* lines
    for dir in by-partlabel by-name by-label by-path by-uuid by-partuuid by-id; do
        # On A/B systems not all of the partitions are duplicated, so we have to check with and without suffix
        if [ -e "/dev/disk/$dir/$label$ab_slot_suffix" ]; then
            path="/dev/disk/$dir/$label$ab_slot_suffix"
            break
        elif [ -e "/dev/disk/$dir/$label" ]; then
            path="/dev/disk/$dir/$label"
            break
        fi
    done
    echo $path
}


parse_mount_flags() {
    org_options="$1"
    options=""
    for i in $(echo $org_options | tr "," "\n"); do
        [[ "$i" =~ "context" ]] && continue
        options+=$i","
    done
    options=${options%?}
    echo $options
}

if [ -e /android/init ]; then
	echo "System-as-root, only bind-mounting sub-mounts of /android/"
	cat /proc/self/mounts | while read line; do
		set -- $line
		# Skip any unwanted entry
		echo $2 | egrep -q "^/android/" || continue
		desired_mount=${2/\/android/}
		mount --bind $2 $LXC_ROOTFS_PATH/$desired_mount
	done

	rm -rf /dev/__properties__
	mkdir -p /dev/__properties__
	if [ -e /dev/disk/by-partlabel/persist ]; then
		mkdir -p /mnt/vendor/persist && mount /dev/disk/by-partlabel/persist /mnt/vendor/persist
	fi
else
	for mountpoint in /android/*; do
		mount_name=$(basename $mountpoint)
		desired_mount=$LXC_ROOTFS_PATH/$mount_name
	
		# Remove symlinks, for example bullhead has /vendor -> /system/vendor
		[ -L $desired_mount ] && rm $desired_mount

		[ -d $desired_mount ] || mkdir $desired_mount
		mount --bind $mountpoint $desired_mount
	done

	[ ! -e $LXC_ROOTFS_PATH/dev/null ] && mknod -m 666 $LXC_ROOTFS_PATH/dev/null c 1 3

	# Create /dev/pts if missing
	mkdir -p $LXC_ROOTFS_PATH/dev/pts

	# Pass /sockets through
	mkdir -p /dev/socket $LXC_ROOTFS_PATH/socket
	mount -n -o bind,rw /dev/socket $LXC_ROOTFS_PATH/socket

	rm $LXC_ROOTFS_PATH/sbin/adbd

	sed -i '/on early-init/a \    mkdir /dev/socket\n\    mount none /socket /dev/socket bind' $LXC_ROOTFS_PATH/init.rc

	sed -i "/mount_all /d" $LXC_ROOTFS_PATH/init.*.rc
	sed -i "/swapon_all /d" $LXC_ROOTFS_PATH/init.*.rc
	sed -i "/on nonencrypted/d" $LXC_ROOTFS_PATH/init.rc

	# Config snippet scripts
	run-parts /var/lib/lxc/android/pre-start.d || true
fi

fstab=$(ls /vendor/etc/fstab*)
[ ! -e "$fstab" ] && echo "fstab not found" && exit

echo "checking fstab $fstab for additional mount points"

cat ${fstab} | while read line; do
    set -- $line

    # stop processing if we hit the "#endhalium" comment in the file
    echo $1 | egrep -q "^#endhalium" && break

    # Skip any unwanted entry
    echo $1 | egrep -q "^#" && continue
    ([ -z "$1" ] || [ -z "$2" ] || [ -z "$3" ] || [ -z "$4" ]) && continue
    ([ "$2" = "/system" ] || [ "$2" = "/data" ] || [ "$2" = "/" ] \
    || [ "$2" = "auto" ] || [ "$2" = "/vendor" ] || [ "$2" = "none" ] \
    || [ "$2" = "/misc" ]) && continue
    ([ "$3" = "emmc" ] || [ "$3" = "swap" ] || [ "$3" = "mtd" ]) && continue

    label=$(echo $1 | awk -F/ '{print $NF}')
    [ -z "$label" ] && continue

    echo "checking mount label $label"

    path=$(find_partition_path $label)

    [ ! -e "$path" ] && continue

    mkdir -p $2
    echo "mounting $path as $2"
    mount $path $2 -t $3 -o $(parse_mount_flags $4)
done
