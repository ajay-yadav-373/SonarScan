#!/bin/bash

#This file contains common functions used across all scripts during backup and recovery
#Assumtions:
#   LOGFILE - must be set to the appropriate file prior to invoking any listed function
#
DEV_DM=`cat /proc/devices | grep "device-mapper" | head -n 1 | awk '{print $1}'`
DEV_MD=`cat /proc/devices | grep -w "md" | head -n 1 | awk '{print $1}'`
DEV_FIO=`cat /proc/devices | grep "fio" | head -n 1 | awk '{print $1}'`

DEV_CPQARRAY="104"

LOGDIR="/tmp"
LOGFILE="/tmp/cvrestore.log"
SRDIR="/"
SYS_CONF="/tmp/sysconf"
SYS_STATE_LOC=/system_state/sysconf/
YASTGUI="/tmp/yastgui"
STORAGE_TREE="/tmp/storage_tree"
AUTOLAYOUTFILE="/tmp/autolayout"
SUPPORTED_DISK="^/dev/mapper|^/dev/[ihsv]d|^/dev/fio|^/dev/dm|^/dev/cciss|^/dev/xvd|^/dev/disk/by-uuid/|^/dev/md|LABEL\=|^/dev/nvme"
SKIPPED_IS_DISK_LIST="^/dev/drbd|^/dev/emcpower|^/dev/loop"
DELIM_OPTIONS=("p" "-part" "part")
SYS_MTPT="^/$|^/boot$|^/boot/efi$|^/usr$|^/etc$|^/lib64$|^/lib$|^/var$|^/var$|^/opt$"
SYS_MTPT2="${SYS_MTPT}|^swap"
MIN_SIZE_BOOT_PART=$((200*1024*1024))
SUPPORT_PTYPE="gpt|msdos"
#If anyone want to skip any directory for mount point, it can be added here.
mpnt=`docker info|grep "Docker Root Dir"|cut -f2 -d':'|tr -d ' '`
UNMOUNT_LOC=""
if [ "x$mpnt" != "x" ]
then
    UNMOUNT_LOC="^$mpnt"
fi
Log()
{
    if [ -f $0 ]; then
        file=`basename $0`
    else
        file="<shell>"
    fi
    dt=`date`
    echo -e "$file: $dt: $*" >> $LOGFILE
}

LogFile()
{
    Log $@
}


#Replace Fstab entry from diskname to UUID
#   Name: fstabDiskToUUID
#   API DEF:
#       IN:             arg1=fstab file location,arg2=new fstab file location(should not be same)
#       OUT:            return 0=sucess 1=fail
#       EXIT:           NO
fstabDiskToUUID(){
    ret=0
    ofile=$1
    nfile=$2
    rm -rf $nfile
    if [ ! -f $ofile ]
    then
        Log"fstabDiskToUUID: fstab file Location [$ofile ]is incorrect!!"
        return 1
    fi
    while read line
    do
       disk=`echo $line| awk '{print $1}'`
       disklink=`readlink -f $disk`
       found=1
       for i in `ls /dev/disk/by-uuid/`
       do
           if [ x`readlink -f /dev/disk/by-uuid/$i` == x$disklink ]
           then
               found=0
               uuid=`basename $i`
               echo $line|sed "s%$disk%UUID=$uuid%g" >> $nfile    #Used '%' as delimiter.Lets hope that '%' does not come in diskname,else it will break.
               break
           fi
       done
       if [ $found -eq 1 ]
       then
           echo $line >> $nfile
           ret=1
       fi
    done < $ofile
    return $ret
}

#Save Metadata of Software RAID devices
#   Name: SaveMd
#   API DEF:
#       exit: no
SaveMd(){
        mkdir -p $SYS_CONF/md_metadata
        cat /proc/mdstat > $SYS_CONF/md_metadata/mdstat.conf
        mdadm --detail --scan > $SYS_CONF/md_metadata/mdadm.conf
        cat $SYS_CONF/md_metadata/mdstat.conf | sed -e '/^Personalities/d' > $SYS_CONF/md_metadata/mdstat.temp
        cat $SYS_CONF/md_metadata/mdstat.temp | sed -e '/^unused/d' > $SYS_CONF/md_metadata/mdstat.temp.1
        cat $SYS_CONF/md_metadata/mdstat.temp.1 | sed -e '/^$/d' > $SYS_CONF/md_metadata/mdstat.temp
        cat $SYS_CONF/md_metadata/mdstat.temp | sed -e '/^\s/d' > $SYS_CONF/md_metadata/mdstat.temp.1
        mv $SYS_CONF/md_metadata/mdstat.temp.1 $SYS_CONF/md_metadata/mdstat.temp
        num=0
        while read i
        do
                mkdir -p $SYS_CONF/md_metadata/disk/$num
                folder=$SYS_CONF/md_metadata/disk/$num
                echo $i | awk '{print $1}' > $folder/name
                mdadm --misc --detail /dev/`cat $folder/name` > $folder/detail
                echo $i | awk '{print $3}' > $folder/status
                echo $i | awk '{print $4}' > $folder/type
                count=`echo $i | awk '{print NF}'`
                dcount=5
                while [ $dcount -le $count ]
                do
                        diskval=`echo $i | awk '{print $'"$dcount"'}'`
                        echo "$i:$dcount:$diskval"
                        disknum=`echo $diskval | cut -f2 -d'['|cut -f1 -d']'`
                        mkdir -p $folder/device/$disknum
                        echo $diskval | cut -f1 -d'[' > $folder/device/$disknum/name
                        dcount=$[$dcount +1]
                done
                num=$[$num +1]
        done < $SYS_CONF/md_metadata/mdstat.temp
}

#Find block device name for a device name:major#:minor# and upto level# specified
#   Name: findSysBlock
#   API DEF:
#       IN:             arg1=device_name(e.g. /dev/sda), arg2=major#, arg3=minor#, arg4=level
#       OUT:            block device from /sys/block or /sys/class/block OR empty string
#       EXIT:           no
findSysBlock()
{
    disk=$1
    maj=$2
    min=$3
    level=$4
    Log "findSysBlock : Looking for [$disk] [$maj:$min] till level [$level]"
    diskname=`basename $disk`
    if [ -z "$level" ]; then
        Log "findSysBlock: Assume level=2"
        level=2
    fi

    findopt=' -L '
    mkdir /tmp/_testdir_
    find -L /tmp/_testdir_ > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        Log "find does not support -L"
        findopt=""
    fi
    rm -rf /tmp/_testdir_
    # in Future, Save following information in Map instead of File(Currently Map is not supported in RH5 and RH4).
    if [ ! -f $SYS_CONF/devMinMajList_$level ]
    then
        list=`find $findopt /sys/block -maxdepth $level -name dev 2> /dev/null`
        for node in $list;
        do
            echo "`cat $node` $node" >> $SYS_CONF/devMinMajList_$level
        done
    fi
    node=`cat $SYS_CONF/devMinMajList_$level |grep -wE "^${maj}:${min}"|cut -f2 -d' '`
    Log "findSysBlock: Debug: return [`dirname $node`] for [$maj:$min] level=[$level]"
    echo "`dirname $node`"
}


# Execute the command and exit on failure
#   Name: Execute
#   API DEF:
#       IN:             arg1=command_string
#       OUT:            none
#       EXIT:           function will call exit with retcode '2' upon failures
Execute()
{
    Log "[Execute] cmd = [$@]"
    $@
    ret=$?
    Log "Return code=[$ret]"
    if [ $ret -ne 0 ]; then
        log="Error: execution of '$*' failed"
        Log "$log"
        echo "$log" > /tmp/srfailure_reason
        exit 2
    fi
}

# Execute the command and return errorcode on failure
#   Name: ExecuteRet
#   API DEF:
#       IN:             arg1=command_string
#       OUT:            retcode
#       EXIT:           no
ExecuteRet()
{
    Log "[ExecuteRet] cmd = [$@]"
    /bin/bash -c "$@"
    ret=$?
    Log "Return code=[$ret]"
    if [ $ret -ne 0 ]; then
        Log "Error: execution of '$*' failed"
    fi
    return $ret
}

# Execute the command and return result
#   Name: ExecFn
#   API DEF:
#       IN:             arg1=command_string
#       OUT:            command_result or empty string if failed
#       EXIT:           no
ExecFn()
{
    Log "Execfn: $*"
    val=`$@`
    ret=$?
    if [ $ret -ne 0 ]; then
        Log "Warning: $* failed!!"
        echo ""
    else
        Log "[$@] returns [$val]"
        echo -e "$val"
    fi
}

# Execute the command and return result and last status
#   Name: ExecFn
#   API DEF:
#       IN:             arg1=command_string
#       OUT:            command_result or empty string if failed
#       EXIT:           no
ExecFnRet()
{
    Log "Execfn: $*"
    local val
    local ret

    val=`$@`
    ret=$?
    if [ $ret -ne 0 ]; then
        Log "Warning: $* failed!!"
        echo ""
    else
        Log "[$@] returns [$val]"
        echo -e "$val"
    fi
    return $ret
}

#Extract the required value from the registry
#   Name: get_registry_value
#   API DEF:
#       IN:             arg1=reg_key_filename, arg2=key_name
#       OUT:            key_value or empty string
#       EXIT:           no
get_registry_value()
{
    Log "Debug: get_registry_value invoked with [$1][$2]"
    cat $1 | while read line
    do
        key=`echo $line | cut -d' ' -f1`
        if [ "$key" = "$2" ]; then
            echo $line | awk '{print $2}'
            Log "Debug: get_registry_value returns [`echo $line | awk '{print $2}'`]"
            break
        fi
    done
}

#Save kpartx delimiter in /tmp/kpartx_delim
#   Name: SaveKpartxDelimiter
#   API DEF:
#       IN:             none (udev rules assumed in /etc/udev/rules.d)
#       OUT:            delimiter saved in /tmp/kpartx_delim. defaults to 'p' if not found
#       EXIT:           no
SaveKpartxDelimiter()
{
    rule=`find /etc/udev/rules.d/ -type f -name "*multipath.rules"`
    if [ -z "$rule" ]; then
        rule=`find /usr/lib/udev/rules.d/ -type f -name "*multipath.rules"`
    fi
    if [ -n "$rule" ]; then
         cat $rule | grep -v "^[[:space:]]*#" | grep RUN | grep "kpartx -" | grep "\-p" | head -n 1 | awk -F ' -p ' '{print $2}' | awk '{print $1}'  | tr -d [\'] > /tmp/kpartx_delim
    fi

    if [ "a`cat /tmp/kpartx_delim 2>/dev/null`" == "a" ]; then
         rule=`find /etc/udev/rules.d/ -type f -name "*kpartx.rules"`
         if [ -z "$rule" ]; then
             rule=`find /usr/lib/udev/rules.d/ -type f -name "*kpartx.rules"`
         fi
         if [ -n "$rule" ]; then
              cat $rule | grep -v "^[[:space:]]*#" | grep RUN | grep "kpartx -" | grep "\-p" | head -n 1 | awk -F ' -p ' '{print $2}' | awk '{print $1}'  | tr -d [\'] > /tmp/kpartx_delim
         fi
    fi
    if [ "a`cat /tmp/kpartx_delim 2>/dev/null`" == "a" ]; then
         uname -r |grep -w el6
         if [ $? -eq 0 ]
         then
             echo "p" > /tmp/kpartx_delim
         fi
    fi
}

#List all mountpoints with storage device matching fixed regex
#   Name: ListFSTAB
#   API DEF:
#       IN:             none (check regex within, if certain mountpoints get ignored)
#       OUT:            list of mountpoints
#       EXIT:           no
ListFSTAB ()
{
    op=`mount -l|grep -E $SUPPORTED_DISK |awk '{print $3}'`
    Log "Debug: ListFSTAB : $op"
    mount -l|grep -E $SUPPORTED_DISK|awk '{print $3}'
}

#List all mountpoints with storage device matching fixed regex
#   Name: ListMountEntries
#   API DEF:
#       IN:             none (check regex within, if certain mountpoints get ignored)
#       OUT:            entire mount entry with device, mountpoint, type, options
#       EXIT:           no
ListMountEntries ()
{
    mount -l | grep -E $SUPPORTED_DISK
}

#List all swap partitions
#   Name: ListSwaps
#   API DEF:
#       IN:             none
#       OUT:            list of swaps
#       EXIT:           no
ListSwaps()
{
    op=`cat /proc/swaps | tail -n+2`
    Log "Debug: ListSwaps : $op"
    cat /proc/swaps | tail -n+2 | grep -v file
}

#Get major:minor numbers for device
#   Name: getDevMajMin
#   API DEF:
#       IN:             valid device node
#       OUT:            string value in the format <major#>:<minor#> OR empty string
#       EXIT:           no
getDevMajMin()
{
    dev=$1
    majx=`stat -L -c %t $dev`
    maj=$((0x$majx))
    minx=`stat -L -c %T $dev`
    min=$((0x$minx))
    if [ -z "$maj" -a -z "$min" ]; then
        Log "Error: Cannot stat [$dev] to obtain a valid maj:min number"
        echo ""
        return
    fi
    echo "$maj:$min"
}

#Returns the device type of disk
#   Name: getDeviceType
#   API DEF:
#       IN:             ARG1=disk device
#       OUT:            returns the device type
#       EXIT:           no
getDeviceType()
{
    disk=$1

    if [ -z "$disk" ]; then
        Log "Invalid device argument disk[$disk]"
        return 1
    fi

    majx=`stat -Lc %t $disk`
    maj=$((0x$majx))
    minx=`stat -Lc %T $disk`
    min=$((0x$minx))

    sysblock=`findSysBlock $disk $maj $min`
    if [ -z "$sysblock" ]; then
        Log "Failed to get sysblock dir name for device"
        echo ""
        return 1
    fi
  
#http://lkml.iu.edu/hypermail/linux/kernel/0602.1/1295.html 
    dev_type=`cat $sysblock/device/type`

    case "$dev_type" in 
        "0")
            echo "disk"
            ;;  
        "1")
            echo "tape"
            ;;
        "2")
            echo "printer"
            ;;
        "3")
            echo "processor"
            ;;
        "4")
            echo "worm"
            ;;
        "5")
            echo "rom"
            ;;
        *)
            echo "unknown"
            ;;
    esac
    return 0
}

#Returns the partition device name for a given disk and partition number
#   Name: getPartDevPath
#   API DEF:
#       IN:             ARG1=disk device ARG2=partnum
#       OUT:            construct the partition device name : e.g. /dev/sda, 1 => /dev/sda1 .. /dev/cciss/c0d0, 2 => /dev/cciss/c0d0p2 OR empty string
#       EXIT:           no
getPartDevPath()
{
    disk=$1
    part=$2

    if [ -z "$disk" -o -z "$part" ]; then
        Log "Invalid device argument disk[$disk] part[$part]"
        return 1
    fi

    if [ $part -eq 0 ]; then
        Log "Invalid device argument disk[$disk] part[$part]"
        return 0
    fi

    majx=`stat -Lc %t $disk`
    maj=$((0x$majx))
    minx=`stat -Lc %T $disk`
    min=$((0x$minx))

    sysblock=`findSysBlock $disk $maj $min`
    if [ -z "$sysblock" ]; then
        Log "Failed to get sysblock dir name for device"
        echo ""
        return 1
    fi

    if [ -d $sysblock/dm ]; then
        dm_name=`cat $sysblock/dm/name`
        Log "Disk[$disk] is a DM device, DM Name[$md_name]"
        del=`ls /dev/mapper/$dm_name* | sed "s#/dev/mapper/$dm_name##g" | grep -v ^$ | sed 's/[0-9]*//g' | head -n 1`
        disk="/dev/mapper/$dm_name"
        Log "Partition delimeter for disk [$disk] is ['$del']"
    else
        disk_name=`basename $sysblock`
        disk_name=`echo $disk_name|sed "s#^cciss\!#cciss/#g"`
        if [ -b "/dev/${disk_name}${part}" ]
        then
            Log "Found device [/dev/${disk_name}${part}]"
            echo "/dev/${disk_name}${part}"
            return 0
        fi
        del=`ls /dev/$disk_name* | sed "s#/dev/$disk_name##g" | grep -v ^$ | sed 's/[0-9]*//g' | head -n 1`
        disk="/dev/$disk_name"
        Log "Partition delimeter for disk [$disk] is ['$del']"
    fi

    device="${disk}${del}${part}"
    if [ ! -b $device ]; then
        Log "Partition device [$device] does not exist for disk [$disk], partnum [$part]"
        return 1
    fi

    echo $device
    return 0
}

#Check if mount point is a system moint point
#   Name: is_system_mntpt
#   API DEF:
#       IN:             ARG1=mount point path
#       OUT:            string value 1 if it is a system mount point otherwise 0
#       EXIT:           no
is_system_mntpt()
{
    echo $1 | grep -E "$SYS_MTPT2" | wc -l
}

#Check if mount point is boot moint point
#   Name: is_boot_mntpt
#   API DEF:
#       IN:             ARG1=mount point path
#       OUT:            string value 1 if it is a system mount point otherwise 0
#       EXIT:           no
is_boot_mntpt()
{
    echo $1 | grep -E "^/boot$|^/boot/efi$" | wc -l
}



#Get disk device name for maj#:min# (Only match disks not it's partitions)
#   Name: getDiskForMajMin
#   API DEF:
#       IN:             string in format maj#:min#
#       OUT:            string device name for disk, if found
#       EXIT:           no
getDiskForMajMin()
{
    Log "getDiskForMajMin: Debug: Looking for device with maj:min=[$1]"
    majmin=$1
    for dev in `ls /sys/block`;
    do
        if [ -e "/sys/block/$dev/dev" ]; then
            devmajmin=`cat /sys/block/$dev/dev`
            if [ -n "$devmajmin" ]; then
                if [ "$devmajmin" == "$majmin" ]; then
                    maj=`echo $majmin | cut -d':' -f1`
                    Log "getDiskForMajMin: Debug: Extracted major=[$maj]"
                    if [ "$maj" == "$DEV_DM" ]; then
                        name=`getDMname $dev`
                        Log "getDiskForMajMin: Debug: Found matching device [$name] for [$majmin]"
                        echo $name
                    else
                        Log "getDiskForMajMin: Debug: Found matching device [$dev] for [$majmin]"
                        moddev=`echo $dev | sed 's/\!/\//g'`
                        echo "/dev/$moddev"
                    fi
                    break
                fi
            fi
        fi
    done
}


#Get uuid for dm-XX device: wrapper that attempts to read off the uuid with the device name as is as well as with resolving soft links
#   Name: getDMuuid
#   API DEF:
#       IN:             device path (e.g. /dev/dm-xx)
#       OUT:            uuid if found, else empty string
#       EXIT:           no
getDMuuid()
{
    dev=$1

    uuid=$(getDMuuid_inner $dev)
    if [ -z "$uuid" ]; then
        if [ -L "$dev" ]; then
            dev=`readlink -f $1`
            Log "[$1] is a softlink - resolved to [$dev]"
            uuid=$(getDMuuid_inner $dev)
        fi
    fi
    echo $uuid
}


#Get uuid for dm-XX device
#   Name: getDMuuid_inner
#   API DEF:
#       IN:             device path (e.g. /dev/dm-xx)
#       OUT:            uuid if found, else empty string
#       EXIT:           no
getDMuuid_inner()
{
    dev=$1
    dmdev=$dev

    OLDLD=$LD_LIBRARY_PATH
    export LD_LIBRARY_PATH="$SRDIR:$LD_LIBRARY_PATH"
    Log "New LD_LIBRARY_PATH: [$LD_LIBRARY_PATH]"
    PARTINFO="$SRDIR/partinfo"
    cmd="$PARTINFO getDMuuid $dmdev"
    Log "DEBUG: Invoke command [$cmd]"

    dmuuid=`ExecFn $cmd`

    if [ -z "$dmuuid" ]; then
        dmdev=`basename $dev`

        cmd="$PARTINFO getDMuuid $dmdev"
        Log "DEBUG: Invoke command [$cmd]"

        dmuuid=`ExecFn $cmd`
    fi

    #replace space ' ' with '\x20'
    escdmuuid=${dmuuid// /"\\x20"}

    if [ -n "$dmuuid" ]; then
        Log "DEBUG: getDMuuid for [$dmdev] = [$dmuuid]==>[$escdmuuid]"
        echo "$escdmuuid"
    else
        Log "ERROR: getDMuuid for [$dmdev] CANNOT be read!"
        echo ""
    fi
    export LD_LIBRARY_PATH=$OLDLD
}

#Get DM name for uuid
#   Name: getDMnameForUUID
#   API DEF:
#       IN:             uuid
#       OUT:            dm name if found, else empty string
#       EXIT:           no
getDMnameForUUID()
{
    dmdev=`basename $1`

    OLDLD=$LD_LIBRARY_PATH
    export LD_LIBRARY_PATH="$SRDIR:$LD_LIBRARY_PATH"
    Log "New LD_LIBRARY_PATH: [$LD_LIBRARY_PATH]"
    PARTINFO="$SRDIR/partinfo"
    cmd="$PARTINFO getDMnameForUUID $dmdev"
    Log "DEBUG: Invoke command [$cmd]"

    dmname=`ExecFn $cmd`

    if [ -n "$dmname" ]; then
        Log "DEBUG: getDMnameForUUID for [$dmdev] = [$dmname]"
        echo "/dev/mapper/$dmname"
    else
        Log "ERROR: getDMnameForUUID for [$dmdev] CANNOT be read!"
        echo ""
    fi
    export LD_LIBRARY_PATH=$OLDLD
}

#Get name for dm-XX device : if we fail, iterate over devices in /dev/mapper to find which softlink points to this dm-XX device and fetch it's dm-name
#   Name: getDMname
#   API DEF:
#       IN:             device path (e.g. /dev/dm-xx)
#       OUT:            full path to '/dev/mapper/<device>' if found OR empty string if not found
#       EXIT:           no
getDMname()
{
    dev=$1

    name=$(getDMname_inner $dev)
    if [ -z "$name" ]; then
        for ln in `ls /dev/mapper`; do
            if [ -L "/dev/mapper/$ln" ]; then
                res=`readlink -f "/dev/mapper/$ln"`
                if [ -n "$res" -a "$res" == "$dev" ]; then
                    Log "getDMname: Debug: Found link [$res]->[$dev], attempting to read it's DMname"
                    name=$(getDMname_inner /dev/mapper/$ln)
                    break
                fi
            fi
        done
    fi
    echo $name
}

#Get name for dm-XX device
#   Name: getDMname_inner
#   API DEF:
#       IN:             device path (e.g. /dev/dm-xx)
#       OUT:            full path to '/dev/mapper/<device>' if found OR empty string if not found
#       EXIT:           no
getDMname_inner()
{
    dmdev=`basename $1`

    if [ "$dmdev" == "$1" ]; then
        dmdev="/dev/$dmdev"
    else
        dmdev="$1"
    fi
    Log "getDMname_inner: Debug: invoked with [$1]. Check for [$dmdev]"


    OLDLD=$LD_LIBRARY_PATH
    export LD_LIBRARY_PATH="$SRDIR:$LD_LIBRARY_PATH"
    Log "New LD_LIBRARY_PATH: [$LD_LIBRARY_PATH]"
    PARTINFO="$SRDIR/partinfo"
    cmd="$PARTINFO getDMname $dmdev"
    Log "DEBUG: Invoke command [$cmd]"

    dmname=`ExecFn $cmd`

    if [ -n "$dmname" ]; then
        Log "DEBUG: getDMname_inner for [$dmdev] = [/dev/mapper/$dmname]"
        echo "/dev/mapper/$dmname"
    else
        Log "ERROR: getDMname_inner for [$dmdev] CANNOT be read!"
        echo ""
    fi
    export LD_LIBRARY_PATH=$OLDLD
}

#Get name for dm-XX device if exists, else return name as is
#   Name: getDMnameWrapper
#   API DEF:
#       IN:             device path (e.g. /dev/dm-xx)
#       OUT:            full path to '/dev/mapper/<device>' if found OR input devicename if not found
#       EXIT:           no
getDMnameWrapper()
{
    in=$1
    out=`getDMname $in`
    if [ -z "$out" ]; then
        Log "getDMnameWrapper: DM name not found, return [$in]"
        echo $in
    else
        Log "getDMnameWrapper: DM name [$out] found for [$in]"
        echo $out
    fi
    return
}
#Check if device is a disk (not a partition/LV, etc
#   Name: isDisk
#   API DEF:
#       IN:             device path
#       OUT:            1 if disk, 0 otherwise
#       EXIT:           no
isDisk()
{
    device=$1
    OLDLD=$LD_LIBRARY_PATH
    export LD_LIBRARY_PATH="$SRDIR:$LD_LIBRARY_PATH"
    Log "New LD_LIBRARY_PATH: [$LD_LIBRARY_PATH]"
    PARTINFO="$SRDIR/partinfo"
    cmd="$PARTINFO isDisk $device"
    Log "DEBUG: Invoke command [$cmd]"

    isDisk=`ExecFn $cmd`

    if [ "$isDisk" == "1" ]; then
        Log "DEBUG: isDisk returned success[$device]"
        echo "1"
    else
        #DRBD is unsupported disk.So we don't care whether this device is valid or not as we will skip mountpoints on this disk.
        if [ "x"`echo $device|grep -E "$SKIPPED_IS_DISK_LIST"` != "x" ]
        then
            Log "Debug:[$device] is an unsupported Device!!"
            echo "1"
            export LD_LIBRARY_PATH=$OLDLD
            return
        fi
        Log "Error: isDisk returned error [$device]"
        echo "0"
    fi
    export LD_LIBRARY_PATH=$OLDLD
}

#Get PCI slot id for given device path
#    Name: getPCIId
#    API DEF:
#        IN:            string device path
#        OUT:            string PCI Id, empty if not found
#        EXIT:            no
getDevPCIId()
{
    device=$1
    devmajmin=`getDevMajMin $1`
    if [ -z "$devmajmin" ]; then
        Log "getDevPCIId: Error: Device major:minor numbers could not be found [$device]"
        echo ""
        return
    fi
    sysnode=`grep -l $devmajmin /sys/block/*/dev`
    if [ -z "$sysnode" ]; then
        Log "getDevPCIId: Error: sys block node for [$devmajmin] not found"
        echo ""
        return
    fi

    sysnode_d=`dirname $sysnode`/device
    sysnode_p=`readlink $sysnode_d`
    pciId=`basename $sysnode_p`

    if [ -x "$pciId" ]; then
        Log "getDevPCIId: Error: could not extract PCI id from link [$sysnode_p] of [$sysnode_d] of node [$sysnode]"
        echo ""
        return
    else
        Log "getDevPCIId: Debug: Extract PCI ID [$pciId] for [$device]"
        echo $pciId
    fi
}

#Get disk device name for any valid device name. Returns disk device for partition device
#   Name: getDiskForDev
#   API DEF:
#       IN:             string device path
#       OUT:            same as input if full disk; disk name if input is partition. Always appended with ':'<partnum> where <partnum>=0 for disk, >0 for partitions
#       EXIT:           no
getDiskForDev()
{
    device=$1
    which cryptsetup > /dev/null
    if [ $? -eq 0 ]
    then
        dmsetup ls --target crypt |grep -qw `basename $device`
        if [ $? -eq 0 ]
        then
            echo "$device:0"
            return
        fi
    fi
    if [[ $device == *"UUID="* ]]; then
        op=`blkid | tr -d \" | grep "$device" | head -n 1 | awk -F ":" '{print $1}'`
        ct=`blkid | tr -d \" | grep "$device" | wc -l`
        if [ $ct -gt 1 ]; then #could be multipath so all paths and mpath device will be listed in blkid
            ct=`blkid | tr -d \" | grep "$device" | grep "mapper" | wc -l`
            if [ $ct -ge 1 ]; then
                op=`blkid | tr -d \" | grep "$device" | grep "mapper" | head -n 1 | awk -F ":" '{print $1}'`
            fi
        fi
        if [ -z "$op" ]; then
            Log "Error: getDiskForDev: Failed to device name for $device! blkid=`blkid`"
            return
        fi
        device=$op
        Log "Debug: getDiskForDev: Converted device [$1] => [$device]"
    fi
    devmajmin=`getDevMajMin $device`
    if [ -z "$devmajmin" ]; then
        Log "Error: getDiskForDev: could not obtain a valid maj:min number for [$device]!"
        return
    fi
    maj=`echo $devmajmin | cut -d':' -f1`
    min=`echo $devmajmin | cut -d':' -f2`
    Log "getDiskForDev: Debug: for device [$device] maj=[$maj] min=[$min]"

    #IF device is a DM device, find it's DM-parent
    if [ "$maj" == "$DEV_DM" ]; then
        uuid=`getDMuuid $device`
        ispart=`echo $uuid | grep part`
        if [ -z "$ispart" ]; then
            #This could be a mpath disk or some other DM device! confirm once
            is_disk=`isDisk $device`
            if [ "$is_disk" == "1" ]; then
                Log "getDiskForDev: Debug [$device] is a DM disk."
                #if this is a /dev/dm-XX name, save it's persistent name

                pvdevmajmin=`getDevMajMin $device`
                if [ -z "$pvdevmajmin" ]; then
                    Log "Error: getUnderlyingDisks: could not obtain a valid maj:min number for [$device]!"
                    return
                fi
                pvmaj=`echo $pvdevmajmin | cut -d':' -f1`
                pvmin=`echo $pvdevmajmin | cut -d':' -f2`
                Log "getUnderlyingDisks: Debug: maj:min = [$pvmaj:$pvmin] for device=[$device]"
                if [ "$pvmaj" == "$DEV_DM" ]; then
                    device=`getDMname $device`
                fi
                partnum=0
                echo "$device:$partnum"
            else
                Log "getDiskForDev: Error: [$device] is not a parttition AND not a valid disk!"
                echo ""
            fi
        else
            #This is a DM partition device. Find it's parent disk
            partnum=`echo $uuid | grep part | cut -d'-' -f1 | sed -e 's/part//'`
            parentuuid=`echo $uuid | cut -d'-' -f2-`
            Log "getDiskForDev: Debug: Extract parent disk UUID[$parentuuid] for [$device][$uuid]"
            parentDisk=`getDMnameForUUID $parentuuid`
            if [ -n "$parentDisk" ]; then
                Log "getDiskForDev: Debug: parent disk for [$device]=[$parentDisk]. Partition#=[$partnum]"
                echo $parentDisk:$partnum
            else
                Log "getDiskForDev: Cannot find parent disk for [$device][$uuid]"
                echo ""
            fi
        fi
    else
        #XXX: hack. need a better way to find this
        node=`findSysBlock $device $maj $min 2`
        if [ -n "$node" ]; then
            Log "getDiskForDev: Debug: findSysBlock [$node] for [$device] level=2. Confirm isDisk"
            #second check
            is_disk=`isDisk $device`
            if [ "$is_disk" == "1" ]; then
                Log "getDiskForDev: Debug [$device] is a disk."
                partnum=0
                echo "$device:$partnum"
            else
                Log "getDiskForDev: Error: [$device] is not a parttition AND not a valid disk!"
                echo ""
            fi
        else
            #not found in top level /sys/block or /sys/class/block
            node=`findSysBlock $device $maj $min 3`
            if [ -n "$node" ]; then
                Log "getDiskForDev: Debug: findSysBlock [$node] for [$device] level=3. Confirm isDisk"
                #second check
                parentnode=`dirname $node`
                parentnode=`basename $parentnode`
                #for cciss disks, node[/sys/block/cciss!c0d0/cciss!c0d0p2] device [/dev/cciss/c0d0p2]
                #...parentnode so far 'cciss!c0d0'
                if [[ $parentnode =~ .*\!.* ]]; then
                    parentnode=${parentnode/\!//}        #...parentnode now 'cciss/c0d0'
                    parentnode_for_part=`basename $parentnode` # =[c0d0]
                else
                    parentnode_for_part=$parentnode
                fi
                if [ -e $node/partition ]; then
                    partnum=`cat $node/partition`
                else
                    dv=`basename $device`
                    partnum=${dv#*$parentnode_for_part}        # for cciss/mpath this may be p2. for sda, etc this should be just a number
                    if [ -f /tmp/kpartx_delim ]; then
                        delim=`cat /tmp/kpartx_delim`
                        if [[ $partnum =~ ${delim}.* ]]; then
                            partnum=${partnum#$delim}
                        fi
                    else
                        #check a few usual suspects
                        if [[ $partnum =~ "p".* ]]; then
                            partnum=${partnum#p}
                        elif [[ $partnum =~ "-part".* ]]; then
                            partnum=${partnum#-part}
                        fi
                    fi
                fi
                parentnode="/dev/$parentnode"
                Log "getDiskForDev: parentnode=[$parentnode]. Partition#=[$partnum]"
                is_disk=`isDisk $parentnode`
                if [ "$is_disk" == "1" ]; then
                    Log "getDiskForDev: Debug [$parentnode] is the disk for [$device]"
                    echo "$parentnode:$partnum"
                else
                    Log "getDiskForDev: Error: [$parentnode] is not a parttition AND not a valid disk for [$device]!"
                    echo ""
                fi
            fi
        fi
    fi
    return
}

#Get/Set disk serial number for disk
#   Name: diskSerial
#   API DEF:
#       IN:             device path (e.g. /dev/dm-xx) for a disk, arg2=get|set
#       OUT:            4 byte disk serial number in ascii readable format
#       EXIT:           no
diskSerial()
{
    dev=$1
    cmd=$2

    if [ -z $cmd -o -z $dev ]; then
        Log "Error: diskSerial invoked with invalid args [$dev][$cmd]"
        echo ""
        return
    fi
    if [ "$cmd" != "get" -a "$cmd" != "set" ]; then
        Log "Error: diskSerial invalid command [$cmd]"
        echo ""
        return
    fi

    OLDLD=$LD_LIBRARY_PATH
    export LD_LIBRARY_PATH="$SRDIR:$LD_LIBRARY_PATH"
    Log "New LD_LIBRARY_PATH: [$LD_LIBRARY_PATH]"
    PARTINFO="$SRDIR/partinfo"
    if [ "$cmd" == "get" ]; then
        command="$PARTINFO getDiskSerial $dev"
    else
        command="$PARTINFO setDiskSerial $dev"
    fi
    Log "DEBUG: Invoke command [$command]"

    serial=`ExecFn $command`

    if [ -n "$serial" ]; then
        Log "DEBUG: diskSerial for [$dev] = [$serial]"
        echo "$serial"
    else
        Log "ERROR: diskSerial for [$dev] CANNOT be found!"
        echo ""
    fi
    export LD_LIBRARY_PATH=$OLDLD
}
#getDMname()
#{
#    dmdev=$1
#    if [ -z "$dmdev" ]; then
#        echo ""
#    else
#        if [ -d "/sys/block/$dmdev/dm" ]; then #kernel version >= 2.6.29
#            dmname=`cat /sys/block/$dmdev/dm/name`
#            Log "getDMname: return /sys/block/$dmdev/dm/name as [$dmname]"
#            echo $dmname
#        else    #kernel version < 2.6.29
#            for dev in `ls /dev/mapper`;
#            do
#                Log "getDMname: DEBUG: legacy mode. Looking at $dev"
#                maj=`stat -c %t /dev/mapper/$dev`
#                Log "getDMname: DEBUG: legacy mode. maj=[$maj] for $dev"
#                if [ "x$maj" == "xfd" ]; then
#                    min=`stat -c %T /dev/mapper/$dev`
#                    Log "getDMname: DEBUG: legacy mode. min=[$min] for $dev"
#                    if [ "x$dmdev" == "xdm-$min" ]; then
#                        Log "getDMname: DEBUG: legacy mode. Found match [/dev/mapper/$dev] for $dmdev"
#                        echo "/dev/mapper/$dev"
#                    fi
#                fi
#            done
#        fi
#    fi
#}

#Get all underlying disks for a device.
#   Name: getUnderlyingDisks
#   API DEF:
#       IN:             arg1=string device path arg2=<filename> to store recreation information
#       OUT:            for LV: list of disks that make all PVs for it's VG
#                       for multipath disk: /dev/mapper/<name>
#                       for multipath disk partition: /dev/mapper/<name> of it's parent multipath disk
#                       for non LV/non multipath disk: device name
#                       for non LV/non multipath disk partition: device name of it's parent disk
#                   Empty string if any case above fails!
#                   recreaion information in one of the format:
#                       [1] LVM## VG=<name> PVs=<diskname>:<partition>,<distname>:<partition>,...,     OR
#                       [2] DISK## <diskname>:<partition>
#       EXIT:           no
getUnderlyingDisks()
{
    device=$1
    recreationinfofile=$2
    recreationinfo=""
    Log "getUnderlyingDisks: Debug: invoked with device=[$device]"

    which cryptsetup > /dev/null
    if [ $? -eq 0 ]
    then
        dmsetup ls --target crypt |grep -qw `basename $device`
        if [ $? -eq 0 ]
        then
            majver=`cryptsetup --version|head -n 1| awk '{print $NF}' | cut -f1 -d'.'`
            minver=`cryptsetup --version|head -n 1| awk '{print $NF}' | cut -f2 -d'.'`
            if [ -z "$majver" ]
            then
                Log "Could not find cryptsetup version!"
                echo ""
                return
            fi
            if [ -n "$majver" -a "$majver" == "1" ]
            then
                if [ -n "$minver" -a $minver -lt 6 ]
                then
                    Log "CryptSetup might not be supported.Please contact support"
                    echo ""
                    return
                fi
            fi
            founddiskName=`cryptsetup -v status $device|grep device:|awk '{print $2}'`
            resDisk=`getDiskForDev $founddiskName`
            if [ "x$resDisk" == "x" ]
            then
                resDisk="$founddiskName:lv"
            fi
            recreationinfo="LUKS## name=`basename $device` DISK=$resDisk"
            echo $recreationinfo >> $recreationinfofile
            Log "getUnderlyingDisks: Debug: Obtain disk [$founddisk] for luks encrypt disk [$device]"
            device=$founddiskName
        fi
    fi

    devmajmin=`getDevMajMin $device`
    if [ -z "$devmajmin" ]; then
        Log "Error: getUnderlyingDisks: could not obtain a valid maj:min number for [$device]!"
        return
    fi
    #this was the mounted device. It could be an LV/disk/partition
    #multipathed disks are returned as is. a separate validation should be done to check for slaves
    maj=`echo $devmajmin | cut -d':' -f1`
    min=`echo $devmajmin | cut -d':' -f2`
    Log "getUnderlyingDisks: Debug: maj:min = [$maj:$min] for device=[$device]"

    if [ "$maj" == "$DEV_DM" ]; then
        #re-write the device name as it could be /dev/dm-XX and lvdisplay will fail on it
        device=`getDMname $device`
        Log "getUnderlyingDisks: Debug: [$maj]:[$min] is DM. Changed device name to [$device]"
        is_lv=`lvdisplay -c | awk -v maj=$maj -v min=$min -F ":" '{if ($(NF-1)==maj && $NF==min) print $1}'`
        if [ -n "$is_lv" ]; then
            Log "getUnderlyingDisks: Debug: [$device] is a LV"
            vg_name=`lvdisplay -c | awk -v maj=$maj -v min=$min -F ":" '{if ($(NF-1)==maj && $NF==min) print $2}'`
            #vg_name=`lvdisplay $device 2>/dev/null | grep "VG Name" | awk '{print $3}'`
            if [ -z "$vg_name" ]; then
                Log "Error: VG Name could not be found for LV $device"
                return
            fi
            pv_list=`pvs | grep -w $vg_name 2>/dev/null | awk '{print $1}'`
            Log "Obtained PV list [$pv_list] for VG [$vg_name] having LV [$device]"
            recreationinfo="LVM## VG=$vg_name PVs="
            #echo $pv_list
            disk_list=""
            for pv in $pv_list;
            do
                Log "getUnderlyingDisks: Debug: process PV [$pv] from list [$pv_list]"
                founddiskN=`getDiskForDev $pv`
                recreationinfo="${recreationinfo}${founddiskN},"
                founddisk=`echo $founddiskN | cut -d':' -f1`
                partnum=`echo $founddiskN | cut -d':' -f2`
                Log "getUnderlyingDisks: Debug: founddisk[$founddisk] partition#=[$partnum] for [$pv]"
                if [ -z "$disk_list" ]
                then
                    disk_list=`getUnderlyingDisks $pv $recreationinfofile`
                else
                    disk_list="$disk_list\n"`getUnderlyingDisks $pv $recreationinfofile`
                fi
            done
            Log "getUnderlyingDisks: Debug: Obtained disk_list [$disk_list] for pv_list[$pv_list]"
            Log "getUnderlyingDisks: Set $recreationinfofile to value [$recreationinfo]"
            echo $recreationinfo >> $recreationinfofile
            echo -e $disk_list
            return
        else
            Log "getUnderlyingDisks: Debug: [$device] is NOT a LV"
            #Mounted device is a DM device but not an LV. It could be an mpath disk or partition
            dm_slaves_list=`ls /sys/block/dm-$min/slaves`
            dm_slave_found=0
            nondm_slave_found=0
            for dm_dev in $dm_slaves_list;
            do
                maj=`cat /sys/block/$dm_dev/dev | cut -d':' -f1`
                if [ "$maj" == "$DEV_DM" ]; then
                    dm_slave_found=$((dm_slave_found+1))
                else
                    nondm_slave_found=$((nondm_slave_found+1))
                fi
            done
            if [ $nondm_slave_found -gt 0 -a $dm_slave_found -gt 0 ]; then
                Log "getUnderlyingDisks: Error: both dm and non-dm slaves [$dm_slaves_list] found for $device. Cannot handle this device!"
                echo ""
                return
            elif [ $dm_slave_found -gt 0 ]; then
                #This will be treated as an mpath partition
                if [ $dm_slave_found -ne 1 ]; then
                    #A mpath partition should have only 1 dm slave device!
                    Log "getUnderlyingDisks: Error: multiple dm slaves [$dm_slaves_list] found for $device. Cannot handle this device!"
                    echo ""
                    return
                else
                    dm_parent_short=`ls /sys/block/dm-$min/slaves`
                    dm_parent=`getDMname $dm_parent_short`
                    Log "getUnderlyingDisks: Debug: dm_slaves=1 for [dm-$min]. dm_parent (underlying disk)=[$dm_parent]"
                    if [ -z "$dm_parent" ]; then
                        Log "getUnderlyingDisks: Error: Cannot obtain slave device's dm name for $dm_parent_short while looking at slaves of dm-$min"
                        echo ""
                        return
                    fi
                    foundDiskN=`getDiskForDev $device`
                    partnum=`echo $foundDiskN | cut -d':' -f2`
                    Log "getUnderlyingDisks: Debug: for DM partition [$device], obtained diskinfo[$foundDiskN] partition#=[$partnum]"
                    recreationinfo="DISK## $dm_parent:$partnum"
                    echo $recreationinfo >> $recreationinfofile
                    echo "$dm_parent"
                    return
                fi
            elif [ $nondm_slave_found -gt 0 ]; then
                #This will be treated as a full disk mpath device
                dm_parent=`getDMname dm-$min`
                if [ -z "$dm_parent" ]; then
                    Log "getUnderlyingDisks: Error: Cannot obtain slave device's dm name for dm-$min"
                    echo ""
                    return
                fi
                Log "getUnderlyingDisks: Debug: underlying disk =[$dm_parent]"
                recreationinfo="DISK## $dm_parent:0"
                echo $recreationinfo >> $recreationinfofile
                echo "$dm_parent"
                return

            else
                Log "getUnderlyingDisks: Error: No slave [$dm_slaves_list] dev found for $device. Cannot handle this device"
                echo ""
                return
            fi
        fi
    elif [ "$maj" == "$DEV_MD" ]
    then
        Log "getUnderlyingDisks: Debug: [$device] is a software Raid Device"
        recreationinfo="MD## NAME=$device DEV="
        disk_list=""
        basedev=`basename $device`
        path=`find $SYS_CONF/md_metadata/disk/*/name -type f -exec grep -wH $basedev {} \;|cut -f1 -d':'`
        path=`dirname $path`
        Log "getUnderlyingDisks: Debug: path[$path] for a software Raid Device[$basedev]"
        for adev in `cat $path/device/*/name`
        do
            dev=/dev/$adev
            Log "Found device[$dev]"
            founddiskN=`getDiskForDev $dev`
            recreationinfo="${recreationinfo}${founddiskN},"
            founddisk=`echo $founddiskN | cut -d':' -f1`
            partnum=`echo $founddiskN | cut -d':' -f2`
            Log "getUnderlyingDisks: Debug: founddisk[$founddisk] partition#=[$partnum] for [$dev]"
            if [ -z "$disk_list" ]; then
                disk_list=$founddisk
            else
                disk_list="$disk_list\n$founddisk"
            fi

        done
        Log "getUnderlyingDisks: Debug: Obtained disk_list [$disk_list] for device[$device]"
        Log "getUnderlyingDisks: Set $recreationinfofile to value [$recreationinfo]"
        echo $recreationinfo >> $recreationinfofile
        echo -e $disk_list
        return
    else
        #For all non-DM devices, assume that block dev with same major and minor=0 is the parent disk. Return it's name if it exists. In order to be sure, consult sysfs as well.
        founddiskN=`getDiskForDev $device`
        founddisk=`echo $founddiskN | cut -d':' -f1`
        partnum=`echo $founddiskN | cut -d':' -f2`
        Log "getUnderlyingDisks: Debug: non-dm device. underlying disk = [$founddisk]. partition#=[$partnum]"
        recreationinfo="DISK## $founddisk:$partnum"
        echo $recreationinfo >> $recreationinfofile
        Log "Check disk[$founddisk] is softRaid or not."
        echo $founddisk|grep -qE "^/dev/md"
        if [ $? -eq 0 ]
        then
            Log "disk[$founddisk] is softRaid."
            founddisk=`getUnderlyingDisks $founddisk $recreationinfofile`
        Log "Got following disks[$founddisk]."
        fi
        echo -e $founddisk
        return
    fi
}

#Get filesystem options
#   Name: getFsOpts
#   API DEF:
#       IN:             arg1=FSTYPE, arg2=device path, arg3=mountpoint name
#       OUT:            FS specific output of fs description commands
#       EXIT:           no
getFsOpts()
{
    fstype=$1
    dev=$2
    mnt=$3
    Log "getFsOpts: Debug: invoked with fstype=[$fstype] dev=[$dev] mnt=[$mnt]"

    case $fstype in
        "reiserfs")
            debugreiserfs $dev 2>/dev/null
            ;;
        "ext2")
            dumpe2fs -h $dev 2>/dev/null
            ;;
        "ext3")
            dumpe2fs -h $dev 2>/dev/null
            ;;
        "ext4")
            dumpe2fs -h $dev 2>/dev/null
            ;;
        "xfs")
            xfs_info $mnt 2>/dev/null
            xfs_io -x -c "resblks" $mnt 2>/dev/null
            ;;
        *)
            Log "Unknown fstype [$fstype]. Not trying to dump fs options"
            ;;
    esac
    return
}

#Initialize dm-multipath
#   Name: initMpath
#   API DEF:
#       IN:             arg1=FSTYPE, arg2=device path, arg3=mountpoint name
#       OUT:            FS specific output of fs description commands
#       EXIT:           no
#   Intended behavior: check pre-requisites and initialize multipath daemons. Use this as a starting point for vendor specific multipath support
initMpath()
{
    if [ -f /tmp/use_mpath_flag ]; then

        #some devices might not have SCSI_IDENT_* udev property in which case we should look for ID_SERIAL - adding this only if multipath.conf file does not already exist.
        #if it does, we may have to look at device specific blacklist options
        MCONF="/etc/multipath.conf"
        if [ ! -e $MCONF ]; then
            echo "blacklist_exceptions {" >> $MCONF
            echo "      property \"(ID_WWN|SCSI_IDENT_.*|ID_SERIAL)\"" >> $MCONF
            echo "}" >> $MCONF
        fi
        if [ -f /tmp/exclude_localdisks_mpath ]; then
            Log "User chose to exclude local disks from mpath"
            if [ -e /tmp/blacklist ]; then
                rm -f /tmp/bl_found
                if [ -e $MCONF ]; then
                    rm -f /tmp/blacklist.new
                    cat $MCONF | while read line
                    do
                        bret=`echo $line | grep -w "blacklist[ \t]*{"|grep -v "#"`
                        echo $line >> /tmp/blacklist.new
                        if [ "x$bret" != "x" ]; then
                            cat /tmp/blacklist >> /tmp/blacklist.new
                            touch /tmp/bl_found
                            Log "Inserted local disks in blaclist section"
                        fi
                    done
                    cp -f /tmp/blacklist.new $MCONF
                fi
                if [ ! -e /tmp/bl_found ]; then
                    Log "/etc/multipath.conf not found, OR no blacklist section could be parsed..add new"
                    echo "blacklist {" >> $MCONF
                    cat /tmp/blacklist >> $MCONF
                    echo "}" >> $MCONF
                fi
            fi
        fi

        BINDINGFILELOC="/etc/multipath/bindings"
        BINDINGFILECOPY="/tmp/bindings"
        if [ -e "/etc/multipath/bindings" ]; then
            \cp -f $BINDINGFILELOC $BINDINGFILECOPY
        elif [ -e "/var/lib/multipath/bindings" ]; then
            BINDINGFILELOC="/var/lib/multipath/bindings"
            \cp -f $BINDINGFILELOC $BINDINGFILECOPY
        fi

        Log "\nUser chose to configure multipath..."
        if [ -x /sbin/multipathd ]; then
             op=`modprobe dm-multipath 2>&1`
             ret=$?
             Log "loading dm-multipath - ret[$ret], result [$op]"

             mkdir /var/run 2>/dev/null
             op=`/sbin/multipathd 2>&1`
             ret=$?
             Log "starting multipathd - ret[$ret], result [$op]"
             sleep 5

             op=`multipath -v3 2>&1`
             ret=$?
             Log "Discover multipaths - ret[$ret], result \n $op \n. waiting for 10 seconds\n"
             sleep 10
        fi

        #old bindings file may be useful if some or all disks are same between backup and restore (inplace restore)
        #for out of place restore, we should delete the old entries so we can reuse the friendly names for new devices rather than name disks with a new name
        if [ -f $BINDINGFILECOPY ]; then
            Log "Debug: processing multipath bindings file $BINDINGFILECOPY (copied from $BINDINGFILELOC)"
            devicesmatchfound=0
            while read line
            do
                echo $line | grep -q "^[ \t]*#"
                if [ $? -ne 0 ]; then
                    friendlyname=`echo $line | awk '{print $1}'`
                    uuid=`echo $line | awk '{print $2}'`
                    Log "Debug: check [$friendlyname] [$uuid]"
                    # check if a device with this uuid is present or not
                    grep -w $uuid /sys/block/*/dm/uuid
                    if [ $? -eq 0 ]; then
                        Log "Debug: found device with uuid [$uuid]"
                        devicesmatchfound=1
                        break
                    fi
                fi
            done < $BINDINGFILECOPY

            if [ $devicesmatchfound -eq 0 ]; then
                Log "Debug: none of the mpath devices match with source. remove bindings file"
                rm -f $BINDINGFILELOC

                op=`multipath -F 2>& 1`
                Log "flush paths - result [$op]"
                sleep 5

                op=`multipath -v3 2>&1`
                Log "Discover multipaths - result \n $op \n. waiting for 10 seconds\n"
                sleep 10

            else
                Log "Debug: one or more mpath devices match with source. this is likely an in place restore. not removing bindings file"
            fi
        fi

        #Enumerate all mpath devices in the system
        Log "Extract multipath partition delimiter from udev rules"

        SaveKpartxDelimiter

        Log "Enumerated mpath devices. Discovered kpartx_delim [`cat /tmp/kpartx_delim`]"
    else
        Log "Skip mpath device configuration - User override"
    fi
}

# Create partition nodes
#   Name: CreatePartNodes
#   API DEF:
#       IN:             arg1=device name, arg2=partition spec file
#       OUT:            none
#       EXIT:           no
#   Intended behavior: Creates a device node for each partition listed in the spec file
#   FIXME: duplicated from srmountcreate.sh
#   FIXME: works for sfdisk style spec files
CreatePartNodes()
{
    Log "CreatePartNodes invoked with $1 $2"
    curdev=$1
    spec_file=$2
    str1=`ls -l $curdev | cut -d',' -f1`
    str2=`ls -l $curdev | cut -d',' -f2`
    MAJOR_NUM=`echo $str1 | awk '{print $NF}'`
    MINOR_NUM=`echo $str2 | awk '{print $1}'`
    PART_NUM=$((MINOR_NUM+1))
    cat $spec_file | grep "size" | while read line
    do
        nline=`echo $line | tr -d ' ' | grep -v "size=0"`
        if [ -z "$nline" ]; then
            continue
        fi
        set $line
        PART_NAME=$1
        NODE_NUM=$((MINOR_NUM+PART_NUM))
        if [ ! -e $PART_NAME ]; then
               Execute "mknod $PART_NAME b $MAJOR_NUM $PART_NUM"
        fi
        PART_NUM=$((PART_NUM+1))
    done
}

REDHAT="redhat"
SUSE="suse"
UBUNTU="ubuntu"
get_distribution()
{
    distribution=""
    if [ -e /tmp/MOUNTDIR/etc/ ]; then
        str=`cat /tmp/MOUNTDIR/etc/*release | grep -i "SUSE"`
        if [ "x$str" != "x" ]; then
            distribution=$SUSE
        else
            str=`cat /tmp/MOUNTDIR/etc/*release | grep -i "ubuntu|debian"`
            if [ "x$str" != "x" ]; then
                distribution=$UBUNTU
            else
                distribution=$REDHAT
            fi
        fi
    else
        distribution=`cat $SYS_STATE_LOC/distribution`
    fi
}

# Prepare chroot directory
#   Name: prepmount_cmd
#   API DEF:
#       IN:             none
#       OUT:            none
#       EXIT:           no
#   Intended behavior: bind mount sysfs/procfs/dev
#   FIXME: duplicated from common.sh
prepmount_cmd()
{
    if [ -d /tmp/MOUNTDIR ]; then
        mkdir -p /tmp/MOUNTDIR/proc /tmp/MOUNTDIR/sys /tmp/MOUNTDIR/dev
        mount --bind /proc /tmp/MOUNTDIR/proc
        mount --bind /sys /tmp/MOUNTDIR/sys
        mount --bind /dev /tmp/MOUNTDIR/dev
        if [ $? -ne 0 ]; then
            mount -t devtmpfs devtmpfs /tmp/MOUNTDIR/dev
            if [ $? -ne 0 ]; then
                cp -a /dev /tmp/MOUNTDIR
            fi
        fi
    fi
}

# Un-Prepare chroot directory
#   Name: prepumount_cmd
#   API DEF:
#       IN:             none
#       OUT:            none
#       EXIT:           no
#   Intended behavior: remove bind mount sysfs/procfs/dev
#   FIXME: duplicated from common.sh
prepumount_cmd()
{
    if [ -d /tmp/MOUNTDIR ]; then
        umount /tmp/MOUNTDIR/sys
        umount /tmp/MOUNTDIR/proc
        umount /tmp/MOUNTDIR/dev
    fi
}

#check for this in the script that sources this script
COMMON_FUNCS_SOURCED=1

