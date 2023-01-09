#!/bin/bash

LOGFILE="/tmp/create_1tchbootcd.log" #updated once we have log dir location
INSTANCE="Instance001"               #can be updated. command line arg 'i'
COPY_PREC=0                          #can be updated. command line arg 'p'
MODE=0                               #can be updated. command line arg 'm' 0=interactive, 1=silent,2=debug
BKPSET_NAME="defaultBackupSet"       #can be updated. command line arg 'b'
DISPTOTIME=`date +"%Y/%m/%d %H:%M:%S"`
TOTIME="[browseto]\n$DISPTOTIME"     #can be updated. command line arg 't'

SRC_CLIENTNAME=""                    #must be updated. command line arg 's'
DST_CLIENTNAME=""                    #can be updated. command line arg 'd' defaults to client from which this script is executed. OPTION IS RESERVED FOR internal use.
CS_HOSTNAME=""                       #must be updated. command line arg 'c'
USERNAME=""                          #must be updated. command line arg 'u'
PASSWORD=""                          #can be updated. command line arg 'o'
ENCRYPTEDPASSWORD=""                 #can be updated. command line arg 'e'
DVD4FILE=""                          #must be udpated. command line arg 'n'
SCRIPT_DIR=`pwd`/1touch_uefi
BOOTCD_FILE=""                       #Optional. Can be used for give location of bootcd.tar.gz
DEST_DVDLOC=`pwd`                     # Optional. Location where final DVD will be stored
UEFI_FILES_VER=1                     #Optional. Command line arg 'v' to be used to include new version of UEFI files. 1=ver1 (default), 2=ver2
mkdir -p $SCRIPT_DIR
ARGS_FILE="$SCRIPT_DIR/sysstate.input"

parg=""                 

#FUNCS

Log()
{
    DATE=`date +%D' '%H:%M:%S`
    echo "${DATE} ${FUNCNAME[1]}@${BASH_SOURCE[0]} ${BASH_LINENO[0]} $*" >> $LOGFILE
}
LogS()
{
    echo -e "$*" | tee -a $LOGFILE
}

get_registry_value()
{
    cat $1 | while read line
    do
        key=`echo $line | cut -d' ' -f1`
        if [ "$key" = "$2" ]; then 
            echo $line | awk '{print $2}'
            break
        fi   
    done 
}

parse_args()
{
    while getopts "m:s:d:p:b:i:c:u:o:e:t:n:r:f:l:v:" opt; do
        case $opt in
            m)
                #mode silent or interactive
                MODE=$OPTARG        #0=interactive 1=silent
                ;;
            s)
                #src client
                SRC_CLIENTNAME=$OPTARG
                ;;
            d)
                #dst client
                DST_CLIENTNAME=$OPTARG
                ;;
            p)
                #copy precedence
                COPY_PREC=$OPTARG
                ;;
            b)
                #backupset
                BKPSET_NAME=$OPTARG
                ;;
            i)
                #instance on this machine
                INSTANCE=$OPTARG
                ;;
            c)
                #CS host name
                CS_HOSTNAME=$OPTARG
                ;;
            u)
                #CS username
                USERNAME=$OPTARG
                ;;
            o)
                #CS password
                PASSWORD=$OPTARG
                ;;
            e)
                #encrypted CS password
                ENCRYPTEDPASSWORD=$OPTARG
                ;;
            t)
                #time to restore
                TOTIME=$OPTARG
                ;;
            f)
                #Use this bootcd.
                BOOTCD_FILE=$OPTARG
                ;;
            r)
                #change file in stage DVD
                REPLACINGFILE=$OPTARG
                ;;
            n)
                #Input DVD4.iso location
                DVD4FILE=$OPTARG
                ;;
            l)
                # Final location to place the DVD in(Only Absolute path)
                DEST_DVDLOC=`readlink -f $OPTARG`
                ;;
            v)
                #Version of UEFI files to use
                UEFI_FILES_VER=$OPTARG
                ;;
            \?)
                # Invalid args point to usage
                usage
                exit 1
                ;;

        esac
    done
}

validate_args()
{
    if [ -z "$DST_CLIENTNAME" ]; then
        file="/etc/CommVaultRegistry/Galaxy/$INSTANCE/.properties"
        if [ -f $file ]; then 
            DST_CLIENTNAME=`get_registry_value $file "sPhysicalNodeName"`
        fi    
    fi

    if [ -z "$CS_HOSTNAME" ]; then
        file="/etc/CommVaultRegistry/Galaxy/$INSTANCE/CommServe/.properties"
        if [ -f $file ]; then
            CS_HOSTNAME=`get_registry_value $file "sCSHOSTNAME"`
        fi
    fi
    
    if [ -z "$SRC_CLIENTNAME" -o \
         -z "$DST_CLIENTNAME" -o \
         -z "$CS_HOSTNAME"    -o \
         -z "$USERNAME"       ]; then
        return 1
    fi

    if [ -z "$DVD4FILE" ]; then
        LogS "ERROR: Missing DVD4.iso path [-n]"
        return 1
    fi

    if ! [ -d "$DEST_DVDLOC" ]; then
        LogS "ERROR: Missing directory to store final DVD in [-l] : ${DEST_DVDLOC}"
        return 1
    fi

    UEFIFILENAME="uefi_files.tgz"
    if [ $UEFI_FILES_VER -eq 2 ]; then
        UEFIFILENAME="cv_uefi_files_v2.tgz"
    fi
    if [ ! -f "$BASEDIR/../iDataAgent/systemrecovery/$UEFIFILENAME" ]; then
        LogS "Missing files - $BASEDIR/../iDataAgent/systemrecovery/$UEFIFILENAME"
        LogS "1touch_unified creation scripts not found. Missing updates?"
        return 1
    else
        cd $SCRIPT_DIR
        tar zxf ../$UEFIFILENAME
        cd - > /dev/null
    fi

#    test_mkisofs=`mkisofs --version | grep -q genisoimage`
#    if [ $? -ne 0 ]; then
#        LogS "mkisofs not found or too old! genisoimage 1.09+ required"
#        return 1
#    fi

    if [ -z "$PASSWORD" ] && [ -z "$ENCRYPTEDPASSWORD" ] && [ $MODE -ne 1 ]
    then
        echo -n "Enter Password:"
        read -s PASSWORD
        echo ""
    fi
    if [ -z "$PASSWORD" ]; then
        if [ -n "$ENCRYPTEDPASSWORD" ]; then
            parg=" -ps $ENCRYPTEDPASSWORD"
        else
            parg=" -p "
        fi
    else
        cd $BASEDIR
        if [ ! -e ./onetouchutil ]; then
            cp ../iDataAgent/systemrecovery/bootimage/INITRD/onetouchutil .
        fi

        if [ -e "../iDataAgent/systemrecovery/bootimage/INITRD/onetouchutil" ]; then
            #Copy onetouchutil binary if current directory version is not same as source location
            md5_src=`md5sum "../iDataAgent/systemrecovery/bootimage/INITRD/onetouchutil" | awk '{print $1}'`
            md5_dest="0"
            if [ -e "./onetouchutil" ]; then
                md5_dest=`md5sum "./onetouchutil" | awk '{print $1}'`
            fi
            if [ $md5_src != $md5_dest ]; then
                cp -f "../iDataAgent/systemrecovery/bootimage/INITRD/onetouchutil" .
            fi
        fi

        chmod --reference="../iDataAgent/systemrecovery/bootimage/INITRD/onetouchutil" onetouchutil
        epswd=`./onetouchutil encrypt "$PASSWORD" 2> /dev/null`
        parg=" -ps $epswd"
        cd - > /dev/null
    fi

    return 0
}

usage()
{
#Log "USAGE: $0 [-m <mode>] -s <src_client> [-d <dst_client>] -c <cs_hostname> -u <csusername> [-s <cspassword>] [-p <copy precedence>] [-b <backupsetname>] [-i <instance>] [-t <totime>]"
    LogS "USAGE: $0 [-m <mode>] -s <src_client> [-d <dst_client>] -c <cs_hostname> -u <csusername> [-o <cspassword>] [-p <copy precedence>] [-b <backupsetname>] [-i <instance>] [-t <totime>] [-r <sourcefile used during restore>=<destination of source file wrt root of DVD>] -n <dvd4.iso path> [-l <dest_directory>] [-v 2]"
    LogS "       ... mode: 0=interactive(default) 1=silent"
    LogS "       ... instance: instance on current machine"
    LogS "       ... totime: for job restore in format YYYY/MM/DD hh:mm:ss"
    LogS "       ... -d defaults to client on which this script is executed on"
    LogS "       ... -l directory to store final DVD on. Defaults to iDataAgent"
    LogS "       ... -v defaults to version 1 of UEFI files to be included in ISO"
}

exitfn()
{
    retcode=$1
#Perform qlogout, ignoring errors if any
    cd $BASEDIR
    ./qlogout

    exit $retcode
}

list_jobs_set_totime()
{
    if [ $MODE -ne 1 ]; then
        #Get system state jobs
        LogS "Obtaining list of system state backup jobs for client $SRC_CLIENTNAME"
        Log "./qlist jobhistory -c $SRC_CLIENTNAME -b $BKPSET_NAME -a Q_LINUX_FS -optype SystemState -dispJobTime > /tmp/joblist01"
        ./qlist jobhistory -c $SRC_CLIENTNAME -b $BKPSET_NAME -a Q_LINUX_FS -optype SystemState -dispJobTime > /tmp/joblist01
        if [ $? -ne 0 ]; then
            Log "Failed to retrieve list of system state jobs!"
            exitfn 1
        fi

        Log "Obtained list of system state backup jobs. Processing them now..."
        cat /tmp/joblist01 | grep ^[0-9] | grep Completed | grep -iv error | tr -s / - | awk '{print $(NF-3),$(NF-2),$1,$(NF-1),$(NF)}' > /tmp/joblist02
        sort -nr /tmp/joblist02 > /tmp/joblist03

        FILE="/tmp/syslist"
        rm -f $FILE
        while read -r
        do
            jobid=`echo $REPLY | awk '{print $3}'`
            if [ $jobid -eq -1 ]; then
            break;
            fi  
            echo $REPLY | awk '{print $3, $1, $2, $4, $5}' >> $FILE
        done < /tmp/joblist03
        cat /tmp/syslist | tr '\t' ' '| tr -d '-' | tr -d ':' | tr -d '.' | sort -k4,5 -r | awk '{print $1}' > /tmp/syslist_sortkeys
        rm -f /tmp/syslist_sorted
        while read key
        do
            val=`grep -w $key /tmp/syslist 2>/dev/null`
            if [ -n "$val" ]; then
                echo $val >> /tmp/syslist_sorted
            fi
        done < /tmp/syslist_sortkeys
        tr -d '\r' < /tmp/syslist_sorted >$FILE

        cat $FILE | tr -s '-' '/' > /tmp/syslist.$$
        mv /tmp/syslist.$$ $FILE

        Log "Processed list of system state jobs is [`cat $FILE`]"

        while [ 1 ];
        do
            i=0
            TIME[0]=""
#e.g.
#1 =>   927 2014/01/09 09:08:29 2014/01/09 09:11:40
            LogS "      JobID   StartDate/Time          EndDate/Time"
            LogS "-----------------------------------------------------"
            while read line
            do
                i=$(($i+1))
                LogS "$i =>   $line"
                TIME[$i]=`echo $line | cut -d ' ' -f4-5`
            done < $FILE
            LogS "Select a job from the list above [1-$i] : "
            read selection
            selection=`echo $selection | tr -cd [:digit:]`
            LogS "Updated selection to $selection"

            if [ -n "$selection" -a "$selection" -ge 1 -a "$selection" -le $i ]; then
                TOTIME="[browseto]\n${TIME[$selection]}"    #can be updated. command line arg 't'
                DISPTOTIME=${TIME[$selection]}
                break
            else
                LogS "\n\tincorrect selection. Try again...\n"
            fi
        done 
        LogS "Use time [$DISPTOTIME] to fetch system state backup"
        
    else
        LogS "Non interactive mode. Use time [$DISPTOTIME] to fetch system state backup"
    fi 
}

create_qcmd_input()
{
    FILE_TO_RESTORE="/tmp/bootcd.tar.gz"

    echo "[sourceclient]" > $ARGS_FILE      #Notice the single >
    echo "$SRC_CLIENTNAME">> $ARGS_FILE
    echo "[dataagent]" >> $ARGS_FILE
    echo "Q_LINUX_FS" >> $ARGS_FILE
    echo "[backupset]" >> $ARGS_FILE
    echo "$BKPSET_NAME" >> $ARGS_FILE
    echo "[destinationclient]" >> $ARGS_FILE
    echo "$DST_CLIENTNAME">> $ARGS_FILE
    echo "[sourcepaths]" >> $ARGS_FILE
    echo "$FILE_TO_RESTORE" >> $ARGS_FILE
    echo "[streamcount]" >> $ARGS_FILE
    echo "1" >> $ARGS_FILE
    echo "[copyprecedence]" >> $ARGS_FILE
    echo "$COPY_PREC" >> $ARGS_FILE
    echo "[priority]" >> $ARGS_FILE
    echo "66" >> $ARGS_FILE
    echo "[backuplevel]" >> $ARGS_FILE
    echo "0" >> $ARGS_FILE
    echo "[jobstatus]" >> $ARGS_FILE
    echo "0" >> $ARGS_FILE
    echo "[destinationpath]" >> $ARGS_FILE
    echo "$SCRIPT_DIR" >> $ARGS_FILE
    echo "[browseto]" >> $ARGS_FILE
    echo "$DISPTOTIME" >> $ARGS_FILE
    echo "[options]" >> $ARGS_FILE 
    echo "QR_UNCONDITIONAL" >> $ARGS_FILE
    echo "QR_PRESERVE_LEVEL" >> $ARGS_FILE
    echo "QR_RESTORE_ACLS" >> $ARGS_FILE
    echo "QR_SKIP_AND_CONTINUE" >> $ARGS_FILE
    echo "QR_RECOVER_POINT_IN_TIME" >> $ARGS_FILE
}

invoke_monitor_restore()
{
    cd $BASEDIR
    jobid=`./qoperation restore -af $ARGS_FILE`
    if [ -z "$jobid" ]; then
        Log "Failed to launch job to restore system state"
        exitfn 2
    fi
    while [ 1 ];
    do
        jrstatus=`./qlist job -co s -j $jobid | tail -n 1`
        jstatus=`echo $jrstatus | tr -d [:blank:]`
        Log "status = [$jstatus]"
        pstatus=`./qlist job -j $jobid`
        LogS "$pstatus"
        if [ "$jstatus" == "Running" -o "$jstatus" == "Pending" -o "$jstatus" == "Restore" ]; then
            sleep 10
        else
            echo $jstatus | grep -qi "fail"
            if [ $? -eq 0 ]; then
                LogS "Job Failed [$jstatus]!"
                exitfn 3
            fi
            echo $jstatus | grep -qi "kill"
            if [ $? -eq 0 ]; then
                LogS "Job Killed [$jstatus]!"
                exitfn 3
            fi
            echo $jstatus | grep -qi "suspend"
            if [ $? -eq 0 ]; then
                LogS "Job Suspended [$jstatus]!"
                exitfn 3
            fi
            echo $jstatus | grep -qi "complete"
            if [ $? -eq 0 ]; then
                LogS "Job Completed [$jstatus]"
                break
            fi
        fi
    done
    cd - > /dev/null
}

create_dvd()
{
    LogS "\n----===[ Start creation of DVD4 for ${SRC_CLIENTNAME} ]===----\n"
    cd $SCRIPT_DIR

#Step 1: mount the input DVD4.iso        
    LogS "Mount input DVD4.iso using [$DVD4FILE]...\n"
    umount dvd4input 2>/dev/null   #prevously mounted?
    mkdir -p dvd4input
    mount -oro,loop $DVD4FILE dvd4input
    if [ $? -ne 0 ]; then
        LogS "Failed to mount $DVD4FILE... aborting"
        exitfn 4
    fi

#Step 2: create a copy since we need to modify the contents
    LogS "Copy DVD4 contents (this will take a while)...\n"
    rm -rf dvd4output; mkdir -p dvd4output
    cp -a dvd4input/* dvd4output/

#Step 3: extract stage1 initrd for scripts & copy sh|ycp to new dvd.
    LogS "Extract stage-1 initrd...\n"
    rm -rf stage1_initrd; mkdir -p stage1_initrd; cd stage1_initrd
    zcat ../dvd4input/isolinux/initrd.img | cpio -dim
    mkdir ../dvd4output/stage1scripts
    cp -a *.sh ../dvd4output/stage1scripts ###XXX:check if this is needed
    cp -a *.ycp ../dvd4output/stage1scripts
    cp -a etc ../dvd4output/
    cp -a base64 ../dvd4output/stage1scripts
    cp -a response.pl ../dvd4output/stage1scripts
    chmod a+rx ../dvd4output/stage1scripts/*
    if [ -e "./lib/engines" ]; then
        cp -a lib/engines ../dvd4output/lib
    fi
    cd - > /dev/null

#Step 4: extract restored system state
    LogS "Extract restored system state...\n"
    rm -rf restored_systemstate; mkdir -p restored_systemstate; cd restored_systemstate
    if [ "x$BOOTCD_FILE" != "x" ]
    then
        cp $BOOTCD_FILE ../bootcd.tar.gz
    fi
    tar zxf ../bootcd.tar.gz
    cd - > /dev/null

#Step 5: extract restored stage-2 initrd
    LogS "Extract initrd from restored system state...\n"
    rm -rf stage2_initrd; mkdir -p stage2_initrd; cd stage2_initrd
    if [ -f ../restored_systemstate/initrd.img ]; then
        zcat ../restored_systemstate/initrd.img | cpio -dim
    elif [ -f ../restored_systemstate/tmp/initrd.img ]; then
        zcat ../restored_systemstate/tmp/initrd.img | cpio -dim
    fi  
    cp -f ./system_state/sysconf/extra_ld_library_paths .

#   5.1: extract kernel modules
    LogS "unpack kernel modules...\n"
    tar zxf kernel_modules.tgz
    rm -f kernel_modules.tgz

#   5.2: copy INITRD-x86-64 and other utils
    uname -m | grep --quiet x86_64
    ret=$?
    if [ $ret -eq 0 ]; then
        LogS "unpack 64-bit binaries needed for initrd from $DVD4FILE...\n"
        tar zxf ../dvd4input/INITRD-x86_64.tgz
        mv bootimage-x86_64/INITRD/* .
        rm -rf bootimage-x86_64/INITRD

        cp ../stage1_initrd/createqcmd_xml64 createqcmd_xml
        cp ../stage1_initrd/jm_notify64 jm_notify
        cp ../stage1_initrd/send_logs64 send_logs
        cp ../dvd4input/64bit/boa* ./usr/bin/
        cp ../dvd4input/64bit/db* ./usr/bin/
        cp ../dvd4input/64bit/dropbear* ./usr/bin/
        cp ../dvd4input/64bit/scp ./usr/bin/
        cp ../dvd4input/64bit/setkernconsole ./usr/bin/
        cp ../dvd4input/64bit/lib* ./usr/lib/
    else
        LogS "unpack 32-bit binaries needed for initrd from $DVD4FILE...\n"
        tar zxf ../dvd4input/INITRD.tgz
        mv bootimage/INITRD/* .
        rm -rf bootimage/INITRD

        cp ../stage1_initrd/createqcmd_xml createqcmd_xml
        cp ../stage1_initrd/jm_notify jm_notify
        cp ../stage1_initrd/send_logs send_logs
        cp ../dvd4input/bin/boa* ./usr/bin/
        cp ../dvd4input/bin/dbclient* ./usr/bin/
        cp ../dvd4input/bin/dropbear* ./usr/bin/
        cp ../dvd4input/bin/scp ./usr/bin/
        cp ../dvd4input/setkernconsole ./usr/bin/
        cp ../dvd4input/lib/libcrypto* ./usr/lib/
    fi
    cp ../stage1_initrd/boa.conf .
    mkdir -p ./usr/lib/boa ./var/log/boa ./var/www

#   5.3: set init
    cp -a ../stage1_initrd/*.sh .
    cp init init_legacy
    cp -f init_unified init

#   5.4: store arguments to this script that will be used to auto populate the yast GUI fields    
    FAUTOFILL="./unified_yast_autofill"
    echo "SRC_CLIENTNAME=$SRC_CLIENTNAME" > $FAUTOFILL
    echo "CS_HOSTNAME=$CS_HOSTNAME" >> $FAUTOFILL
    echo "USERNAME=$USERNAME" >> $FAUTOFILL
    echo "BKPSET_NAME=$BKPSET_NAME" >> $FAUTOFILL
    echo "DISPTOTIME=$DISPTOTIME" >> $FAUTOFILL
    echo "COPY_PREC=$COPY_PREC" >> $FAUTOFILL

#   5.5 Add any user provided file
    if [ "x$REPLACINGFILE" != "x" ]
    then
        REPLACINGFILE=`echo $REPLACINGFILE|tr ',' '\n'`
        for i in `echo $REPLACINGFILE`
        do
            sFile=`echo $i|cut -f1 -d'='`
            dFile=`echo $i|cut -f2 -d'='`
            if [ -f $sFile ]; then
                echo "Copying [$sFile] to [$dFile]"
                dir=`dirname $dFile`
                # if dest is provided as directory instead of filename, run mkdir on whole path
                if [[ $dFile == *\/ ]]; then
                    dir=$dFile
                fi
                mkdir -p ./$dir
                cp -f $sFile ./$dFile
            fi
        done
    fi

#   5.6: pack this initrd
    LogS "re-pack initrd...\n"
    #initialization.
    binfmt=""
    binfmt=`cat ../restored_systemstate/tmp/binfmt`
    # /tmp/legacy_cpio if user want to override.
    if [ "x$binfmt" != "xbzImage" -o -f /tmp/legacy_cpio ]
    then
        iopt=" -c "
    else
        iopt=" -H newc "
    fi
    (find . | cpio --quiet $iopt -o ) > ../initrd

    cd - > /dev/null
    LogS "compress initrd (this will take a while)...\n"
    gzip -f9 initrd
    mv initrd.gz initrd.img

#Step 6: copy EFI isolinux directory. Update kernel and initrd
    LogS "Copy vmlinuz and initrd to new dvd...\n"
    unalias cp 2>/dev/null
    rm -rf dvd4output/isolinux
    rm -rf dvd4output/images
    #rm -rf dvd4output/simpana_dump/legacy_chroot.tgz
    #rm -rf dvd4output/simpana_dump/simpana.tar.gz
    rm -rf dvd4output/python
    cp -a isolinux dvd4output
    if [ $UEFI_FILES_VER -eq 2 ]; then
        cp -a images dvd4output
    fi
    if [ "`find restored_systemstate/boot/xen*|wc -l`" -gt 1 ]
    then
        if [ -e restored_systemstate/boot/xen.gz-`cat restored_systemstate/tmp/ver` ]
        then
            cp -f restored_systemstate/boot/xen.gz-`cat restored_systemstate/tmp/ver` dvd4output/isolinux/xen 2>/dev/null
            LogS "Selected xen[restored_systemstate/boot/xen.gz-`cat restored_systemstate/tmp/ver`]"
        elif [ -e `ls -tr restored_systemstate/boot/xen.gz*|head -n 1` ]
        then
            cp -f `ls -tr restored_systemstate/boot/xen.gz*|head -n 1` dvd4output/isolinux/xen 2>/dev/null
            LogS "Selected xen[`ls -tr restored_systemstate/boot/xen.gz*|head -n 1`]"
        else
             cp -f `ls -tr restored_systemstate/boot/xen*|head -n 1` dvd4output/isolinux/xen 2>/dev/null
             LogS "Selected xen[`ls -tr restored_systemstate/boot/xen*|head -n 1`]"
        fi
    else
        cp -f restored_systemstate/boot/xen*gz* dvd4output/isolinux/xen 2>/dev/null #not always will we have a xen kernel, ignore the error if any
    fi
    cp -f restored_systemstate/boot/vmlinuz* dvd4output/isolinux/vmlinuz
    cp -f initrd.img dvd4output/isolinux/initrd.img
    if [ $UEFI_FILES_VER -eq 2 ]; then
        cp -f restored_systemstate/boot/vmlinuz* dvd4output/images/pxeboot/vmlinuz
        cp -f initrd.img dvd4output/images/pxeboot/initrd.img
    fi
    cp -a EFI dvd4output
    rm -rf dvd4output/INITRD*.tgz

#Step 7: generate new iso
    LogS "Generate new DVD image...\n"
    cd dvd4output
    uname -m | grep --quiet x86_64
    ret=$?
    if [ -f ../xorriso.x64 -a $ret -eq 0 ]; then
        cp -f ../xorriso.x64 ../xorriso
    elif [ -f ../xorriso.x86 -a $ret -ne 0 ]; then
        cp -f ../xorriso.x86 ../xorriso
    fi

    path=`readlink -f ${DEST_DVDLOC}`/DVD4_${SRC_CLIENTNAME}.iso
    EFIBOOT_IMGPATH=isolinux/efiboot.img
    if [ $UEFI_FILES_VER -eq 2 ]; then
        EFIBOOT_IMGPATH=images/efiboot.img
    fi
    LD_LIBRARY_PATH=$LD_LIBRARY_PATH:../ ../xorriso -as mkisofs -quiet -U -A "ONETOUCH" -V "ONETOUCH" -volset "ONETOUCH" -J -joliet-long -r  -T -x ./lost+found -o ${path} -b isolinux/isolinux.bin -c isolinux/boot.cat -no-emul-boot -boot-load-size 4 -boot-info-table -eltorito-alt-boot --efi-boot $EFIBOOT_IMGPATH -no-emul-boot .
    cd - > /dev/null

    cd .. > /dev/null

    LogS "Generated DVD for $SRC_CLIENTNAME : [$path]"

##Step 8: clean up 
    cd $SCRIPT_DIR
    rm -rf stage1_initrd
    rm -rf stage2_initrd
    umount dvd4input
    rm -rf dvd4input
    rm -rf bootcd.tar.gz
    rm -rf dvd4output
    rm -f sysstate.input
    rm -f initrd.img
    rm -rf restored_systemstate
    rm -rf $SCRIPT_DIR
    return
}

#ENDFUNCS
if [ $MODE -eq 2 ]
then
    set -x
fi
cdir=`pwd`
if [ -e ../../galaxy_vm ]; then
    cd ../../
    . ./galaxy_vm
    cd Base
    . ./cvprofile
    cd ${cdir}
fi

parse_args "$@"

file="/etc/CommVaultRegistry/Galaxy/$INSTANCE/Base/.properties"
if [ -f $file ]; then 
    BASEDIR=`get_registry_value $file "dBASEHOME"`
fi    
file="/etc/CommVaultRegistry/Galaxy/$INSTANCE/EventManager/.properties"
if [ -f $file ]; then 
    LOGDIR=`get_registry_value $file "dEVLOGDIR"`
    LOGFILE="$LOGDIR/create_1tchbootcd.log"
fi

validate_args
if [ $? -ne 0 ]; then
    LogS "Error validating args"
    usage
    exit 1
fi

#Perform qlogin
LogS "Attempting to log in to the CS $CS_HOSTNAME using command [$BASEDIR/qlogin -u $USERNAME $parg]"
cd $BASEDIR

if [ "x$BOOTCD_FILE" == "x" ]
then

    ./qlogin -u $USERNAME $parg
    ret=$?
    if [ $ret -ne 0 ]; then
        Log "qlogin failed. Incorrect credentials? Check logs" 
    fi


    list_jobs_set_totime

    create_qcmd_input

    invoke_monitor_restore

fi
create_dvd

exitfn 0
if [ $MODE -eq 2 ]
then
    set +x
fi

