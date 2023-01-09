#!/bin/sh

# this script takes the following options
# -d <disk>
# -m <metadata>

dump_disk_info()
{
	set -- $*
	while [ $# -ne 0 ]
	do
		disk=`basename $1`
		# get VXVM name for the disk
		vx_disk=`vxdisk -e list | grep -w $disk | awk '{print $1}'`
		if [ -z "$vx_disk" ]
		then
			echo "Error: cannot determine VXVM name for disk: '$disk'"
			shift 1
			continue
		fi
		echo "*** information for '$vx_disk' <-> '$disk' ***"
		vxdisk list $vx_disk
		shift 1
	done
}

# parse argumets
while getopts d:m: opt
do
	case $opt in
		"d")
			disks="$disks $OPTARG";;	

		"m")
			metadata=$OPTARG
	esac
done

echo "disks = '$disks'"
echo "metadata = '$metadata'"

dump_disk_info $disks
exit 0
