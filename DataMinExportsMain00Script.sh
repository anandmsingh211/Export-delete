#!/bin/ksh
#################################################################################
#By:S.Ravi, CAPGemini America Inc                                               #
#Date: 07262024                                                                 #  
#Description: Read Export Arguments and Pass/Execute DataMinExportsSub0Script.sh#
#################################################################################
echo "Enter Oracle Database Name:"
read ORACLE_DB
echo "Enter Oracle Database SID:"
read ORACLE_SID
export ORACLE_SID
echo "Enter Archival Execution- From Date(MM/DD/YYYY):"
read FROM_DATE
echo "Enter Archival Execution- To Date(MM/YY/YYYY):"
read TO_DATE
echo "Enter Archival Year(YYYY/YYYY_YYYY)/FOLDER YEAR:"
read ARCHIVE_YEAR
echo "Enter Archival Environment(FS/HR/TE/SE{ALL CAPS}):"
read ARCHIVE_ENV


BASEDIR=$(pwd)
OUTLOGDTTM=$(date +"%Y%m%d_%H%M%S")
OUTLOGFILE=$BASEDIR/LOGS/DataMinExports_${ARCHIVE_ENV}LOG_${OUTLOGDTTM}.out
echo "tail -1000f ${OUTLOGFILE}"
echo "ps -ef | grep \"DataMinExport\""
nohup ./DataMinExportsSub000Script.sh $ORACLE_DB $ORACLE_SID $FROM_DATE $TO_DATE $ARCHIVE_YEAR $ARCHIVE_ENV > ${OUTLOGFILE} 2>&1 &
