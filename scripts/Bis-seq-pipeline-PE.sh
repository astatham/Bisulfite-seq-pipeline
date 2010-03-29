#!/bin/bash -e

if [ ! -e "$1" ]; then
  echo "$1"" does not exist!";
  exit 1;
fi

source "$1";

if [ ! -e "$FASTQ1" ]; then
  echo "$FASTQ1"" does not exist!";
  exit 1;
fi

if [ ! -e "$FASTQ2" ]; then
  echo "$FASTQ2"" does not exist!";
  exit 1;
fi

#init the database
echo "* Initialising the database";
rm -f "$PROJECT".db;
sqlite3 "$PROJECT".db < $PIPELINE_PATH/sql/Bis-seq-PE.schema;

#Convert fastq into csv
echo "* Importing reads into the database";
gunzip -c "$FASTQ1"  | awk 'NR%4==1 || NR%4==2' | sed -e 's/ .*//' | sed -e 'N' -e 's/\//,/' -e 's/\n/,/' -e 's/^@//' >"$PROJECT".fastq1.csv;
gunzip -c "$FASTQ2"  | awk 'NR%4==1 || NR%4==2' | sed -e 's/ .*//' | sed -e 'N' -e 's/\//,/' -e 's/\n/,/' -e 's/^@//' >"$PROJECT".fastq2.csv;
#Import FW & RV seqs in db, one row per read id
awk -v file2="$PROJECT".fastq2.csv 'BEGIN {FS=","} {
  tmp1=$1
  tmp2=$3
  getline < file2
  print tmp1","tmp2","$3}' "$PROJECT".fastq1.csv > "$PROJECT".reads.csv
echo -e ".separator \",\"\n.import $PROJECT.reads.csv reads" | sqlite3 "$PROJECT".db;
gzip "$PROJECT".reads.csv;

#Record position of C residues in FW reads
echo "* Importing C residues in FW reads into the database";
awk 'BEGIN {FS = ","}; {\
num=split($3, tmp, "C"); \
upto=0
for (i = 2; i <= num; i++) {\
   upto = upto + 1 + length(tmp[i-1]);
   print $1 "," $2 "," upto;  \
}
}' "$PROJECT".fastq1.csv > "$PROJECT".C.csv;
echo -e ".separator \",\"\n.import $PROJECT.C.csv readsC" | sqlite3 "$PROJECT".db
gzip -f "$PROJECT".fastq1.csv
gzip -f "$PROJECT".C.csv

#Record position of G residues in RV reads
echo "* Importing G residues in RV reads into the database";
awk 'BEGIN {FS = ","}; {\
num=split($3, tmp, "G"); \
upto=0
for (i = 2; i <= num; i++) {\
   upto = upto + 1 + length(tmp[i-1]);
   print $1 "," $2 "," upto;  \
}
}' "$PROJECT".fastq2.csv > "$PROJECT".G.csv;
echo -e ".separator \",\"\n.import $PROJECT.G.csv readsC" | sqlite3 "$PROJECT".db
gzip -f "$PROJECT".fastq2.csv
gzip -f "$PROJECT".G.csv

#Convert C residues in reads to T
echo "* Bisulfite converting reads";
gunzip -c "$FASTQ1" | sed -e 's/ .*//' -e '2~4s/C/T/g' > "$PROJECT".conv.fastq1;
gunzip -c "$FASTQ2" | sed -e 's/ .*//' -e '2~4s/G/A/g' > "$PROJECT".conv.fastq2;

#Map against forward strand, and filter out reads with too many MMs
echo "* Bowtie mapping against forward strand";
bowtie --norc "$BOWTIE_PARAMS" "$BOWTIE_BS_INDEX".plus -1 "$PROJECT".conv.fastq1 -2 "$PROJECT".conv.fastq2 2> mapping.plus.log | gzip -c > "$PROJECT".plus.map.gz;

gunzip -c "$PROJECT".plus.map.gz | sed -e 'N' -e 's/\n/\t/' | awk -v maxmm=$(($MAX_MM+$MIN_MM_DIFF)) 'BEGIN {FS="\t"}{
  numFW=split($8, tmpFW, ":")
  numRV=split($16, tmpRV, ":")
  if ((numFW+numRV)<maxmm) {
    print substr($1,1,length($1)-2) "," $3 "," ($4+1) "," ($12+1) ",+," (numFW+numRV)
  }
}' | sed 's/plusU_//'> "$PROJECT".both.map.csv

#Same for reverse strand
echo "* Bowtie mapping against reverse strand";
bowtie --nofw "$BOWTIE_PARAMS" "$BOWTIE_BS_INDEX".minus -1 "$PROJECT".conv.fastq1 -2 "$PROJECT".conv.fastq2 2> mapping.minus.log | gzip -c > "$PROJECT".minus.map.gz;

gunzip -c "$PROJECT".minus.map.gz | sed -e 'N' -e 's/\n/\t/' | awk -v maxmm=$(($MAX_MM+$MIN_MM_DIFF)) 'BEGIN {FS="\t"}{
  numFW=split($8, tmpFW, ":")
  numRV=split($16, tmpRV, ":")
  if ((numFW+numRV)<maxmm) {
    print substr($1,1,length($1)-2) "," $3 "," ($4+1) "," ($12+1) ",-," (numFW+numRV)
  }
}' | sed 's/minusU_//'>> "$PROJECT".both.map.csv

gzip "$PROJECT".conv.fastq1;
gzip "$PROJECT".conv.fastq2;

#adjust no of mismatches for C's in read that are T's in the reference
echo "Getting the reference sequence of reads mapping positions\n"
R --vanilla --slave --quiet --args "$PROJECT".both.map.csv "$PROJECT".both.reference.csv $READ_LENGTH < "$PIPELINE_PATH"/scripts/getReferenceSequences.R;
echo -e ".separator \",\"\n.import ""$PROJECT"".both.reference.csv mappingBoth" | sqlite3 "$PROJECT".db

sqlite3 -csv "$PROJECT".db "SELECT mappingBoth.*, readsC.pair, readsC.position
  FROM mappingBoth LEFT OUTER JOIN readsC On mappingBoth.id=readsC.id;" | sort -t "," -k 1,1 -k 2,2 -k 3,3n -k6,6n | awk 'BEGIN {FS=","} {
	s=($1","$2","$3","$4","$5",")
    if (s != prevs) {
        if ( FNR > 1 ) print (prevs newMM)
        newMM = $6
	}
	if ($9=="1") { #check that the reference base actually *was* a C on forward read
		if (substr($7, $10, 1)!="C") newMM = newMM+1
	} else if ($9=="2") { #check that the reference base actually *was* a G on reverse read
		if (substr($8, $10, 1)!="G") newMM = newMM+1	
	}
	prevs = s
} END {
	print (prevs newMM)
}' > "$PROJECT".both.adjust.csv;

#Combine forward and reverse strand mappings, filter out duplicates
echo "* Combining and filtering forward and reverse mappings";
sort -t "," -k 1,1 -k 6,6n "$PROJECT".both.adjust.csv  | awk -v maxmm=$MAX_MM -v mindiff=$MIN_MM_DIFF 'BEGIN {FS = ","} {
    s = $1
    if (s != prevs) {
        if ( FNR > 1 ) {
			if ( prevval<=maxmm && valdiff>=mindiff) print prevline
        }
        prevval = $6
        prevline = $0
        valdiff = mindiff
    }
    else valdiff = prevval-$6
    prevs = s
}
END {
	if ( prevval<=maxmm && valdiff>=mindiff) print prevline
}' | cut -d "," --complement -f6  > "$PROJECT".map.csv

#import into the db
echo -e ".separator \",\"\n.import ""$PROJECT"".both.adjust.csv mappingAdjust" | sqlite3 "$PROJECT".db
#gzip -f "$PROJECT".both.map.csv

echo -e ".separator \",\"\n.import ""$PROJECT"".map.csv mapping" | sqlite3 "$PROJECT".db
gzip -f "$PROJECT".map.csv

#create mappingC table
echo "* Creating mappingC table";
sqlite3 -csv "$PROJECT".db "SELECT mapping.id, mapping.chr, mapping.position, mapping.strand, readsC.position \
FROM readsC JOIN mapping ON readsC.id=mapping.id" | awk 'BEGIN {FS = ","}; {\
	printf "%s,%s,",$1,$2;
	if ($4=="+") {printf "%s,",($3+$5-1);} else {printf "%s,",($3-$5);}
	print $4
	}' > "$PROJECT".mapC.csv
echo -e ".separator \",\"\n.import ""$PROJECT"".mapC.csv mappingC" | sqlite3 "$PROJECT".db
gzip -f "$PROJECT".mapC.csv

#Create GenomeData R instances of the mapped reads and their Cs
echo "* Converting to GD Rdata";
R --vanilla --slave --quiet --args "$PROJECT".map.csv.gz "$PROJECT".Rdata < $PIPELINE_PATH/scripts/csvmap2GD.R &> /dev/null;
R --vanilla --slave --quiet --args "$PROJECT".mapC.csv.gz "$PROJECT".C.Rdata < $PIPELINE_PATH/scripts/csvmap2GD.R &> /dev/null;

#create mapping.log
echo "* Creating mapping.log";
NUM_READS=`sqlite3 "$PROJECT".db "SELECT COUNT(id) FROM reads;"`;
NUM_UNIQUE=`sqlite3 "$PROJECT".db "SELECT COUNT(id) FROM mapping;"`;
NUM_UNMAPPABLE=`sqlite3 "$PROJECT".db "SELECT COUNT(id) FROM reads \
WHERE id NOT IN(SELECT id FROM mappingBoth);"`;
NUM_MULTIPLE=`sqlite3 "$PROJECT".db "SELECT COUNT(id) FROM reads \
WHERE id IN(SELECT id FROM mappingBoth) \
AND id NOT IN (SELECT id FROM mapping);"`;

echo "# reads processed: $NUM_READS" > mapping.log;
echo "# reads with at least one reported alignment: $NUM_UNIQUE" >> mapping.log;
echo "# reads that failed to align: $NUM_UNMAPPABLE" >> mapping.log;
echo "# reads with alignments suppressed due to -m: $NUM_MULTIPLE" >> mapping.log;
echo "Reported $NUM_UNIQUE alignments to 1 output stream(s)" >> mapping.log;