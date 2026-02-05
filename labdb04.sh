export LABDB=ODLLAB1

db2 "CONNECT TO ${LABDB}"

# archive logs (needed for online backup/rollforward)
db2 "UPDATE DB CFG FOR ${LABDB} USING LOGARCHMETH1 DISK:/ars/data/alog/${LABDB}"

# incremental support
db2 "UPDATE DB CFG FOR ${LABDB} USING TRACKMOD ON"

db2 "TERMINATE"

# NEWLOGPATH change becomes effective only after deactivate/activate
db2 "DEACTIVATE DB ${LABDB}"
db2 "ACTIVATE DB ${LABDB}"

db2 "CONNECT TO ${LABDB}"