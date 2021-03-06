#!/bin/bash -e 

#set default paths - if these tools are within the $PATH then this script will work fine without them being defined in the .config
BOWTIE_PATH="bowtie"
SAMTOOLS_PATH="samtools"
R_PATH="R"

#Load the config file
if [ ! -e "$1" ]; then
  echo "$1"" does not exist!";
  echo "Usage: Bis-seq-pipeline-PE.sh [configfile]";
  exit 1;
fi

echo `date`" - Reading config file: $1";
source "$1";

#Check for existence of necessary files
if [ ! -e "$FASTQ1" ]; then echo "$FASTQ1 does not exist!"; exit 1; fi
if [ ! -e "$FASTQ2" ]; then echo "$FASTQ2 does not exist!"; exit 1; fi
if [ ! -e "$PIPELINE_PATH"/sql/Bis-seq-PE.schema ]; then echo "$PIPELINE_PATH""/sql/Bis-seq-PE.schema does not exist!"; exit 1; fi
if [ ! -e "$PIPELINE_PATH"/scripts/readChr.awk ]; then echo "$PIPELINE_PATH""/scripts/readChr.awk does not exist!"; exit 1; fi
if [ ! -e "$GENOME_PATH"/plus.1.ebwt ]; then echo "Forward bowtie index not found at $GENOME_PATH"; exit 1; fi
if [ ! -e "$GENOME_PATH"/minus.1.ebwt ]; then echo "Reverse bowtie index not found at $GENOME_PATH"; exit 1; fi

#check for existence of necessary tools 
if [ ! type -P sqlite3 &>/dev/null ]; then echo "sqlite3 command not found."; exit 1; fi
if [ ! type -P "$BOWTIE_PATH" &>/dev/null ]; then echo "$BOWTIE_PATH command not found."; exit 1; fi
if [ ! type -P "$SAMTOOLS_PATH" &>/dev/null ]; then echo "$SAMTOOLS_PATH command not found."; exit 1; fi
if [ ! type -P "$R_PATH" &>/dev/null ]; then echo "$R_PATH command not found."; exit 1; fi

#init the database
echo `date`" - Initialising the database";
rm -f "$PROJECT".db;
sqlite3 "$PROJECT".db < "$PIPELINE_PATH"/sql/Bis-seq-PE.schema;

echo `date`" - Importing reads into the database";
#Import FW & RV seqs in db, one row per read id
gunzip -c "$FASTQ1" |awk -v file2="$FASTQ2" 'BEGIN {
  FS="/"
  cmd="gunzip -c " file2
} {
  readname=$1
  getline FWseq
  getline
  getline FWqual

  cmd | getline
  cmd | getline RVseq
  cmd | getline
  cmd | getline RVqual
  
  tmp1=$1
  tmp2=$3
  tmp3=$4
  getline < file2
  print readname "|" FWseq "|" RVseq "|" FWqual "|" RVqual
}' | sed 's/^@//' | sort -t "|" -k1,1 | sqlite3 "$PROJECT".db '.import /dev/stdin reads';

#Convert C residues in reads to T
echo `date`" - Bisulfite converting reads";
#setup named pipes
gunzip -c "$FASTQ1" | sed -e 's/ .*//' -e '2~4s/C/T/g' > "$PROJECT".conv.fastq1;
gunzip -c "$FASTQ2" | sed -e 's/ .*//' -e '2~4s/G/A/g' > "$PROJECT".conv.fastq2;

#Map against forward strand, and filter out reads with too many MMs
echo `date`" - Bowtie mapping against forward strand";
"$BOWTIE_PATH" --norc "$BOWTIE_PARAMS" "$GENOME_PATH"/plus -1 "$PROJECT".conv.fastq1 -2 "$PROJECT".conv.fastq2 2> mapping.plus.log |  sed -e 'N' -e 's/\n/\t/' | awk -v maxmm=$(($MAX_MM+$MIN_MM_DIFF)) 'BEGIN {FS="\t"}{
  numFW=split($8, tmpFW, ":")-1
  if (numFW==-1) numFW=0
  numRV=split($16, tmpRV, ":")-1
  if (numRV==-1) numRV=0
  if ((numFW+numRV)<maxmm) {
    print substr($1,1,length($1)-2) "|" $3 "|" ($4+1) "|" ($12+1) "|+|" (numFW+numRV)
  }
}' | sed 's/plusU_//'> "$PROJECT".both.map;

#Same for reverse strand
echo `date`" - Bowtie mapping against reverse strand";
"$BOWTIE_PATH" --nofw "$BOWTIE_PARAMS" "$GENOME_PATH"/minus -1 "$PROJECT".conv.fastq1 -2 "$PROJECT".conv.fastq2 2> mapping.minus.log | sed -e 'N' -e 's/\n/\t/' | awk -v maxmm=$(($MAX_MM+$MIN_MM_DIFF)) 'BEGIN {FS="\t"}{
  numFW=split($8, tmpFW, ":")-1
  if (numFW==-1) numFW=0
  numRV=split($16, tmpRV, ":")-1
  if (numRV==-1) numRV=0
  if ((numFW+numRV)<maxmm) {
    print substr($1,1,length($1)-2) "|" $3 "|" ($12+1) "|" ($4+1) "|-|" (numFW+numRV)
  }
}' | sed 's/minusU_//'>> "$PROJECT".both.map;

gzip -f "$PROJECT".conv.fastq1;
gzip -f "$PROJECT".conv.fastq2;

#adjust no of mismatches for C's in read that are T's in the reference
echo `date`" - Getting the reference sequence of reads mapping positions"
sort -t "|" -k2,2 -k3,3n "$PROJECT".both.map | awk -v readLength="$READ_LENGTH" -v pipeline="$PIPELINE_PATH" -v genomePath="$GENOME_PATH" 'BEGIN {FS="|"}
function revComp(temp) {
    for(i=length(temp);i>=1;i--) {
        tempChar = substr(temp,i,1)
        if (tempChar=="A") {printf("T")} else
        if (tempChar=="C") {printf("G")} else
        if (tempChar=="G") {printf("C")} else
        if (tempChar=="T") {printf("A")} else
        {printf("N")}
    }
} { #entry point
    if ($2!=chr) { #if hit a new chromosome, read it into chrSeq
        chr=$2
        gf = "awk -f "pipeline"/scripts/readChr.awk "genomePath"/"chr".fa" 
        gf | getline chrSeq
    }
    FW=toupper(substr(chrSeq,$3,readLength+1)) #retrieve forward sequence
    RV=toupper(substr(chrSeq,$4,readLength+1)) #retrieve reverse sequence
    printf("%s|%s|%s|%s|%s|%s|",$1,$2,$3,$4,$5,$6)
    if ($5=="+") {
        FW=toupper(substr(chrSeq,$3,readLength+1)) #retrieve forward sequence
        RV=toupper(substr(chrSeq,$4,readLength+1)) #retrieve reverse sequence
        printf("%s|",FW)
        revComp(RV)
        printf("\n")
    } else {
        FW=toupper(substr(chrSeq,$3-1,readLength+1)) #retrieve forward sequence
        RV=toupper(substr(chrSeq,$4-1,readLength+1)) #retrieve reverse sequence
        revComp(FW)
        printf("|%s\n",RV)
    }
}' | sort -t "|" -k1,1 |  sqlite3 "$PROJECT".db '.import /dev/stdin mappingBoth'
gzip -f "$PROJECT".both.map;

echo `date`" - Adjusting number of mismatches for C->T errors in mapping"
sqlite3 "$PROJECT".db "SELECT mappingBoth.*, reads.sequenceFW, reads.sequenceRV
  FROM mappingBoth JOIN reads ON mappingBoth.id=reads.id;" | awk -v bp="$READ_LENGTH" 'BEGIN {FS="|"} {
	mm=0;
    refCs=0;
	nonCpG=0;
    for(i=1;i<=bp;i++) {
        temp1 = substr($7,i,1)
    	temp2 = substr($9,i,1)
    	temp3 = substr($7,i,2)
    	if (temp1=="C") {
    		if (temp3!="CG") refCs++;
    		if (temp2!="C"&&temp2!="T") mm++;
    	} else if (temp1!=temp2) mm++;
    	if (temp2=="C" && temp1=="C" && temp3!="CG") nonCpG++;
    	temp1 = substr($8,i+1,1)
    	temp2 = substr($10,i,1)
    	temp3 = substr($8,i,2)
    	if (temp1=="G") {
            if (temp3!="CG") refCs++;
            refCs++;
    		if (temp2!="G"&&temp2!="A") mm++;
    	} else if (temp1!=temp2) mm++;
        if (temp2=="G" && temp1=="G" && temp3!="CG") nonCpG++;
    }
    print $1"|"$2"|"$3"|"$4"|"$5"|"mm"|"substr($7,1,bp)"|"substr($8,2,bp)"|"refCs"|"nonCpG
}' | gzip -c > "$PROJECT".both.adjust.csv.gz;
gunzip -c "$PROJECT".both.adjust.csv.gz | sort -t "|" -k1,1 | sqlite3 "$PROJECT".db '.import /dev/stdin mappingAdjust'

echo `date`" - Combining forward and reverse mappings and filtering out duplicate mappings and unconverted reads";
gunzip -c "$PROJECT".both.adjust.csv.gz | awk -v cutoff="$CONV_CUTOFF" 'BEGIN {FS="|"} {
    if ($9==0) {print $0} else if ($10/$9<=cutoff) print $0;
}' | cut -d "|" -f1,2,3,4,5,6,7,8 |  sort -t "|" -k 1,1 -k 6,6n  | awk -v maxmm=$MAX_MM -v mindiff=$MIN_MM_DIFF 'BEGIN {FS = "|"} {
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
}' | sort -t "|" -k1,1 |  sqlite3 "$PROJECT".db '.import /dev/stdin mapping'

echo `date`" - Exporting database to BAM files"
sqlite3 "$PROJECT".db "SELECT
mapping.id, mapping.chr, mapping.strand, mapping.positionFW, reads.sequenceFW, mapping.positionRV, reads.sequenceRV, reads.qualityFW, reads.qualityRV
FROM mapping LEFT JOIN reads ON mapping.id=reads.id WHERE mapping.strand='+';" | awk -v readLength="$READ_LENGTH" -v strand=+ -f "$PIPELINE_PATH"/scripts/createSAM.awk | "$SAMTOOLS_PATH" view -bt "$GENOME_PATH"/reflengths - > "$PROJECT".mappings.plus.bam    
"$SAMTOOLS_PATH" sort "$PROJECT".mappings.plus.bam "$PROJECT".plus;
"$SAMTOOLS_PATH" index "$PROJECT".plus.bam;
rm "$PROJECT".mappings.plus.bam;

sqlite3 "$PROJECT".db "SELECT
mapping.id, mapping.chr, mapping.strand, mapping.positionFW, reads.sequenceFW, mapping.positionRV, reads.sequenceRV, reads.qualityFW, reads.qualityRV
FROM mapping LEFT JOIN reads ON mapping.id=reads.id WHERE mapping.strand='-';" | awk -v readLength="$READ_LENGTH" -v strand=- -f "$PIPELINE_PATH"/scripts/createSAM.awk | "$SAMTOOLS_PATH" view -bt "$GENOME_PATH"/reflengths - > "$PROJECT".mappings.minus.bam
"$SAMTOOLS_PATH" sort "$PROJECT".mappings.minus.bam "$PROJECT".minus;
"$SAMTOOLS_PATH" index "$PROJECT".minus.bam;
rm "$PROJECT".mappings.minus.bam;

#create bed & Rdata (GD) file for coverage mapping for each strand
echo `date`" - Creating coverage bed and GenomeData files";
sqlite3 -csv "$PROJECT".db "SELECT chr, positionFW, positionRV FROM mapping WHERE strand='+';" | gzip -c > "$PROJECT".plus.bed.gz;
sqlite3 -csv "$PROJECT".db "SELECT chr, positionFW, positionRV FROM mapping WHERE strand='-';" | gzip -c > "$PROJECT".minus.bed.gz;

"$R_PATH" --vanilla --slave --args "$PROJECT".plus.bed.gz "$PROJECT".plus.Rdata "$READ_LENGTH" < "$PIPELINE_PATH"/scripts/bed2GD.R;
"$R_PATH" --vanilla --slave --args "$PROJECT".minus.bed.gz "$PROJECT".minus.Rdata "$READ_LENGTH" < "$PIPELINE_PATH"/scripts/bed2GD.R;

#Are C's found in CpG sites?
echo `date`" - Determining context of C residues"
sqlite3 -csv "$PROJECT".db "SELECT mapping.chr, mapping.positionFW, mapping.positionRV, mapping.strand, reads.sequenceFW, reads.sequenceRV
  FROM mapping JOIN reads ON mapping.id=reads.id;" | sort -t "," -k1,1 | awk 'BEGIN {FS = ","} {
	num=split($5, tmp, "C"); 
	upto=0
	for (i = 2; i <= num; i++) {
		upto = upto + 1 + length(tmp[i-1]);
		if ($4=="+") print $1 "," ($2+upto-1)
		else print $1 "," ($2+length($5)-(upto)-1)
	}
	num=split($6, tmp, "G"); 
	upto=0
	for (i = 2; i <= num; i++) {
		upto = upto + 1 + length(tmp[i-1]);
		if ($4=="+") print $1 "," ($3+length($5)-(upto))			
		else print $1 "," ($3+upto-2)
	}
}' | awk -v pipeline="$PIPELINE_PATH" -v genomePath="$GENOME_PATH" 'BEGIN {FS=","}
function revComp(temp) {
    for(i=length(temp);i>=1;i--) {
        tempChar = substr(temp,i,1)
        if (tempChar=="A") {printf("T")} else
        if (tempChar=="C") {printf("G")} else
        if (tempChar=="G") {printf("C")} else
        if (tempChar=="T") {printf("A")} else
        {printf("N")}
    }
} { #entry point
    if ($1!=chr) { #if hit a new chromosome, read it into chrSeq
        chr=$1
        gf = "awk -f "pipeline"/scripts/readChr.awk "genomePath"/"chr".fa" 
        gf | getline chrSeq
    }
    print(toupper(substr(chrSeq,$2,2)))
}' | sort | uniq -c > "$PROJECT".context;

#How many Cs in read vs reference?
echo `date`" - Determining conversion %"
sqlite3 -csv "$PROJECT".db "SELECT reads.sequenceFW, reads.sequenceRV, mapping.referenceFW, mapping.referenceRV
  FROM mapping JOIN reads ON mapping.id=reads.id;" | awk 'BEGIN {
	FS = ","
	readC=0
	refC=0
} {
	readC=readC+split($1,tmp,"C")-1
	readC=readC+split($2,tmp,"G")-1
	refC=refC+split($3,tmp,"C")-1
	refC=refC+split($4,tmp,"G")-1
} END {
	print "No of C residues in the read sequences: " readC
	print "No of C residues in the reference sequences: " refC
}' >> "$PROJECT".context;

NUM_READS=`sqlite3 "$PROJECT".db "SELECT COUNT(id) FROM reads;"`;
NUM_REPORTED=`sqlite3 "$PROJECT".db "SELECT COUNT(DISTINCT id) FROM mappingBoth;"`;
NUM_UNIQUE=`sqlite3 "$PROJECT".db "SELECT COUNT(id) FROM mapping;"`;
NUM_UNMAPPABLE=`sqlite3 "$PROJECT".db "SELECT COUNT(id) FROM reads \
WHERE id NOT IN(SELECT id FROM mappingBoth);"`;
NUM_MULTIPLE=`sqlite3 "$PROJECT".db "SELECT COUNT(id) FROM reads \
WHERE id IN(SELECT id FROM mappingBoth) \
AND id NOT IN (SELECT id FROM mapping);"`;

#Creating mapping log
echo `date`" - Creating mapping log"
echo "# reads processed: $NUM_READS" > mapping.log;
echo "# reads with at least one reported alignment: $NUM_REPORTED" >> mapping.log;
echo "# reads that failed to align: $NUM_UNMAPPABLE" >> mapping.log;
echo "# reads with alignments suppressed due to -m: $NUM_MULTIPLE" >> mapping.log;
echo "Reported $NUM_UNIQUE alignments to 1 output stream(s)" >> mapping.log;
