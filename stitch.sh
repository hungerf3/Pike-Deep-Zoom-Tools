#! /bin/sh

for F in *.jpg;
do
    jpegtopnm < ${F} > $(basename ${F} jpg)pnm
done

WIDTH=$(ls -1 *.jpg | cut -f1 -d. | cut -f2 -d_ | sort -n | tail -1)
HEIGHT=$(ls -1 *.jpg | cut -f1 -d. | cut -f1 -d_ | sort -n | tail -1)

for ROW in $(seq 0 ${HEIGHT});
do
    rm work.txt
    touch work.txt
    for COL in $(seq 0 ${WIDTH});
    do
	echo ${ROW}_${COL}.pnm >> work.txt
    done
    pnmcat -tb $(cat work.txt) > row-${ROW}.pnm
done
rm work.txt
touch work.txt
for ROW in $(seq 0 ${HEIGHT});
do
    echo row-${ROW}.pnm >> work.txt
done

pnmcat -lr $(cat work.txt) > out.pnm
