#!/bin/ksh
#################################################################################
# Description: Wrapper script to execute Del_extra_validation9.sql              #
# Logic:                                                                        #
#   1. Prompts for DB, Dates, and Archive Info (Matches Export Script)          #
#   2. Asks "Delete All Templates?" vs "Specific Templates"                     #
#   3. Builds a SQL-compatible WHERE clause (LIKE '%' or IN ('A','B'))          #
#   4. Passes this clause to the SQL script as parameter &6                     #
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

# Directory where the Export Logs are stored (Validation Source)
echo "Enter Log Directory Name (e.g., DATAMIN_LOG_DIR):"
read LOG_DIR_OBJ
echo "Enter Export Log File Name (e.g. DataMinExports_FSLOG_20251211_230319.out):"
read LOG_FILE_NAME

# Convert Dates for Display/Logic if needed
FROM_DT=$(date +"%d-%b-%Y" --date=$FROM_DATE)
TO_DT=$(date +"%d-%b-%Y" --date=$TO_DATE)

echo " "
echo "Q. Delete data for ALL Templates executed between $FROM_DT and $TO_DT?"
echo " "
echo "1) Yes (All Templates)"
echo "2) No  (Specific Templates)"
echo "Enter Selection:"
read DELETE_ALL

while [ $DELETE_ALL != 1 -a $DELETE_ALL != 2 ];
do
	echo "Invalid Selection."
	echo "1) Yes (All Templates)"
	echo "2) No  (Specific Templates)"
	echo "Enter Selection:"
	read DELETE_ALL
done

# Logic derived from DataMinExportsMainScript.sh
if [ $DELETE_ALL = 1 ]; then
    # Matches everything
    TEMPLATEVAR="LIKE ('%')"
else
    SEQNO=1
    echo " "
    # Start building IN clause
    TEMPLATEVAR=""
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

    # Finalize IN Clause structure
    if [ $SEQNO != 1 ];then
        TEMPLATEVAR=$(echo $TEMPLATEVAR | tr 'a-z' 'A-Z')
        TEMPLATEVAR=$(echo "${TEMPLATEVAR%?}") # Remove trailing comma
        TEMPLATEVAR="IN ($TEMPLATEVAR)"
    else
        echo "No templates selected. Exiting."
        exit 1
    fi
fi

echo "Templates Where Condition: " $TEMPLATEVAR

# Database Connection Setup
ORACLE_HOME=`grep $ORACLE_DB /etc/oratab | awk -F: '{print $2}'`
export ORACLE_HOME
export LD_LIBRARY_PATH=${ORACLE_HOME}/lib
export PATH=$ORACLE_HOME/bin:$LD_LIBRARY_PATH:$PATH

SYSADM_PASSWORD=`cat /backup/exa_ps/dba/.home|grep -w $ORACLE_DB |grep -iw sysadm | awk '{print $3}'`
DB_USERNAME=SYSADM
DB_PASSWORD=$SYSADM_PASSWORD
DB_SERVICE=$ORACLE_DB
PL_CONNECT_STRING="$DB_USERNAME/$DB_PASSWORD@$DB_SERVICE"

# Execution
echo "Starting Deletion Script..."
echo "tail -f Del_extra_validation9.LOG" 

sqlplus -s $PL_CONNECT_STRING <<EOF
@Del_extra_validation9.sql "$ORACLE_DB" "$FROM_DATE" "$TO_DATE" "$LOG_DIR_OBJ" "$LOG_FILE_NAME" "$TEMPLATEVAR"
EXIT;
EOF

echo "Script Execution Complete."