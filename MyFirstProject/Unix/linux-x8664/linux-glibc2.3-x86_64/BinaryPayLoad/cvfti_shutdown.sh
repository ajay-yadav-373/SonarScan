#!/bin/sh
# sample script for shutting down Full Text Index server.
# As per Full Text Administration Guide, only Cold Backups
# of FTI is supported. So, it is mandatory to shutdown Index
# server at the begining of the backup and restart it after
# completion of the FTI backup.
# This script has to be modified so that user environment
# points to local Full Text Index server.
# make sure FULL Text Indexer install bin directory is in PATH
# of FTI user so that setuenv.sh and nctrl commands can be executed.

FTI_USER=dctmfast
FASTSEARCH=/dctm_installpath/fulltext/IndexServer/
echo "cvfti_shutdown:Begin FTI shutdown ..."
su - $FTI_USER -c "LD_LIBRARY_PATH=$FASTSEARCH:lib; export LD_LIBRARY_PATH FASTSEARCH;$FASTSEARCH/bin/setupenv.sh; $FASTSEARCH/bin//nctrl  stop indexer"

ret=$?
if [ "$ret" -ne 0 ]; then
	echo "Full Text Index shutdown has failed with error code $ret"
else
	echo "Full Text Index shutdown is completed"
fi
exit $ret
