#! /bin/sh

WORKSPACE=${TMP-/var/tmp/}$$/
mkdir ${WORKSPACE}

for F in *.jpg;
do
    jpegtopnm < ${F} > ${WORKSPACE}$(basename ${F} jpg)pnm
done

WIDTH=$(ls -1 *.jpg | cut -f1 -d. | cut -f2 -d_ | sort -n | tail -1)
HEIGHT=$(ls -1 *.jpg | cut -f1 -d. | cut -f1 -d_ | sort -n | tail -1)

for ROW in $(seq 0 ${HEIGHT});
do
    WORK= " "
    for COL in $(seq 0 ${WIDTH});
    do
	WORK="${WORK} ${WORKSPACE}${ROW}_${COL}.pnm"
    done
    pnmcat -tb ${WORK} > ${WORKSPACE}row-${ROW}.pnm
done
WORK= " "
for ROW in $(seq 0 ${HEIGHT});
do
    WORK="${WORK} ${WORKSPACE}row-${ROW}.pnm"
done

pnmcat -lr ${WORKSPACE}${WORK} > out.pnm

rm ${WORKSPACE}/*.pnm
rmdir ${WORKSPACE}