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

FROM_DT=$(date +"%d-%b-%Y" --date=$FROM_DATE)
TO_DT=$(date +"%d-%b-%Y" --date=$TO_DATE)
BASEDIR=$(pwd)
OUTLOGDTTM=$(date +"%Y%m%d_%H%M%S")
##OUTLOGFILE=$BASEDIR/$ARCHIVE_YEAR/DataMinExports_${ARCHIVE_ENV}LOG_${OUTLOGDTTM}.out
OUTLOGFILE=$BASEDIR/LOGS/DataMinExports_${ARCHIVE_ENV}LOG_${OUTLOGDTTM}.out

echo " "
echo "Q. Export all $ARCHIVE_ENV Templates for $ARCHIVE_YEAR executed between $FROM_DT and $TO_DT?"
echo " "
echo "1) Yes"
echo "2) No"
echo "Enter Selection:"
read EXPORT_ALL


while [ $EXPORT_ALL != 1 -a $EXPORT_ALL != 2 ];
do
	echo "Q. Export all $ARCHIVE_ENV Templates for $ARCHIVE_YEAR executed between $FROM_DT and $TO_DT?"
	echo " "
	echo "1) Yes"
	echo "2) No"
	echo "Enter Selection:"
	read EXPORT_ALL
done

if [ $EXPORT_ALL = 1 ];then

        echo "tail -1000f ${OUTLOGFILE}"
        echo "ps -ef | grep \"DataMinExport\""
	nohup ./DataMinExportsSub000Script.sh $ORACLE_DB $ORACLE_SID $FROM_DATE $TO_DATE $ARCHIVE_YEAR $ARCHIVE_ENV > ${OUTLOGFILE} 2>&1 &

else

	SEQNO=1
	echo " "
	#TEMPLATEVAR=\ LIKE\ \(\'\%"')"
	TEMPLATEVAR=\ IN\ \(\'\ "')"
	echo "Enter Template $SEQNO Name Or Press 0 (Done)"
	read TEMPLATEOPTION

	while [ $TEMPLATEOPTION != 0 ];
	do
		if [ $SEQNO = 1 ];then
			TEMPLATEVAR=""
		fi

		SEQNO=`expr $SEQNO + 1`
		TEMPLATEVARIN=$TEMPLATEOPTION
		TEMPLATEVAR=$TEMPLATEVAR\'$TEMPLATEVARIN\'\,
	
		echo "Enter Template $SEQNO Name Or Press 0 (Done)"
		read TEMPLATEOPTION
	done

	if [ $SEQNO != 1 ];then
		TEMPLATEVAR=$(echo $TEMPLATEVAR | tr 'a-z' 'A-Z')
		TEMPLATEVAR=$(echo "${TEMPLATEVAR%?}")
		TEMPLATEVAR=\ IN\ \($TEMPLATEVAR")"
	fi

	echo "Templates Where Condition: " $TEMPLATEVAR


	ORACLE_DB=$ORACLE_DB
	ORACLE_SID=$ORACLE_SID
	export ORACLE_SID

	SYSADM_PASSWORD=`cat /backup/exa_ps/dba/.home|grep -w $ORACLE_DB |grep -iw sysadm | awk '{print $3}'`
	DB_USERNAME=SYSADM
	DB_PASSWORD=$SYSADM_PASSWORD
	DB_SERVICE=$ORACLE_DB
	PL_CONNECT_STRING="$DB_USERNAME/$DB_PASSWORD@$DB_SERVICE"



	echo 'oracle Database name       : ' $ORACLE_DB
	echo 'Oracle SID                 : ' $ORACLE_SID
	echo 'Archive Execution-From Date: ' $FROM_DT
	echo 'Archive Execution-To Date  : ' $TO_DT 

	echo 'Checking the Validity of Templates ...'
	CURDT_BTCHCNT=$(sqlplus -s $PL_CONNECT_STRING <<-CDTEND-OF-SQL
	set pagesize 0;
	set head off;
	SELECT COUNT(*)
	FROM SYSADM.PSARCHBATCH B
	WHERE PSARCH_DTTM >= '$FROM_DT'
	AND PSARCH_DTTM < '$TO_DT'
	AND PSARCH_ID ${TEMPLATEVAR};
	EXIT;
CDTEND-OF-SQL);

	echo 'Templates count in Dates Range : ' $CURDT_BTCHCNT 

	if [ $CURDT_BTCHCNT -gt 0 ];then

        	echo "Valid Templates found to Export"
                echo "tail -1000f ${OUTLOGFILE}"  
                echo "ps -ef | grep \"DataMinExport\""
		nohup ./DataMinExportsSub001Script.sh $ORACLE_DB $ORACLE_SID $FROM_DATE $TO_DATE $ARCHIVE_YEAR $ARCHIVE_ENV "${TEMPLATEVAR}"> ${OUTLOGFILE} 2>&1 &
	else

		echo "No Valid Templates found to Export ..."

	fi

fi
