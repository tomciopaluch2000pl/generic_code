export DB=ODLLAB1

db2 "DEACTIVATE DB ${DB}"

db2 "BACKUP DATABASE ${DB} TO /ars/data/backup/${DB} COMPRESS"


db2 "DROP DATABASE ${DB}"


db2 list db directory | grep -i ${DB}


db2 "RESTORE DATABASE ${DB} FROM /ars/data/backup/${DB}"


db2 "ACTIVATE DB ${DB}"
db2 "CONNECT TO ${DB}"


db2 "SELECT * FROM APP.TEST1 ORDER BY ID"


db2 "GET DB CFG FOR ${DB}" | egrep -i "LOGARCHMETH1|TRACKMOD"



