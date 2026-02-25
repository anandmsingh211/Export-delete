#!/bin/ksh
#################################################################################
# Description: Wrapper script to execute export_delete_final1.sql
# Changes:
#   - Uses "IS NOT NULL" for the "All Templates" option (no embedded quotes).
#   - Properly builds IN ('A','B',...) list and uppercases template IDs.
#   - Passes the exact template string to SQL*Plus (no extra escaping needed, 
#     as the SQL script now uses q'[]' literal quoting).
#################################################################################

set -e

echo "Enter Oracle Database Name:"
read -r ORACLE_DB

echo "Enter Oracle Database SID:"
read -r ORACLE_SID
export ORACLE_SID

echo "Enter Archival Execution - From Date (MM/DD/YYYY):"
read -r FROM_DATE

echo "Enter Archival Execution - To Date (MM/DD/YYYY):"
read -r TO_DATE

# Directory where the Export Logs are stored (Validation Source)
echo "Enter Log Directory Name (e.g., DATAMIN_LOG_DIR):"
read -r LOG_DIR_OBJ

echo "Enter Export Log File Name (e.g. DataMinExports_FSLOG_20251211_230319.out):"
read -r LOG_FILE_NAME

# Pretty dates for display (optional)
FROM_DT=$(date +"%d-%b-%Y" --date="$FROM_DATE" 2>/dev/null || echo "$FROM_DATE")
TO_DT=$(date +"%d-%b-%Y" --date="$TO_DATE" 2>/dev/null || echo "$TO_DATE")

echo " "
echo "Q. Delete data for ALL Templates executed between $FROM_DT and $TO_DT?"
echo " "
echo "1) Yes (All Templates)"
echo "2) No  (Specific Templates)"
echo "Enter Selection:"
read -r DELETE_ALL

# Clean the input in case of carriage returns
DELETE_ALL=$(printf "%s" "$DELETE_ALL" | tr -d '[:space:]')

while [ "$DELETE_ALL" != "1" ] && [ "$DELETE_ALL" != "2" ];
do
  echo "Invalid Selection."
  echo "1) Yes (All Templates)"
  echo "2) No  (Specific Templates)"
  echo "Enter Selection:"
  read -r DELETE_ALL
  DELETE_ALL=$(printf "%s" "$DELETE_ALL" | tr -d '[:space:]')
done


if [ "$DELETE_ALL" = "1" ]; then
  TEMPLATEVAR="__ALL__"   # sentinel
else
  SEQNO=1
  TEMPLATEVAR=""
  echo " "
  echo "Enter Template $SEQNO Name Or Press 0 (Done)"
  read -r TEMPLATEOPTION
  
  # Aggressively strip spaces and hidden carriage returns
  TEMPLATEOPTION=$(printf "%s" "$TEMPLATEOPTION" | tr -d '[:space:]' | tr -d '\r')

  while [ "$TEMPLATEOPTION" != "0" ];
  do
    if [ -n "$TEMPLATEOPTION" ]; then
      # Normalize to upper to match PS keys
      TEMPLATEVARIN=$(printf "%s" "$TEMPLATEOPTION" | tr '[:lower:]' '[:upper:]')
      # Append with single quotes and a comma
      TEMPLATEVAR="${TEMPLATEVAR}'${TEMPLATEVARIN}',"
      SEQNO=$(expr $SEQNO + 1)
    fi

    echo "Enter Template $SEQNO Name Or Press 0 (Done)"
    read -r TEMPLATEOPTION
    # Aggressively strip spaces and hidden carriage returns
    TEMPLATEOPTION=$(printf "%s" "$TEMPLATEOPTION" | tr -d '[:space:]' | tr -d '\r')
  done

  # Finalize IN (...) list
  if [ $SEQNO -ne 1 ]; then
    # Native shell string manipulation to remove the trailing comma (no sed required)
    TEMPLATEVAR="${TEMPLATEVAR%,}"
  else
    echo "No templates selected. Exiting."
    exit 1
  fi
fi

echo "Templates Where Condition: $TEMPLATEVAR"

# Database Connection Setup
ORACLE_HOME=$(grep "^${ORACLE_DB}:" /etc/oratab | awk -F: '{print $2}' | head -1)
export ORACLE_HOME
export LD_LIBRARY_PATH=${ORACLE_HOME}/lib
export PATH=$ORACLE_HOME/bin:$LD_LIBRARY_PATH:$PATH

# Pull SYSADM password (adjust this pipeline to your environment if needed)
SYSADM_PASSWORD=$(cat /backup/exa_ps/dba/.home | grep -w "$ORACLE_DB" | grep -iw sysadm | awk '{print $3}')
DB_USERNAME=SYSADM
DB_PASSWORD=$SYSADM_PASSWORD
DB_SERVICE=$ORACLE_DB
PL_CONNECT_STRING="$DB_USERNAME/$DB_PASSWORD@$DB_SERVICE"

echo "Starting Deletion Script..."
echo "tail -f export_delete_final1.LOG"

# The variable is mapped strictly to prevent expansion loss
CLAUSE_TO_SQLPLUS="$TEMPLATEVAR"

# Double quotes around $CLAUSE_TO_SQLPLUS force SQL*Plus to see it as exactly one parameter
sqlplus -s "$PL_CONNECT_STRING" <<EOF
@export_delete_final1.sql "$ORACLE_DB" "$FROM_DATE" "$TO_DATE" "$LOG_DIR_OBJ" "$LOG_FILE_NAME" "$CLAUSE_TO_SQLPLUS"
EXIT;
EOF

echo "Script Execution Complete."