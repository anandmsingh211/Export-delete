#!/bin/ksh
#################################################################################
# Description: Wrapper script to execute export_delete_final1.sql
#################################################################################

# Removed 'set -e' as it can cause older ksh versions to abort during 'expr'
echo "Enter Oracle Database Name:"
read -r ORACLE_DB

echo "Enter Oracle Database SID:"
read -r ORACLE_SID
export ORACLE_SID

echo "Enter Archival Execution - From Date (MM/DD/YYYY):"
read -r FROM_DATE

echo "Enter Archival Execution - To Date (MM/DD/YYYY):"
read -r TO_DATE

echo "Enter Log Directory Name (e.g., DATAMIN_LOG_DIR):"
read -r LOG_DIR_OBJ

echo "Enter Export Log File Name (e.g. DataMinExports_FSLOG_20251211_230319.out):"
read -r LOG_FILE_NAME

echo " "
echo "Q. Delete data for ALL Templates?"
echo "1) Yes (All Templates)"
echo "2) No  (Specific Templates)"
echo "Enter Selection:"
read -r DELETE_ALL

while [ "$DELETE_ALL" != "1" ] && [ "$DELETE_ALL" != "2" ];
do
  echo "Invalid Selection."
  echo "1) Yes (All Templates)"
  echo "2) No  (Specific Templates)"
  echo "Enter Selection:"
  read -r DELETE_ALL
done

if [ "$DELETE_ALL" = "1" ]; then
  TEMPLATEVAR="__ALL__"
else
  SEQNO=1
  TEMPLATEVAR=""
  echo " "
  echo "Enter Template $SEQNO Name Or Press 0 (Done)"
  read -r TEMPLATEOPTION

  while [ "$TEMPLATEOPTION" != "0" ];
  do
    # Convert to uppercase
    TEMPLATEVARIN=$(printf "%s" "$TEMPLATEOPTION" | tr '[:lower:]' '[:upper:]')
    
    # Append to the list WITH A COMMA ONLY (no single quotes, no spaces)
    TEMPLATEVAR="${TEMPLATEVAR}${TEMPLATEVARIN},"
    
    SEQNO=$(expr $SEQNO + 1)
    echo "Enter Template $SEQNO Name Or Press 0 (Done)"
    read -r TEMPLATEOPTION
  done

  # Finalize the list
  if [ $SEQNO -ne 1 ]; then
    # Reverting back to your original, proven 'sed' command to drop the last comma!
    TEMPLATEVAR=$(printf "%s" "$TEMPLATEVAR" | sed 's/,$//')
  else
    echo "No templates selected. Exiting."
    exit 1
  fi
fi

echo "Templates Where Condition: $TEMPLATEVAR"

# Safety Check: Stop the script if KSH wiped the variable
if [ -z "$TEMPLATEVAR" ]; then
    echo "ERROR: The template variable is empty! Shell script failed to build the string."
    exit 1
fi

# Database Connection Setup
ORACLE_HOME=$(grep "^${ORACLE_DB}:" /etc/oratab | awk -F: '{print $2}' | head -1)
export ORACLE_HOME
export LD_LIBRARY_PATH=${ORACLE_HOME}/lib
export PATH=$ORACLE_HOME/bin:$LD_LIBRARY_PATH:$PATH

SYSADM_PASSWORD=$(cat /backup/exa_ps/dba/.home | grep -w "$ORACLE_DB" | grep -iw sysadm | awk '{print $3}')
DB_USERNAME=SYSADM
DB_PASSWORD=$SYSADM_PASSWORD
DB_SERVICE=$ORACLE_DB
PL_CONNECT_STRING="$DB_USERNAME/$DB_PASSWORD@$DB_SERVICE"

echo "Starting Deletion Script..."
echo "tail -f export_delete_final1.LOG"

# Notice $TEMPLATEVAR is passed directly here
sqlplus -s "$PL_CONNECT_STRING" <<EOF
@export_delete_final1.sql "$ORACLE_DB" "$FROM_DATE" "$TO_DATE" "$LOG_DIR_OBJ" "$LOG_FILE_NAME" "$TEMPLATEVAR"
EXIT;
EOF

echo "Script Execution Complete."