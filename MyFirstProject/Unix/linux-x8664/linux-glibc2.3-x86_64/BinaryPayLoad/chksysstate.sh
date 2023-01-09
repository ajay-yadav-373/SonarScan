#This script will validate the contents of the files in system state backup.
debug_mode=0

SYS_STATE_LOC=$1
TEST_SYS_STATE_LOG=$2/sysstatecheck.log

if [ -f /tmp/systemrecovery.debug ]; then
    debug_mode=1
fi

if [ ! -f $SYS_STATE_LOC/BOOTLOADER ]; then
    echo "BOOTLOADER file missing in $1" >> $TEST_SYS_STATE_LOG
    exit 2
fi

bl=`cat $SYS_STATE_LOC/BOOTLOADER | awk '{print $1}'`
if [[ "$bl" != "GRUB" ]] && [[ "$bl" != "LILO" ]] && [[ "$bl" != "ELILO" ]]; then
    echo "unsupported boot loader in $1" >> $TEST_SYS_STATE_LOG
    exit 2
fi

if [ $debug_mode -eq 1 ]; then
    echo "Found $bl BootLoader in $1" >> $TEST_SYS_STATE_LOG
fi

if [ ! -f $SYS_STATE_LOC/CLIENTSRDIR ]; then
    echo "CLIENTSRDIR file missing in $1" >> $TEST_SYS_STATE_LOG
    exit 2
fi

clsrdir=`cat $SYS_STATE_LOC/CLIENTSRDIR`
if [ $debug_mode -eq 1 ]; then
    echo "Found $clsrdir as the system recovery directory in $1" >> $TEST_SYS_STATE_LOG
fi

if [[ "$clsrdir" == "" ]] || [[ ! -d "$clsrdir" ]]; then
    echo "$clsrdir found as system recovery directory in $1 is not a valid directory" >> $TEST_SYS_STATE_LOG
    exit 2
fi

if [ ! -f $SYS_STATE_LOC/disks ]; then
    echo "disks file missing in $1" >> $TEST_SYS_STATE_LOG
    exit 2
fi

for disk in `cat $SYS_STATE_LOC/disks | awk '{print $2}' | tr -d ':'` 
do
    isdisk=`fdisk -l $disk | grep Disk | awk '{print $2}'`
    if [ $debug_mode -eq 1 ]; then
        echo "Found $isdisk in disks file on $1" >> $TEST_SYS_STATE_LOG
    fi
    if [ "$isdisk" == "" ]; then
        echo "$disk found in disks file on $1 is not a valid disk" >> $TEST_SYS_STATE_LOG
        exit 2
    fi
done

if [ ! -f $SYS_STATE_LOC/GALAXYLOGPATH ]; then
    echo "Galaxy Log path file missing from $1" >> $TEST_SYS_STATE_LOG
    exit 2
fi

glxylogpath=`cat $SYS_STATE_LOC/GALAXYLOGPATH`
if [ $debug_mode -eq 1 ]; then
    echo "Found $glxylogpath as galaxy log path in $1" >> $TEST_SYS_STATE_LOG
fi

if [ ! -d "$glxylogpath" ]; then
    echo "Galaxy Log path is $glxylogpath as per $1, but directory does not exit on system" >> $TEST_SYS_STATE_LOG
    exit 2
fi



#Check the validity of the contents of .vgcfg files 
vglist=`vgdisplay | grep "VG Name" | awk '{print $3}'`
for vg in $vglist; do
    vguid=`vgdisplay $vg | grep "VG UUID" | awk '{print $3}'`
    if [ ! -f $SYS_STATE_LOC/lvm_metadata/$vg.vgcfg ]; then
        echo "$vg.vgcfg file missing from $1" >> $TEST_SYS_STATE_LOG
        exit 2
    fi 
    vguidfound=`grep "$vguid" "$SYS_STATE_LOC/lvm_metadata/$vg.vgcfg" `
    if [ "$vguidfound" != "" ]; then
        if [ $debug_mode -eq 1 ]; then
            echo "VG UID $vguid exists in the $vg.vgcfg file"
        fi
    else
        echo "VG UID $vguid does not exist in the $vg.vgcfg file"
        exit 2
    fi

    lvuidlist=`vgdisplay -v $vg | grep "LV UUID" | awk '{print $3}'`
    for lvuid in $lvuidlist; do
        if [ ! -f $SYS_STATE_LOC/lvm_metadata/$vg.vgcfg ]; then
            echo "$vg.vgcfg file missing from $1" >> $TEST_SYS_STATE_LOG
            exit 2
        fi 
        lvuidfound=`grep "$lvuid" "$SYS_STATE_LOC/lvm_metadata/$vg.vgcfg"`
        if [ "$lvuidfound" != "" ]; then
            if [ $debug_mode -eq 1 ]; then
                echo "LV UID $lvuid exists in the $vg.vgcfg file"
            fi
        else
            echo "LV UID $lvuid does not exist in the $vg.vgcfg file"
            exit 2
       fi
    done
done

pvlist=`pvdisplay | grep "PV Name" | awk '{print $3}'`
for pv in $pvlist; do
    pvdisplay $pv > /tmp/pv.pvcfg.$$
    pvuid=`cat /tmp/pv.pvcfg.$$ | grep "PV UUID" | awk '{print $3}'`
    pvuidfound=`grep $pvuid "$SYS_STATE_LOC/lvm_metadata/pvs.list"`
    if [ "$pvuidfound" != "" ]; then
        if [ $debug_mode -eq 1 ]; then
            echo "PV UUID $pvuid exists in the pvs.list file"
        fi
    else
        echo "PV UUID $pvuid does not exist in the pvs.list file"
        rm -f /tmp/pv.pvcfg.$$
        exit 2
    fi
done

rm -f /tmp/pv.pvcfg.$$

if [ ! -f $SYS_STATE_LOC/mountlist ]; then
    echo "mountlist file missing from $1" >> $TEST_SYS_STATE_LOG
    exit 2
fi

mountpart=`cat $SYS_STATE_LOC/mountlist | awk '{print $1}'`
for part in $mountpart; do
    if [ $debug_mode -eq 1 ]; then
        echo "Found $part in mountlist from $1" >> $TEST_SYS_STATE_LOG
    fi
    dd if="$part" of=/dev/null count=1
    if [[ $? -ne 0 ]]; then
        echo "Invalid partition $part in mount list from $1" >> $TEST_SYS_STATE_LOG
        exit 2    
    fi
done 

disklist=`ls $SYS_STATE_LOC/partition_info/*.out`
if [[ disklist == "" ]]; then
    echo "No File containing disk partitions exists in $1" >> $TEST_SYS_STATE_LOG
    exit 2
fi
for disk in $disklist; do
    #Create a list of empty partitions on the disk 
    phy_disk=`cat $disk | grep "partition" | awk '{ print $5}'`
    empty_list=`sfdisk -l $phy_disk | grep "Empty" | cut -d' ' -f1`
    echo "found $empty_list empty partition list for $phy_disk"
    partlist=`cat $disk | grep "/dev/" | grep ":" | cut -d':' -f1`
    for part in $partlist; do
        if [ $debug_mode -eq 1 ]; then
            echo "A disk partition $part is found in $disk file in $1" >> $TEST_SYS_STATE_LOG
        fi
        isempty=`echo "$empty_list" | grep "$part"`
        if [ "$isempty" != "" ]; then
            echo "Found a empty disk partition $part in $disk file in $1" >> $TEST_SYS_STATE_LOG
        else 
            dd if=$part of=/dev/null count=1
            if [[ $? -ne 0 ]]; then
                echo "Invalid partition $part found in $disk file in $1" >> $TEST_SYS_STATE_LOG
            fi
        fi
    done 
done

if [[ ! -f $SYS_STATE_LOC/systemconf.log ]]; then
    echo "systemconf.log file not found in $1" >> $TEST_SYS_STATE_LOG
    exit 2
fi 
disklist=`cat $SYS_STATE_LOC/disk_lvm_files/ide_disks.lst | grep "name" | awk '{print $2}'`
for ide_disk in $disklist; do
    dd if=$ide_disk of=/dev/null count=1
    if [[ $? -ne 0 ]]; then
         echo "Invalid IDE disk $ide_disk found in ide_disks.lst file in $1" >> $TEST_SYS_STATE_LOG 
    else  
        if [ $debug_mode -eq 1 ]; then
            echo "A IDE disk with name $ide_disk found in ide_disks.lst in $1 file exists in the system" >> $TEST_SYS_STATE_LOG 
        fi  
    fi
done

disklist=`cat $SYS_STATE_LOC/disk_lvm_files/scsi_disks.lst | grep -w "name" | awk '{print $2}'`
for scsi_disk in $disklist; do
    dd if=$scsi_disk of=/dev/null count=1
    if [[ $? -ne 0 ]]; then
         echo "Invalid SCSI disk $scsi_disk found in scsi_disks.lst file in $1" >> $TEST_SYS_STATE_LOG 
    else  
        if [ $debug_mode -eq 1 ]; then
            echo "A SCSI disk with name $scsi_disk found in scsi_disks.lst in $1 file exists in the system" >> $TEST_SYS_STATE_LOG 
        fi  
    fi
done

#Parse through list of mountpoints, find if a mountpoint is a system mountpoint and ensure that its underyling disk is not removable. If so, mark it not-removable!
echo "Set 'removable' to 0 for all disks that have system mountpoints" >> $TEST_SYS_STATE_LOG
if [ ! -e ./onetouchutil ]; then
    cp ./systemrecovery/bootimage/INITRD/onetouchutil .
fi
chmod --reference="./systemrecovery/bootimage/INITRD/onetouchutil" onetouchutil
util="./onetouchutil"
mountlst=`cat $SYS_STATE_LOC/mountlist | awk '{print $2}'`
for mount in $mountlst; do
    disk=""
	if [ "$mount" == "/" -o "$mount" == "/boot" -o "$mount" == "/usr" -o "$mount" == "/lib" -o "$mount" == "/var" -o "$mount" == "/opt" -o "$mount" == "swap" ]; then
        echo "Found a mountpoint [$mount]" >> $TEST_SYS_STATE_LOG
		dev=`cat $SYS_STATE_LOC/mountlist | grep -w "$mount" | awk '{print $1}'`	
        #device can be a SCSI,IDE,MPATH disk or its partition OR an LV
        is_mapper=`echo $dev | grep "/dev/mapper"`
        if [ "x$is_mapper" != "x" ]; then
            echo "underlying dev [$dev] for mountpoint [$mount] is a /dev/mapper device" >> $TEST_SYS_STATE_LOG
            vg=`$util vgname $dev`
            is_vg=`cat $SYS_STATE_LOC/lvm_metadata/pvs.list | grep $vg`
            if [ "x$is_vg" != "x" ]; then
                disk=`cat $SYS_STATE_LOC/lvm_metadata/pvs.list | grep $vg | awk '{print $1}'`
                disk=`$util diskname $disk`
                echo "underlying dev [$dev] for mountpoint [$mount] has valid PV with diskname [$disk]" >> $TEST_SYS_STATE_LOG
            else
                #this can be a multipath device - but we don't expect to see a removable multipath disk. skip checking further
                echo "found device [$dev] which is not an LV" >> $TEST_SYS_STATE_LOG
            fi
        else
            echo "checking if device [$dev] exists" >> $TEST_SYS_STATE_LOG
            if [ -e "$dev" ]; then
                disk=`$util diskname $dev`
                echo "device [$dev] exists and diskname [$disk]" >> $TEST_SYS_STATE_LOG
            fi
        fi
	fi
    if [ "x$disk" != "x" ]; then
        diskname=`basename $disk`
        echo $diskname >> $SYS_STATE_LOC/override_removable
    fi
done
cat $SYS_STATE_LOC/override_removable | sort -u > $SYS_STATE_LOC/override_removable_unq
for disk in `cat $SYS_STATE_LOC/override_removable_unq`; do
    echo "Looking for disk [$disk] to turn removable=0" >> $TEST_SYS_STATE_LOG
    #check for /tmp/sysconfig/disk_tree/disk_config/disk/scsi/<disk>/removable
    if [ -e $SYS_STATE_LOC/disk_tree/disk_config/disk/ide/$disk/removable ]; then
        echo "found and set removable=0 for IDE disk [$disk]" >> $TEST_SYS_STATE_LOG
        echo "0" > $SYS_STATE_LOC/disk_tree/disk_config/disk/ide/$disk/removable
    elif [ -e $SYS_STATE_LOC/disk_tree/disk_config/disk/scsi/$disk/removable ]; then
        echo "found and set removable=0 for SCSI disk [$disk]" >> $TEST_SYS_STATE_LOG
        echo "0" > $SYS_STATE_LOC/disk_tree/disk_config/disk/scsi/$disk/removable
    elif [ -d $SYS_STATE_LOC/disk_tree/disk_config/disk/mpath/$disk ]; then
        echo "found MPATH disk [$disk]" >> $TEST_SYS_STATE_LOG
        for mdisk in `ls $SYS_STATE_LOC/disk_tree/disk_config/disk/mpath/$disk/devices`; do
            echo "mdisk"          
            if [ -e $SYS_STATE_LOC/disk_tree/disk_config/disk/scsi/$mdisk/removable ]; then
                echo "found and set removable=0 for SCSI disk [$mdisk] since its a path for [$disk]" >> $TEST_SYS_STATE_LOG
                echo "0" > $SYS_STATE_LOC/disk_tree/disk_config/disk/scsi/$disk/removable
            fi
        done
    fi
done

exit 0
