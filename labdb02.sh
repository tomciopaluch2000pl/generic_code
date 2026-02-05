export LABDB=ODLLAB1

# connect
db2 "CONNECT TO ${LABDB}"

# archive logs (needed for online + rollforward)
db2 "UPDATE DB CFG FOR ${LABDB} USING LOGARCHMETH1 DISK:/ars/data/alog/${LABDB}"

# incremental support
db2 "UPDATE DB CFG FOR ${LABDB} USING TRACKMOD ON"

db2 "TERMINATE"

# apply NEWLOGPATH (and generally reload DB cfg changes cleanly)
db2 "DEACTIVATE DB ${LABDB}"
db2 "ACTIVATE DB ${LABDB}"
db2 "CONNECT TO ${LABDB}"

# verify
db2 "GET DB CFG FOR ${LABDB}" | egrep -i "NEWLOGPATH|LOGARCHMETH1|TRACKMOD"

