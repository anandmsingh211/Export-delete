#!/bin/ksh
#################################################################################################################
#Developed By: Ravi Siriseni, CAPGemini America Inc                                                         	#
#Date        : 07-21-2024                                                                                   	#
#Description : Script to Export Data from PeopleSoft Data Minimization Archival Tables.                     	#  	         
#Purpose     : 1. Data Minimization Selects Inactive from PeopleSoft Base Tables to Archival/History Tables.	#
#              2. Post selection, Data from Archival/History Tables is used to delete data from Base Tables.	#
#              3. After agreed period of time, Data also needs to be moved/Exported out of                  	#
#                 Archival/History Tables. This help to retain space in PeopleSoft DataBase.                	#
#              4. Along with Export also need to have flexibility to import data back to Archival Tables.   	#
#              5. Oracle Database Data Pump feature is used to Export and Import the data out of PeopleSoft 	#
#              6. This ShellScript gets the Templates and Records to be exported and executes Database      	#
#                 data pump feture "expdp" to export the data from Archive/History Tables to dump files.    	#
#              7. Also, Generates Log File for Tracking and inserts success and failure export status to    	#
#                 Log Stage records.                                                                            #
#                      	i. PS_DATAMIN_EXPF_XX : Columns:RUNDATE	         : Export Run Date			#
#                                                       PSARCH_ID	 : Archival ID				#
# 						 	VERSION_NBR	 : Run Date's Export Version Number	#
#						 	PTSHOWTIME1	 : Export Start Time			#
#						 	PTSHOWTIME2	 : Export End Time			#
#                                           		PSARCH_DM_EXP	 : Archival Year			#
#						 	EXPORT_FLAG	 : Export Success Flag			#
#						 	FILENAME	 : Dump File Name                       # 
#						 	REC_COUNT_SUM    : Count of History Records in Template #
#		       ii. PS_DATAMIN_EXPC_XX : Columns:RUNDATE		 : Export Run Date			#
#							PSARCH_ID	 : Archival ID				#
#							VERSION_NBR	 : Run Date's Export Version Number	#
#							HIST_RECNAME 	 : History Record Name			#
#							EXPORT_COUNT	 : History Record row counts		#
#		      iii. PS_DATAMIN_EXPB_XX : Columns:RUNDATE		 : Export Run Date                      #
#							PSARCH_ID	 : Archival ID                          #	
#							VERSION_NBR	 : Run Date's Export Version Number     #
#							PSARCH_BATCHNUM	 : Archival Batch Number		#
#		       iv. PS_DATAMIN_EXPS_XX : Columns:RUNDATE		 : Export Run Date                      #
#							PSARCH_ID	 : Archival ID                          #	
#							VERSION_NBR	 : Run Date's Export Version Number     #
#							PSARCH_BATCHNUM	 : Archival Batch Number		#
#                                                       HIST_RECNAME     : History Record Name			#
#                                                       DDLSPACENAME     : History Record Table Space		#	
#                                                       PTSF_INDEX_NAME  : History Record's Index Name		#
#                                                       PPMU_TBLSPACENAME: History Record's Index TableSpace    #
#		        v. PS_DATAMIN_EXPN_XX : Columns:RUNDATE		 : Export Run Date                      #
#							VERSION_NBR	 : Run Date's Export Version Number     #
#							PARAM_NAME	 : NLS DataBase Parameter Name		#
#                                                       VALUE            : NLS DataBase Parameter Value         #
#                      vi. PS_DATAMIN_EXPZ_XX : Columns:RUNDATE          : Export Run Date                      #
#                                                       VERSION_NBR      : Run Date's Export Version Number     #
#                                                       FILENAME         : TimeZone FileName                    #
#                                                       VERSION          : Version                              #
#                                                       CONNID           : Connection Id                        # 
#How To      : Exection Arguments/Parameters									#
#		1. Execute the Shell Script as ./DataMinExportsMainScript.sh 					#
#		2. Provide the Arguments to shellscript as below						#
#		1. Enter Oracle Database Name:									#		
#		   Example: FSLODX [Provide Environment Name where the Database in the Script should connect to]# 
#		2. Enter Oracle Database SID:									#
#		   Example: 5											#
#               3. Enter Archival Execution- From Date(MM/DD/YYYY):						#
#                  Example: 05/01/2023 [Choose Start Date of Wave to be Exported. Wave's selections Start Date.]#
#               4. Enter Archival Execution- To Date(MM/YY/YYYY):						#
#                  Example: 03/01/2024 [Choose End Date of Wave.]						#
#               5. Enter Archival Year(YYYY/YYYY_YYYY)/FOLDER YEAR:						#
#                  Example: 1995_2000  [Archival Year(s) of Wave. This Should be same as the Exports Folder. 	#
#               6. Enter Archival Environment(FS/HR/TE/SE{ALL CAPS}):						#
#                  Example: FS         [PeopleSoft Environment Name. 						#
#                                      This should be same as Sub-Folder in Exports Folder]  			#
#               7. DataMinExportsMainScript.sh Calls DataMinExportsSub0Script.sh.				#
#		8. DataMinExportsSub0Script.sh Exports Dump & LogFiles, Error Vaidations, Emails Notificatons,  #
#                  Records Export Logs.										#		 
#Folder Structure :												#
#  		  	├── 1995_2000										#			
#			│   ├── FS										#
#			│   ├── HR										#	
#			│   ├── SE										#
#			│   └── TE										#
#			└── SAMPLE_FROMYEAR_TOYEAR								#
#			    ├── FS										#
#			    ├── HR										#
#			    ├── SE										#
#			    └── TE										#
#														#
#################################################################################################################
RETURN_CODE=0
############################
# Get Parameters
############################
#**********************************************************************************************#
#Function Call Export Template Echo                                                            #
#**********************************************************************************************#
Call_ExpTemplEcho() {
         PREV_TEMPLATE=$1
 echo "#########################################################################################"
 echo "Beginning export of Template : ${PREV_TEMPLATE}"
 echo "#########################################################################################"
 echo " "
}

#**********************************************************************************************#
#Function Call Export Dump                                                                     #
#**********************************************************************************************#
Call_ExecExportDump_Insert() {
   #echo "Hello" $1 $2 $3 $4 $5 $6 $7
   #---------------------------------------------------------------------------#
   #Assign Variable assignment of Function Call Parameters                     #
   #---------------------------------------------------------------------------#
   TEMPLATE_NAME=$2
   DUMPSTRING=$3
   DUMPLOGDIRENV=$4
   CURDT_BTCHCNT=$5
   FILENAME=$6
   REC_COUNT=$7
   TEMPL_EXP_START_TIME=$8
   PREEXPDTTM=$9
   echo 'TEMPLATE_NAME: ' $TEMPLATE_NAME

   #---------------------------------------------------------------------------#
   #Variables assignment for Success/Failure Template Export Email Notification#
   #---------------------------------------------------------------------------#
   START_MESSAGE="Beginning export of Template : ${TEMPLATE_NAME}"
   END_MESSAGE="Finished export of Template : ${TEMPLATE_NAME}"
   SUCCESS_MESSAGE="Template ${ORACLE_DB}-${TEMPLATE_NAME} successfully Exported, started at "
   ERROR_MESSAGE="Template ${ORACLE_DB}-${TEMPLATE_NAME} failed to Export, check logfile for more info"
   SMAIL_OBJECT="Successfully exported Template ${TEMPLATE_NAME}"
   EMAIL_OBJECT="Unsuccessful in exporting Template ${TEMPLATE_NAME}"
   
   #echo "#########################################################################################"
   #echo $START_MESSAGE
   #echo "#########################################################################################"
   #echo " "
   
   #---------------------------------------------------------------------------#
   #Execute Export. Capture Pre and Post Export date times.                    #
   #---------------------------------------------------------------------------#
   TEMPL_EXP_START_TIME=${TEMPL_EXP_START_TIME}
   PREEXPDTTM=${PREEXPDTTM}      
   POSTEXPDTTM=$(date +"%r")
   NOW=$(date +"%Y/%m/%d")

   #---------------------------------------------------------------------------#
   # Verifying errors                                                          #
   #---------------------------------------------------------------------------#  
   errors_count=`grep ORA- ${BASEDIR}/${TEMPLATE_NAME}*.log | wc -l`
   #errors_count=0;
   echo 'Error Count: ' $errors_count
	
   if [ $errors_count -eq 0 ]; then
    
       #-----------------------------------------------------------------------#
       #No Error. Log ExportDump to Stage Record                               #
       #-----------------------------------------------------------------------#
        SYSADM_PASSWORD=`cat /backup/exa_ps/dba/.home|grep -w $ORACLE_DB |grep -iw sysadm | awk '{print $3}'`
        DB_USERNAME=SYSADM
	DB_PASSWORD=$SYSADM_PASSWORD
	DB_SERVICE=$ORACLE_DB 
	PL_CONNECT_STRING="$DB_USERNAME/$DB_PASSWORD@$DB_SERVICE"
    
        echo 'CURRENT DATE: ' $NOW	
        echo "Insert Data into PS_DATAMIN_EXPF_XX."
        sqlplus -s $PL_CONNECT_STRING <<-EOF
        conn $PL_CONNECT_STRING;
        set heading on feedback on;
        INSERT INTO PS_DATAMIN_EXPF_XX(VERSION_NBR,PSARCH_ID,RUNDATE,PTSHOWTIME1,PTSHOWTIME2,PSARCH_DM_EXP,EXPORT_FLAG,FILENAME,REC_COUNT_SUM) VALUES('$CURDT_BTCHCNT','$TEMPLATE_NAME',TO_DATE('${NOW}','YYYY/MM/DD'),'$PREEXPDTTM',TO_CHAR(SYSDATE, 'HH:MI:SS AM'),'$ARCHIVE_YEAR','Y','$FILENAME','$REC_COUNT');   
        commit;
        exit; 
EOF
        echo "Successful Export: Insert Done."

       #-----------------------------------------------------------------------#
       #No Error. Success Email                                                #
       #-----------------------------------------------------------------------#
       #R0801# echo "$SUCCESS_MESSAGE $TEMPL_EXP_START_TIME and finished at `date`" |  mail -s "$SMAIL_OBJECT" "vgangula@allegisgroup.com,aknarare@allegisgroup.com"
       #echo "$SUCCESS_MESSAGE $TEMPL_EXP_START_TIME and finished at `date`" |  mail -s "$SMAIL_OBJECT" "rasiriseni@allegisgroup.com"
	echo "$SUCCESS_MESSAGE $TEMPL_EXP_START_TIME and finished at `date`"

else
            
       #-----------------------------------------------------------------------#
       #Error. Log ExportDump to Stage Record                                  #
       #-----------------------------------------------------------------------#
	echo "Insert Data into PS_DATAMIN_EXPF_XX."
        sqlplus -s $PL_CONNECT_STRING <<-EOF
        conn $PL_CONNECT_STRING;
        set heading on feedback on;
        INSERT INTO PS_DATAMIN_EXPF_XX(VERSION_NBR,PSARCH_ID,RUNDATE,PTSHOWTIME1,PTSHOWTIME2,PSARCH_DM_EXP,EXPORT_FLAG,FILENAME,REC_COUNT_SUM) VALUES('$CURDT_BTCHCNT','$TEMPLATE_NAME',TO_DATE('$NOW','YYYY/MM/DD'),'$PREEXPDTTM',TO_CHAR(SYSDATE, 'HH:MI:SS AM'),'$ARCHIVE_YEAR','N','$FILENAME','$REC_COUNT');
        commit; 
        exit;
EOF
		echo "Failed Export: Insert Done."

       #-----------------------------------------------------------------------#
       #Error. No Success Email                                                #
       #-----------------------------------------------------------------------#
        #echo $ERROR_MESSAGE |  mail -s "$EMAIL_OBJECT" "vgangula@allegisgroup.com,aknarare@allegisgroup.com"
        echo $ERROR_MESSAGE |  mail -s "$EMAIL_OBJECT" -a ${BASEDIR}/*${TEMPLATE_NAME}*.log "vgangula@allegisgroup.com,aknarare@allegisgroup.com"
        #echo $ERROR_MESSAGE |  mail -s "$EMAIL_OBJECT" -a ${BASEDIR}/*${TEMPLATE_NAME}*.log "rasiriseni@allegisgroup.com"
        echo $ERROR_MESSAGE

   fi

echo "----------------------------------------------------------------------------------------"
echo $END_MESSAGE
echo "----------------------------------------------------------------------------------------"
}
#***************************************************************************#
#END FUNCTION                                                               #
#***************************************************************************#


#declare -A TMPLARR


#*********************************************************************
#Initialize Oracle Variables                                         *
#*********************************************************************
PATH=$PATH:/usr/local/bin
##export ORACLE_HOME=/u01/app/oracle/product/12.1.0.2/dbhome_1
##export LD_LIBRARY_PATH=/u01/app/oracle/product/12.1.0.2/dbhome_1/lib


#R0725#echo "Enter Oracle Database Name:"
#R0725#read ORACLE_DB
#R0725#ORACLE_HOME=`grep $ORACLE_DB /etc/oratab | awk -F: '{print $2}'`
ORACLE_HOME=`grep $1 /etc/oratab | awk -F: '{print $2}'`

export ORACLE_HOME
export LD_LIBRARY_PATH=${ORACLE_HOME}/lib

export PATH=$ORACLE_HOME/bin:$LD_LIBRARY_PATH:$PATH

#R0725#echo "Enter Oracle Database SID:"
#R0725#read ORACLE_SID
#R0725#ORACLE_SID=$ORACLE_DB$ORACLE_SID
ORACLE_DB=$1
ORACLE_SID=$1$2
export ORACLE_SID
#echo ${ORACLE_DB}
#source /home/oracle/${ORACLE_DB}.env


START_TIME=`date`

#*********************************************************************
#Read the Arguments                                                  *
#*********************************************************************
#R#echo "Enter Oracle Database Name:"
#R#read ORACLE_DB
#R#echo "Enter Oracle Database SID:"
#R#read ORACLE_SID
#R#export ORACLE_SID
#R0725#echo "Enter Archival Execution- From Date(MM/DD/YYYY):"
#R0725#read FROM_DATE
#R0725#echo "Enter Archival Execution- To Date(MM/YY/YYYY):"
#R0725#read TO_DATE
#R0725#echo "Enter Archival Year(YYYY/YYYY_YYYY)/FOLDER YEAR:"
#R0725#read ARCHIVE_YEAR
#R0725#echo "Enter Archival Environment(FS/HR/TE/SE{ALL CAPS}):"
#R0725#read ARCHIVE_ENV 


EXPORTFILESRC=/backup/data_arch/ExportInputParams
#FROM_DATE=`grep $1 $EXPORTFILESRC | awk -F: '{print $3}'`
#TO_DATE=`grep $1 $EXPORTFILESRC | awk -F: '{print $4}'`
#ARCHIVE_YEAR=`grep $1 $EXPORTFILESRC | awk -F: '{print $5}'`
#ARCHIVE_ENV=`grep $1 $EXPORTFILESRC | awk -F: '{print $6}'`
FROM_DATE=$3
TO_DATE=$4
ARCHIVE_YEAR=$5
ARCHIVE_ENV=$6


#*********************************************************************
#Print Arguments                                                     *
#*********************************************************************
echo 'oracle Database name       : ' $ORACLE_DB
echo 'Oracle SID                 : ' $ORACLE_SID
#Assign FromDate and ToDate to Variables in Formats of DD-MON-YYYY
RUNDATE=$(date +"%d-%m-%Y")
FROM_DT=$(date +"%d-%b-%Y" --date=$FROM_DATE)
TO_DT=$(date +"%d-%b-%Y" --date=$TO_DATE)
echo 'Archive Execution-From Date: ' $FROM_DT
echo 'Archive Execution-To Date  : ' $TO_DT
echo 'Archive Year               : ' $ARCHIVE_YEAR
echo 'Archive Environment        : ' $ARCHIVE_ENV 

#*********************************************************************
#Assign Directories                                                  *
#*********************************************************************
##BASEDIR=/oggdata/EHUB_EXPORT/DATA_MIN_EXPORTS/$ARCHIVE_YEAR/$ARCHIVE_ENV
#PARFILEDIR=$BASEDIR
#PARFILEDIRENV=$PARFILEDIR
#DUMPLOGDIR=$BASEDIR
#DUMPLOGDIRENV=$DUMPLOGDIR

#expdp parfile=/oggdata/EHUB_EXPORT/DATA_MIN_EXPORTS/TRANS/1995_2000/FS/PAR/Export_Q_APPYMTXX_2001_2001_FS.par

#*********************************************************************
#Database Arguments                                                  *
#*********************************************************************
SYSADM_PASSWORD=`cat /backup/exa_ps/dba/.home|grep -w $ORACLE_DB |grep -iw sysadm | awk '{print $3}'`
##SR102224#ENCRYPTPWD=`cat /oggdata/EHUB_EXPORT/DATA_MIN_EXPORTS/.DataPumpHome| grep -i ENCRYPTPWD| awk '{print $2}'`
ENCRYPTPWD=`cat /backup/data_arch/.DataPumpHome| grep -i ENCRYPTPWD| awk '{print $2}'`
DB_USERNAME=SYSADM
DB_PASSWORD=$SYSADM_PASSWORD
DB_SERVICE=$ORACLE_DB
PL_CONNECT_STRING="$DB_USERNAME/$DB_PASSWORD@$DB_SERVICE"



#-----------------------------------------------------------------------------------#
#Get Current Date Export Run Version number.                                        #
#-----------------------------------------------------------------------------------#
sleep 20

#CRUNDT=$(date +"%d-%b-%Y")
CRUNDT=$(date +"%Y/%m/%d")
CURDT_BTCHCNT=$(sqlplus -s $PL_CONNECT_STRING <<-CDTEND-OF-SQL
set pagesize 0;
set head off;
SELECT MAX(TO_NUMBER(VERSION_NBR))
FROM SYSADM.PS_DATAMIN_EXPB_XX
WHERE RUNDATE=TO_DATE('$CRUNDT','YYYY/MM/DD');
EXIT;
CDTEND-OF-SQL);
CURDT_BTCHCNT=$(($CURDT_BTCHCNT+1))

#-----------------------------------------------------------------------------------#
#Insert Batch numbers.                                                              #
#-----------------------------------------------------------------------------------#
echo " "
echo "=> Batch Numbers check."
sqlplus -s $PL_CONNECT_STRING <<-BATCH-EOF
conn $PL_CONNECT_STRING;
set heading on feedback on;
INSERT INTO SYSADM.PS_DATAMIN_EXPB_XX(RUNDATE,PSARCH_ID,VERSION_NBR,PSARCH_BATCHNUM)
SELECT DISTINCT TO_DATE('$CRUNDT','YYYY/MM/DD'),PSARCH_ID,'$CURDT_BTCHCNT',PSARCH_BATCHNUM
FROM SYSADM.PSARCHBATCH B
WHERE PSARCH_DTTM >= '$FROM_DT'
AND PSARCH_DTTM < '$TO_DT';
commit;
exit;
BATCH-EOF

#echo "Batch Numbers: Insert Done."


#-----------------------------------------------------------------------------------#
#Insert NLS Database Parameters.                                                    #
#-----------------------------------------------------------------------------------#
echo "=> NLS DataBase Parameters Check."
sqlplus -s $PL_CONNECT_STRING <<-NLSPARAM-EOF
conn $PL_CONNECT_STRING;
set heading on feedback on;
INSERT INTO SYSADM.PS_DATAMIN_EXPN_XX(RUNDATE,VERSION_NBR,PARAM_NAME,VALUE)
SELECT DISTINCT TO_DATE('$CRUNDT','YYYY/MM/DD'),'$CURDT_BTCHCNT',PARAMETER,VALUE
FROM NLS_DATABASE_PARAMETERS B
WHERE PARAMETER IN ('NLS_NCHAR_CHARACTERSET','NLS_CHARACTERSET','NLS_LENGTH_SEMANTICS');
commit;
exit;
NLSPARAM-EOF
#echo "NLS DataBase Parameters Check. Insert Done."

#-----------------------------------------------------------------------------------#
#Insert TimeZone.                                                                   #
#-----------------------------------------------------------------------------------#
echo "=> TimeZone Check."
sqlplus -s $PL_CONNECT_STRING <<-TIMEZONE-EOF
conn $PL_CONNECT_STRING;
set heading on feedback on;
INSERT INTO SYSADM.PS_DATAMIN_EXPZ_XX(RUNDATE,VERSION_NBR,FILENAME,VERSION,CONNID)
SELECT DISTINCT TO_DATE('$CRUNDT','YYYY/MM/DD'),'$CURDT_BTCHCNT',FILENAME, VERSION, CON_ID
FROM v\$timezone_file B;
commit;
exit;
TIMEZONE-EOF
#echo "TimeZone. Insert Done."


#*********************************************************************
#Get Templates and History Records                                   *
#*********************************************************************
echo " "
echo "Templates executed in Date Range $FROM_DT and $TO_DT belongs to $ARCHIVE_YEAR Archival Year"

RESULTSET=$(sqlplus -s $PL_CONNECT_STRING <<-END-OF-SQL           
set pagesize 0;
set head off;
set feedback off;
SELECT DISTINCT B.PSARCH_ID, D.HIST_RECNAME 
FROM SYSADM.PSARCHTEMPLATE A
   , SYSADM.PSARCHTEMPOBJ  B
   , SYSADM.PSARCHOBJDEFN  C
   , SYSADM.PSARCHOBJREC   D
   , SYSADM.PSARCHBATCH    DM 
WHERE DM.PSARCH_ID  = A.PSARCH_ID 
AND    A.PSARCH_ID  = B.PSARCH_ID 
AND    C.PSARCH_OBJECT = B.PSARCH_OBJECT 
AND    C.PSARCH_OBJECT = D.PSARCH_OBJECT 
AND   DM.PSARCH_DTTM >= '$FROM_DT' 
AND   DM.PSARCH_DTTM < '$TO_DT'
ORDER BY 1,2;

EXIT;
END-OF-SQL);


#*********************************************************************
#Populate SQL Result Set into Array                                  *
#*********************************************************************
PREV_PSARCH_ID=NONE
COUNTER=0
i=0
j=0
k=0
echo "${RESULTSET}" |while read PSARCH_ID HIST_RECNAME
do
   ##ARRAYTESTBEGIN
   if [ $PSARCH_ID = $PREV_PSARCH_ID ]; then
	k=$(($k+1)) 
   else
    	if [ $COUNTER = 0 ]; then
      		i=0
      		j=0
      		k=0
    	else
    		j=$(($j+1))
    		k=0 
    	fi
   fi

   PREV_PSARCH_ID=$PSARCH_ID
   #echo $i $j $k
   TMPLARR[$i][0]=$i
   TMPLARR[$i][1]=$j
   TMPLARR[$i][2]=$k
   TMPLARR[$i][3]=$PSARCH_ID
   TMPLARR[$i][4]=$HIST_RECNAME
   echo ${TMPLARR[$i][0]} ${TMPLARR[$i][1]} ${TMPLARR[$i][2]} ${TMPLARR[$i][3]} ${TMPLARR[$i][4]}
   i=$(($i+1))
   COUNTER=$(($COUNTER+1))
   ##ARRAYTESTEND
done


echo "Completed Gathering Data. Total Templates to Export for Wave/Year - $ARCHIVE_YEAR in \"$ARCHIVE_ENV\": $((j+1))"
echo "Today's Export Version Counter No: $CURDT_BTCHCNT";

#*********************************************************************
#Build ExportDump content from Array Values                          *
#Call expdp ExportDump and Log the ExportDump in Stage Record        *
#*********************************************************************
PREV_TEMPLATE=NONE
LOOPCOUNTER=0
for (( x=0; x<$i; x++ ))
do 
   #echo "TMPLARR[$x][0]:" ${TMPLARR[$x][0]} ",TMPLARR[$x][1]:" ${TMPLARR[$x][1]} ",TMPLARR[$x][2]:" ${TMPLARR[$x][2]} ",TMPLARR[$x][3]:" ${TMPLARR[$x][3]} ",TMPLARR[$x][4]:" ${TMPLARR[$x][4]}
   #-----------------------------------------------------------------------------------#
   #Assign Array Values to Template & Record Var to loop through for Export Dump Build.#
   #-----------------------------------------------------------------------------------#
   CURR_TEMPLATE=${TMPLARR[$x][3]}
   HIST_RECORD=${TMPLARR[$x][4]}
   
   #----------------------------------------------------------------------------#
   #When Templates are same, add other History Record to Export Dump Content    #
   #----------------------------------------------------------------------------#
   if [ $CURR_TEMPLATE = $PREV_TEMPLATE ]; then          
        
	PARTEXT="$PARTEXT TABLES=SYSADM.PS_${HIST_RECORD} QUERY=SYSADM.PS_${HIST_RECORD}:\"WHERE PSARCH_ID='$CURR_TEMPLATE' AND PSARCH_BATCHNUM||PSARCH_ID IN (SELECT PSARCH_BATCHNUM||PSARCH_ID FROM SYSADM.PSARCHBATCH WHERE PSARCH_DTTM >= '$FROM_DT' AND PSARCH_DTTM < '$TO_DT')\""
   
   else
   #----------------------------------------------------------------------------#
   #When Templates are different, start New Export Build Script for new Template#
   #----------------------------------------------------------------------------#
        #-----------------------------------------------------------------------#
        #Call Function to Execute ExportDump and Log ExportDump to Stage Record #
        #-----------------------------------------------------------------------#
        if [ $LOOPCOUNTER != 0 ]; then
          
           #Call_ExpTemplEcho "${PREV_TEMPLATE}" 
                    
           TEMPL_EXP_START_TIME=`date`
           PREEXPDTTM=$(date +"%r") 
           xx=$((x-1))          
           REC_COUNT=$((${TMPLARR[$xx][2]}+1))
           
           #echo '!eq: ' ${PARTEXT}
           expdp $PARTEXT
           BASEDIR=$(pwd)/${PREV_TEMPLATE}/${ARCHIVE_ENV}          
           Call_ExecExportDump_Insert '!eq:' "${PREV_TEMPLATE}" "${PARTEXT}" "${BASEDIR}" "${CURDT_BTCHCNT}" "${PREV_TEMPLATE}_${RUNDATE}_${ARCHIVE_YEAR}_${FROM_DT}_${TO_DT}_${ARCHIVE_ENV}.dmp" "${REC_COUNT}" "${TEMPL_EXP_START_TIME}" "${PREEXPDTTM}"
        
           #Call_ExpTemplEcho "${PREV_TEMPLATE}"
           #TEMPL_EXP_START_TIME=`date`
           #PREEXPDTTM=$(date +"%r")
        
 
        fi

        #-----------------------------------------------------------------------#
        # start New ExportDump Build Script for new Template                    #
        #-----------------------------------------------------------------------# 

       PARTEXTM="userid=\"/ as sysdba\" directory=${CURR_TEMPLATE}_${ARCHIVE_ENV} dumpfile=${CURR_TEMPLATE}_${RUNDATE}_${ARCHIVE_YEAR}_${FROM_DT}_${TO_DT}_${ARCHIVE_ENV}_%U.dmp logfile=${CURR_TEMPLATE}_${RUNDATE}_${ARCHIVE_YEAR}_${FROM_DT}_${TO_DT}_${ARCHIVE_ENV}.log parallel=18 EXCLUDE=statistics EXCLUDE=TRIGGER ENCRYPTION=ALL ENCRYPTION_MODE=DUAL ENCRYPTION_ALGORITHM=AES256 ENCRYPTION_PASSWORD=$ENCRYPTPWD FILESIZE=10G COMPRESSION=ALL"
                           
        PARTEXT="$PARTEXTM TABLES=SYSADM.PS_${HIST_RECORD} QUERY=SYSADM.PS_${HIST_RECORD}:\"WHERE PSARCH_ID='$CURR_TEMPLATE' AND PSARCH_BATCHNUM||PSARCH_ID IN (SELECT PSARCH_BATCHNUM||PSARCH_ID FROM SYSADM.PSARCHBATCH WHERE PSARCH_DTTM >= '$FROM_DT' AND PSARCH_DTTM < '$TO_DT')\""
       
    fi    
        PREV_TEMPLATE=$CURR_TEMPLATE                  
        LOOPCOUNTER=$(($LOOPCOUNTER+1))    

        if [ ${TMPLARR[$x][2]} = 0 ]; then
           Call_ExpTemplEcho "${CURR_TEMPLATE}"
           TEMPL_EXP_START_TIME=`date`
           PREEXPDTTM=$(date +"%r")
        fi

   #-----------------------------------------------------------------------------------#
   #Insert History Record Counts.                                                      #
   #-----------------------------------------------------------------------------------#
   #echo "History Record Counts ***"
   echo "=> ( $((${TMPLARR[$x][2]}+1)) ) $HIST_RECORD : Get History Record Counts"
   sqlplus -s $PL_CONNECT_STRING <<-COUNT-EOF
   conn $PL_CONNECT_STRING;
   set heading on feedback on;
   INSERT INTO SYSADM.PS_DATAMIN_EXPC_XX(RUNDATE,PSARCH_ID,VERSION_NBR,HIST_RECNAME,EXPORT_COUNT) 
   SELECT DISTINCT TO_DATE('$CRUNDT','YYYY/MM/DD'),'$CURR_TEMPLATE','$CURDT_BTCHCNT','$HIST_RECORD',COUNT(1)
   FROM SYSADM.PS_$HIST_RECORD A,SYSADM.PSARCHBATCH B 
   WHERE A.PSARCH_BATCHNUM = B.PSARCH_BATCHNUM
   AND A.PSARCH_ID = B.PSARCH_ID
   AND A.PSARCH_ID = '$CURR_TEMPLATE' 
   AND PSARCH_DTTM >= '$FROM_DT'
   AND PSARCH_DTTM < '$TO_DT';
   commit;
   exit;
COUNT-EOF


   #echo "History Record $HIST_RECORD Counts: Insert Done." 



   #-----------------------------------------------------------------------------------#
   #Insert History Record TableSpace, Index & Index TableSpace                         #
   #-----------------------------------------------------------------------------------#
   #echo "History Record TableSpace, Index & Index TableSpace ***"
   echo "..Get TableSpace, Index & Index TableSpace"
   sqlplus -s $PL_CONNECT_STRING <<-TABLESPACE-EOF
   conn $PL_CONNECT_STRING;
   set heading on feedback on;
   INSERT INTO SYSADM.PS_DATAMIN_EXPS_XX(RUNDATE,PSARCH_ID,VERSION_NBR,HIST_RECNAME,DDLSPACENAME,PTSF_INDEX_NAME,PPMU_TBLSPACENAME)
   SELECT TO_DATE('$CRUNDT','YYYY/MM/DD'),'$CURR_TEMPLATE','$CURDT_BTCHCNT','$HIST_RECORD',RTS.TABLESPACE_NAME,ITS.INDEX_NAME,ITS.TABLESPACE_NAME 
   FROM DBA_TABLES       RTS    
   , DBA_INDEXES         ITS
   WHERE RTS.TABLE_NAME = ITS.TABLE_NAME
   AND RTS.TABLE_NAME   = 'PS_'||'$HIST_RECORD';
   commit;
   exit;
TABLESPACE-EOF

   #echo "History Record $HIST_RECORD: TableSpace, Index & Index TableSpace : Insert Done."

        FREC_COUNT=${TMPLARR[$x][2]}  
         
    done
#-----------------------------------------------------------------------------------------#
#Call Function to Execute ExportDump and Log ExportDump to Stage Record for Last Template #
#-----------------------------------------------------------------------------------------#
#TEMPL_EXP_START_TIME=`date`
#PREEXPDTTM=$(date +"%r")
REC_COUNT=$(($FREC_COUNT+1))

#Call_ExpTemplEcho  "${PREV_TEMPLATE}"
 
#echo 'Final: ' ${PARTEXT}
expdp $PARTEXT
BASEDIR=$(pwd)/${PREV_TEMPLATE}/${ARCHIVE_ENV}
Call_ExecExportDump_Insert 'Final' "${PREV_TEMPLATE}" "${PARTEXT}" "${BASEDIR}" "${CURDT_BTCHCNT}" "${PREV_TEMPLATE}_${RUNDATE}_${ARCHIVE_YEAR}_${FROM_DT}_${TO_DT}_${ARCHIVE_ENV}.dmp" "${REC_COUNT}" "${TEMPL_EXP_START_TIME}" "${PREEXPDTTM}"
#echo 'Final:' "${PARTEXT}" "${BASEDIR}" "${CURDT_BTCHCNT}"

##ARRAYTESTEND

echo "#########################################################################################"
echo "# Start time : $START_TIME "                                                            
echo "# End time   : `date`"
echo "#########################################################################################"
