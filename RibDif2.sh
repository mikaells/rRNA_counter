#!/bin/bash

####
#A program to analyse the 16s variation in each genome of a genus
#Mikael Lenz Strube
#10-02-2021
####

#Input sanitation
if [ "$#" -lt 2 ]; then
	echo -e "\nUsage is\nRibDif \n\t-g|--genus <genus>\n\t[-c|--clobber\tDelete previous run]\n\t[-a|--ANI\tdisable ANI]\n\t[-f|--frag\tinclude non-complete genomes]\n\t[-i|--id\tclustering cutoff <0.5-1>]\n\t[-t|--threads\tthreads]\n\n"
	exit;
fi

#working out where script is to avoid problems with being put in strange places
scriptDir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

#Working out command line arguments
clobber=false
ANI=true
frag=false
id=1
Ncpu=$( nproc --all )
primers="$scriptDir/v3v4.primers"

while :
do
 case "$1" in
	-h | --help)
		echo -e "\nUsage is\nRibDif \n\t-g|--genus <genus>\n\t[-c|--clobber\tdelete previous run]\n\t[-a|--ANI\tdisable ANI]\n\t[-f|--frag\tinclude non-complete genomes]\n\t[-i|--id\tclustering cutoff <0.5-1>]\n\t[-t|--threads\tthreads]\n\n"
		exit 0
		;;
	-g | --genus)
		genus_arg="$2"
		shift 2
		;;
	-c | --clobber)
		clobber=true
		shift
		;;
	-a | --ANI)
		ANI=false
		shift
		;;
	-f | --frag)
		frag=true
		shift
		;;
	-i | --id)
		id="$2"
		shift 2
		;;
	-t | --threads)
		Ncpu="$2"
		shift 2
		;;
	-p | --primers)
		primers="$2"
		shift 2 
		;;
	--)
		shift
		break
		;;
	-*)
		echo -e "Error: Unexpected option $1"
		exit 4
		;;
	*)
		break
		;;
 esac
done

cat $primers
echo "g: $genus_arg c: $clobber a: $ANI f: $frag i: $id t: $Ncpu"

echo -e "\n***RibDif running on $genus_arg***\n\n"

#if there is a space in the genus argument, assume a species
if [[ $genus_arg =~ " " ]]
then
	echo -e "Detected species.\n\n"
	genus=$(echo "$genus_arg" | sed -r 's/ /_/g')
else
	genus=$genus_arg
fi


#delete previous run if clobber is true
if [[ $clobber = true  ]]
then
	echo -e "Removing old run of $genus."
	if [[ -d $genus ]]
	then
		rm -r $genus
		echo -e "\n"
	else
		echo -e "\t$genus-folder does not exist, ignoring -c/--clobber\n\n"
	fi
elif [[ -d $genus ]]
then
	echo -e "$genus-folder already exists, run again with c/--clobber  or find another folder to run in.\n\n"
	exit
fi


#Use ncbi-genome-download for downloading genus/species
echo -e  "Downloading all strains of $genus into $genus/refseq/bacteria/ with ncbi-genome-download.\n";
if [[ $frag = true  ]]
then
	echo -e "\tIncluding non-complete genomes.\n"
	ncbi-genome-download  -F 'fasta' --genera "$genus_arg" -o $genus -p $((Ncpu*2)) bacteria
else
	ncbi-genome-download  -F 'fasta' -l 'complete' --genera "$genus_arg" -o $genus -p $((Ncpu*2)) bacteria
fi

echo -e "\t$(ls $genus/refseq/bacteria/ | wc -l) genomes downloaded.\n\n"

#checking if download worked
if [ ! -d $genus ]
then
	echo -e "\n\tDownload failed, is $genus_arg a correct genus?\n\n"
	exit
fi

#save command line
echo "RibDif.sh --genus $genus --clobber $clobber --ANI $ANI --frag $frag --id $id --threads $Ncpu" > $genus/run_cmd

#gunzip all in parallel
echo -e "Gunzipping all files.\n\n"
find $genus/refseq/bacteria/ -name "*gz" | parallel -j $Ncpu 'gunzip {}'

#renaming fna-files
echo -e "Renaming fastas and adding GCF (for genomes with multiple chromosomes).\n\n"
#people should really think about the names they give their genomes
find $genus/refseq/bacteria/ -name "*fna" | parallel -j $Ncpu 'sed -i "s/[:,/()=#\0x27]//g; s/[: ]/_/g" {} '
find $genus/refseq/bacteria/ -name "*fna" | parallel -j $Ncpu ' GCF=$(echo $(basename $(dirname {})));  sed -E -i "s/^>(.*)/>$GCF"_"\1/g" {} '

#run barrnap
echo -e "Finding all rRNA genes longer than 90% of expected length with barrnap.\n\n"
find $genus/refseq/bacteria/ -name "*fna" | parallel -j $Ncpu ' barrnap --kingdom "bac" --quiet --threads 1 --reject 0.90 -o "{.}.rRNA" {}'  > barrnap.log 2>&1

#fish out 16S
echo -e "Fishing out 16S genes.\n\n"
find $genus/refseq/bacteria/ -name "*rRNA" | parallel -j $Ncpu 'grep "16S" {} -A1 > {.}.16S'

#renaming headers in 16s
echo -e "Renaming 16S headers.\n\n"
find $genus/refseq/bacteria/ -name "*.16S" | parallel -j $Ncpu ' sed -E -i "s/^>16S_rRNA::(.*):.*/>\1_/g" {} ; awk -i inplace "/^>/ { \$0=\$0"_"++i }1" {}  '

#run splitting 16S, cant make it work in parallel
echo -e "Splitting 16S.\n\n"
original_PWD=$PWD
for folder in $genus/refseq/bacteria/*; do
	mkdir $folder/indiv_16S_dir/
	cd  $folder/indiv_16S_dir/
	awk '/^>/{f=(++i-1)".fna"}1 {print > f}' ../*.16S
	cd $original_PWD
done

#calculating ANI for each genome
if [[ $ANI = false  ]]
then
	echo -e "Skipping detailed intra-genomic analysis and ANI.\n\n"
else
	echo -e "Calculating intra-genomic mismatches and ANI for each genome.\n\n"
	ls -d $genus/refseq/bacteria/*/indiv_16S_dir/ | parallel -j $Ncpu 'average_nucleotide_identity.py -i {} -o {}/../ani/'
fi

echo -e "Alligning 16S genes within genomes with muscle and builing trees with fastree.\n\n"
find $genus/refseq/bacteria/ -name "*.16S" | parallel -j $Ncpu 'muscle -in {} -out {.}.16sAln -quiet; sed -i "s/[ ,]/_/g" {.}.16sAln; fasttree -quiet -nopr -gtr -nt {.}.16sAln > {.}.16sTree '

#Summarizing data
echo -e "Summarizing data into $genus/$genus-summary.csv.\n\n"
echo -e "GCF\tGenus\tSpecies\t#16S\tMean\tSD\tMin\tMax\tTotalDiv" > $genus/$genus-summary.tsv
ls -d $genus/refseq/bacteria/* | parallel -j $Ncpu Rscript $scriptDir/run16sSummary.R {}/ani/ANIm_similarity_errors.tab {}/*16sAln {}/16S_div.pdf {}/*fna {}/*16sTree >> $genus/$genus-summary.tsv


wait;

mkdir $genus/full
find $genus/refseq/bacteria/ -name "*16S" -exec cat {}  \; > $genus/full/$genus.16S

echo -e "Alligning all 16S rRNA genes with mafft and building tree with fasttree.\n\n"
mafft --auto --quiet --adjustdirection --thread $Ncpu $genus/full/$genus.16S > $genus/full/$genus.aln
fasttree -quiet -nopr -gtr -nt $genus/full/$genus.aln > $genus/full/$genus.tree


echo -e "Making amplicons with in_silico_pcr.\n\n"
if [[ primers = "$scriptDir/v3v4.primers" ]]
then
	echo -e "\tUsing default primers\n\n"
else
	echo -e "\tUsing user-defined primers\n\n"
fi

mkdir $genus/amplicons/

while read line;
do
	#echo  $line
	name=$(echo $line | cut -f1 -d" ")
	forw=$(echo $line | cut -f2 -d" ")
	rev=$(echo $line  | cut -f3 -d" ")

	echo -e "Working on \t$name\n\n";
	$scriptDir/in_silico_PCR.pl -s $genus/full/$genus.16S -a $forw    -b $rev -r -m -i > $genus/amplicons/$genus-$name.summary 2> $genus/amplicons/$genus-$name.temp.amplicons

	#renaming headers
	seqkit replace --quiet -p "(.+)" -r '{kv}' -k $genus/amplicons/$genus-$name.summary $genus/amplicons/$genus-$name.temp.amplicons > $genus/amplicons/$genus-$name.amplicons


	#deleting old amplicon files
	rm $genus/amplicons/$genus-$name.temp.amplicons
	rm $genus/amplicons/$genus-$name.summary


	echo -e "Alligning all amplicons with mafft and building tree with fasttree.\n\n"
	mafft --auto --quiet --adjustdirection --thread $Ncpu $genus/amplicons/$genus-$name.amplicons > $genus/amplicons/$genus-$name.aln
	fasttree -quiet -nopr -gtr -nt $genus/amplicons/$genus-$name.aln > $genus/amplicons/$genus-$name.tree

	echo -e "Making unique clusters with vsearch.\n\n"
	mkdir $genus/amplicons/$name-clusters
	vsearch -cluster_fast $genus/amplicons/$genus-$name.amplicons --id $id  -strand both --uc $genus/amplicons/$genus-$name.uc --clusters $genus/amplicons/$name-clusters/$genus-$name-clus --quiet

	echo -e "Making amplicon summary file for tree viewer import.\n\n"
	Rscript $scriptDir/Format16STrees.R $genus/amplicons/$genus-$name.tree $genus/amplicons/$genus-$name-meta.csv $genus/amplicons/$genus-$name.uc

	echo -e "Making amplicon cluster membership heatmaps.\n\n"
	Rscript $scriptDir/MakeHeatmap.R $genus/amplicons/$genus-$name.uc $genus/amplicons/$genus-$name-heatmap.pdf

done < $primers

#clean up logs etc
rm Rplots.pdf
rm barrnap.log

echo -e "\nDone.\n\n"
