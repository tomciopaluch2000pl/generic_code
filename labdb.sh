#create directories

export LABDB=ODLLAB1

mkdir -p /ars/data/plog/${LABDB}
mkdir -p /ars/data/alog/${LABDB}
mkdir -p /ars/data/backup/${LABDB}

ls -ld /ars/data/plog/${LABDB} /ars/data/alog/${LABDB} /ars/data/backup/${LABDB}
df -g /ars/data

#create db

db2 "CREATE DATABASE ${LABDB} ON /ars/data/db1 USING CODESET UTF-8 TERRITORY PL COLLATE USING SYSTEM"

#configure logs

db2 "CONNECT TO ${LABDB}"

# active logs (separate from data)
db2 "UPDATE DB CFG FOR ${LABDB} USING NEWLOGPATH /ars/data/plog/${LABDB}"

# archive logs (separate from data) - required for online recovery / rollforward
db2 "UPDATE DB CFG FOR ${LABDB} USING LOGARCHMETH1 DISK:/ars/data/alog/${LABDB}"

# incremental support
db2 "UPDATE DB CFG FOR ${LABDB} USING TRACKMOD ON"

db2 "TERMINATE"
db2 "ACTIVATE DB ${LABDB}"
db2 "CONNECT TO ${LABDB}"

db2 "GET DB CFG FOR ${LABDB}" | egrep -i "NEWLOGPATH|LOGARCHMETH1|TRACKMOD|LOGFILSIZ|LOGPRIMARY|LOGSECOND"

