#!/usr/bin/env bash

#: phyml_protModelFinder.sh
#: Author: Pablo Vinuesa, CCG-UNAM, @pvinmex, https://www.ccg.unam.mx/~vinuesa/
#: AIM: simple wraper script around phyml, to select a good model for protein alignments
#:      compute AIC, BIC, delta_BIC and BICw, and estimate a ML phylogeny using the best-fitting model
#: LICENSE: GPL v3.0. See https://github.com/vinuesa/get_phylomarkers/blob/master/LICENSE
 
#: Desgin:  phyml_protModelFinder.sh evaluates a set of the named empirical substitution matices 
#      currently implemented in phml v3.*, combining them or not with +G and/or +f
# - Amino-acid based models : LG (default) | WAG | JTT | MtREV | Dayhoff | DCMut | RtREV | CpREV | VT | AB
#		              Blosum62 | MtMam | MtArt | HIVw |  HIVb | custom

# set bash strict mode: http://redsymbol.net/articles/unofficial-bash-strict-mode/
#set -euo pipefail # fails in some calls on tepeu with old phyml and bash; on buluc or tepeu use set -uo pipefail
set -uo pipefail

host=$(hostname)

progname=${0##*/}
version='2.2.2_2024-12-12_GUADALUPE' # v2.2.2_2024-12-12_GUADALUPE: fixed awk exp() out of range error message, by replacing with 2.7183^()
  # v2.1.2_2024-12-12_GUADALUPE; major upgrade
  # - added getopts interface with key options -m -s -b to control model set, search and branch-support methods.
  # - improved checking of user-provided input data and parameters.
  # v2.0_2024-12-11; major upgrade: added getopts interface; improved checking of user-provided input data and parameters.
  # v1.2_2024-12-03 fixed check_is_phylip
  # phyml_protModelFinder.sh v0.8_2023-11-17; 
  # - fixed phyml call using original matrix aa frequencies with -f m
  # - the change above makes phyml_protModelFinder.sh primates_21_AA.phy 5 select the same HIVb+G model, with same BIC & BICw as
  #   prottest3 -i primates_21_AA.phy -BIC -G -F -S 0 -threads 20
		       
		       
min_bash_vers=4.4 # required to write modern bash idioms:
                  # 1.  printf '%(%F)T' '-1' in print_start_time; and 
                  # 2. passing an array or hash by name reference to a bash function (since version 4.3+), 
		  #    by setting the -n attribute
		  #    see https://stackoverflow.com/questions/16461656/how-to-pass-array-as-an-argument-to-a-function-in-bash

min_phyml_version=3.3 # this corresponds to 3.3.year; check_phyml_version also extracts the year, suggesting to update to v2022
phymlv=''
phymlyr=''

# by default, use a single seed tree (BioNJ)
n_starts=1
model_set=''
search_method=BEST
boot=-5

# declare array and hash variables
declare -a models        # array holding the base models (empirical substitution matrices to be evaluated)
declare -A model_cmds    # hash holding the commands for each model 
declare -A model_scores  # hash holding the model lnL scores and AICi values 
declare -A model_options # hash mapping option => model_set

# array of models to evaluate
nuclear_genome_models=(AB BLOSUM62 DAYHOFF DCMut JTT LG VT WAG)
organelle_genemome_models=(CpREV MTMAM MtREV MtArt)
nuclear_and_organellar=( ${nuclear_genome_models[@]} ${organelle_genemome_models[@]} )
viral_genome_models=(HIVw HIVb RtREV)
nuclear_and_viral_models=( ${nuclear_genome_models[@]} ${viral_genome_models[@]} )
all_models=( ${nuclear_genome_models[@]} ${organelle_genemome_models[@]} ${viral_genome_models[@]})
test_models=(JTT LG)

# hash mapping option => model_set
model_options['1']='nuclear_genome_models'
model_options['2']='organelle_genemome_models'
model_options['3']='nuclear_and_organellar_models'
model_options['4']='viral_genome_models'
model_options['5']='nuclear_and_viral'
model_options['6']='all_models'
model_options['7']='test_models'

mpi_OK=0 # flag set in check_dependencies, if mpirun and phyml-mpi are available

#==============================#
# >>> FUNCTION DEFINITIONS <<< #
#------------------------------#

function check_dependencies()
{
    declare -a progs required_binaries optional_binaries
    local p programname
    
    required_binaries=(awk bc sed perl phyml)
    optional_binaries=(mpirun phyml-mpi)
    
    for p in "${optional_binaries[@]}"
    do
          if type -P "$p" >/dev/null
	  then
	      progs=("${optional_binaries[@]}")
	      mpi_OK=1
	  else
	      mpi_OK=0
	      progs=()
	  fi
    done
    
    progs+=("${required_binaries[@]}")
    
    
    for programname in "${progs[@]}"
    do
       if ! type -P "$programname"; then  # NOTE: will print paths of binaries to STDOUT (no >/dev/null)
          echo
          echo "$# ERROR: $programname not in place!"
          echo "  ... you will need to install \"$programname\" first, or include it in \$PATH"
          echo "  ... exiting"
          exit 1
       else
          continue
       fi
    done
    
    echo
    echo '# Run check_dependencies() ... looks good: all required binaries are in place.'
    echo ''
}
#-----------------------------------------------------------------------------------------

function print_version()
{
   echo "$progname v$version"
   exit 0
}
#-----------------------------------------------------------------------------------------

function check_bash_version()
{
   local bash_vers min_bash_vers
   min_bash_vers=$1
   bash_vers=$(bash --version | head -1 | awk '{print $4}' | sed 's/(.*//' | cut -d. -f1,2)
   awk -v bv="$bash_vers" -v mb="$min_bash_vers" \
     'BEGIN { if (bv < mb){print "FATAL: you are running acient bash v"bv, "and version >=", mb, "is required"; exit 1}else{print "# Bash version", bv, "OK"} }'
}
#-----------------------------------------------------------------------------------------

function check_phyml_version {
   local phyml_version min_phyml_version phyml_version_year
   
   min_phyml_version=$1
   phyml_version_year=''
   phyml_version=''
   
   # This version extracts 3.3 from '3.3.20220408.'; but the series goes back to 2017 ...
   #   v3.3.20220408 is required to have the --leave_duplicates option
   phyml_version=$(phyml --version | awk '/This is PhyML version/{print substr($NF, 0, 4)}' | sed 's/\.$//') 
   #phyml_OK=$(awk -v v="$phyml_version" -v m="$min_phyml_version" 'BEGIN{if(v < m || v > 2000) { print 0}else{print 1}  }')
   
   if [[ 1 -eq "$(echo "$phyml_version == $min_phyml_version" | bc)" ]]
   then
        phyml_version_year=$(phyml --version | awk '/This is PhyML version/{print substr($NF, 0, 8)}' | sed 's/.*\.//g')
   else
        phyml_version_year="$phyml_version"
   fi
      
   printf '%s\n' "${phyml_version}_${phyml_version_year}"
}
#-----------------------------------------------------------------------------------------

function check_is_phylip(){
    local phylip_file="$1"

    if [[ ! -f "$phylip_file" ]]; then
        echo "Error: File not found: $phylip_file"
        return 1
    fi

    awk '
    BEGIN {
        valid = 1
    }
    NR == 1 {
        # First line: check for two integers separated by whitespace
        if (!($1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && NF == 2)) {
            print "Error: First line must contain two integers separated by whitespace."
            valid = 0
            exit 1
        }
        num_sequences = $1
        sequence_length = $2
    }
    NR > 1 && /^[^[:space:]]+/{ 
        # Other lines: verify alignment and proper separation
	id = substr($0, 1, 10)  # PHYLIP identifiers are typically up to 10 chars
	idcounts++
        seq = $2
        #gsub(/^ +| +$/, "", seq)  # Trim spaces around the sequence part
        if (!match(seq, /^[-A-Za-z.]+$/)) {
            print "Error: Invalid sequence format on line " NR "."
            valid = 0
            exit 1
        }
        # Check alignment (ensure space between ID and sequence)
        #if (substr($0, 10, 1) != " ") {
	if (! /^[^[:space:]]+[[:space:]+]/){
            print "Error: No space separating ID and sequence on line " NR "."
            valid = 0
            exit 1
        }
    }
    NR > 1 && /^[[:space:]+][-A-Za-z.]+/{
        seq = $0
        gsub(/^ +| +$| /, "", seq)  # Trim spaces around the sequence part
        if (!match(seq, /^[-A-Za-z.]+$/)) {
            print "Error: Invalid sequence format on line " NR "."
            valid = 0
            exit 1
        }
    }
    END {
        if (idcounts != num_sequences) {
            print "Error: Number of sequences " idcounts " does not match specified count (" num_sequences ")."
            valid = 0
        }
        exit valid ? 0 : 1
    }
    ' "$phylip_file"
}

#-----------------------------------------------------------------------------------------

function compute_AA_freq_in_phylip()
{
  local phylip
  phylip=$1
 
  awk '
  BEGIN{print "idx\tAA\tobs_freq"}
  {
    # ignore first row and column
    if( NR > 1 && NF > 1){
       # remove empty spaces
       gsub(/[ ]+/," ")
       l=length($0)

       for(i=1; i<=l; i++){
          c = substr($0, i, 1)
         
	  # count only standard amino acids
	  if (c ~ /[ARNDCQEGHILKMFPSTWYV]/){
              ccounts[c]++
              letters++
          }
       }
    }
  }
  # print relative frequency of each residue
  END {
     for (c in ccounts){ 
        aa++ 
        printf "%i\t%s\t%.4f\n", aa, c, (ccounts[c] / letters )
     }	
  }' "$phylip"
}
#-----------------------------------------------------------------------------------------

function print_start_time()
{
   #echo -n "[$(date +%T)] "
   printf '%(%T )T' '-1' # requires Bash >= 4.3
}
#-----------------------------------------------------------------------------------------

function compute_AICi()
{
   local score n_branches extra_params total_params
   
   score=$1
   n_branches=$2
   extra_params=$3
   
   total_params=$((n_branches + extra_params))
 
   # AICi=-2*lnLi + 2*Ni
   echo "(-2 * $score) + (2 * $total_params)" | bc -l
}
#-----------------------------------------------------------------------------------------

function compute_AICc()
{
   local AIC score n_branches extra_params total_params
   
   score=$1
   n_branches=$2
   extra_params=$3
   n_sites=$4
   AIC=$5
   
   total_params=$((n_branches + extra_params))
 
   # AICi=-2*lnLi + 2*Ni
   #AIC=$( echo "(-2 * $score) + (2 * $total_params)" | bc -l )   
   #echo $AIC + (2 * $total_params($total_params + 1)/($n_sites - $total_params -1)) | bc
   
   echo "$AIC + ( 2 * ($total_params * ($total_params + 1))/($n_sites - $total_params -1) )" | bc -l
}
#-----------------------------------------------------------------------------------------

function compute_BIC()
{
   local score n_branches extra_params total_params n_sites
   
   score=$1
   n_branches=$2
   extra_params=$3
   n_sites=$4
 
   total_params=$((n_branches + extra_params))

   # BICi= k*ln(n) -2*lnLi
   awk -v lnL="$score" -v k="$total_params" -v n="$n_sites" 'BEGIN{ BIC= (-2 * lnL) + (k * log(n)); printf "%0.5f", BIC }'
}
#-----------------------------------------------------------------------------------------

function print_end_message()
{
   cat <<EOF
  ========================================================================================
  If you use $progname v.$version for your research,
  I would appreciate that you:
  
  1. Cite the code in your work as:   
  Pablo Vinuesa. $progname v.$version 
       https://github.com/vinuesa/TIB-filoinfo/blob/master/$progname
  
  2. Give it a like on the https://github.com/vinuesa/TIB-filoinfo/ repo
  
  Thanks!

EOF
}
#----------------------------------------------------------------------------------------- 

function print_help {
   # Prints the help message explaining how to use the script.
   cat <<EOF
 USAGE for $progname v$version:
 $progname -i <infile> -m <model set to evaluate> [-b <(-)int>] [ -h <print help>] [-r <number of random seed trees>] [-s <SEARCH METHOD>] [ -v <print version>]
 
 REQUIRED:
  -i <string> input alignment in PHYLIP format
  -m <int> model set to evaluate by BIC
       1 -> nuclear genes (AB BLOSUM62 DAYHOFF DCMut JTT LG VT WAG)
       2 -> organellar genes (CpREV MTMAM MtREV MtArt)
       3 -> nuclear and organellar (1 + 2)
       4 -> retroviral genes (HIVw HIVb RtREV)
       5 -> nuclear + retroviral genes (1 + 4)
       6 -> all (1+2+3+4+5)
       7 -> test (JTT LG)

 OPTIONAL
  -h <flag> print help (this message)
  -b <int>
      int > 0: int is the number of bootstrap replicates.
       0: neither approximate likelihood ratio test nor bootstrap values are computed.
      -1: approximate likelihood ratio test returning aLRT statistics.
      -2: approximate likelihood ratio test returning Chi2-based parametric branch supports.
      -4: SH-like branch supports alone.
      -5: (default) approximate Bayes branch supports.  
  -s <NNI|SPR|BEST> Search (branch-swapping) method; default:$search_method
  -r <integer> number of random start trees to use for sequential searches; default rand_starts:$n_starts
  -v <flag> print version
 
 EXAMPLES:
   $progname -i my_PHYLIP_alignment.phy -m 1 -b -4 -r 10
 
 NOTES: 
  1. Assumes protein input sequences are ALIGNED and in (relaxed) PHYLIP format 
	 
 AIM: $progname v${version} will evaluate the fit of the the seleced model set,
       combined or not with +G and/or +f, computing AICi, BICi, deltaBIC, BICw 
	and inferring the ML tree under the BIC-selected model and the 
	use-selected search method (N|S|B) and number os start trees.

 PROCEDURE
   - Models are fitted using a fixed NJ-LG tree, optimizing branch lenghts and rates 
	to calculate their AICi, BICi, delta_BIC and BICw
   - The best model is selected by BIC
   - SPR searches can be launched starting from multiple random trees
   - Default single seed tree searches use a BioNJ with BEST moves     
   
   
 SOURCE: the latest version can be fetched from https://github.com/vinuesa/TIB-filoinfo
         
 LICENSE: GPL v3.0. 
    See https://github.com/vinuesa/get_phylomarkers/blob/master/LICENSE
    
EOF
   
   exit 1  
}
#----------------------------------------------------------------------------------------- 


#-----------------------------------------------------------------------------------------
#============================= END FUNCTION DEFINITIONS ==================================
#=========================================================================================


#------------------------------------#
#----------- GET OPTIONS ------------#
#------------------------------------#
# This section uses getopts to process command-line arguments 
#    and set the corresponding variables accordingly. 

[ $# -eq 0 ] && print_help

args=("$@")

while getopts ':b:i:r:m:s:hv?:' OPTIONS
do
   case $OPTIONS in

   b)   boot=$OPTARG
        ;;
   i)   infile=$OPTARG
        ;;
   m)   model_set=$OPTARG
        ;;
   r)   n_starts=$OPTARG
        ;;
   s)   search_method=$OPTARG
        ;;	
   h)   print_help
        ;;
   v)   print_version
        ;;
   :)   printf "argument missing from -%s option\n" "$OPTARG"
   	 print_help
     	 ;;
   ?)   echo "need the following args: "
   	 print_help
	 ;;
   *)   echo "An  unexpected parsing error occurred"
         echo
         print_help
	 ;;	 
   esac >&2   # print the ERROR MESSAGES to STDERR
done

shift $((OPTIND - 1))

# Check required params were provided
if [[ -z "$infile" ]]; then
       echo "Missing required input PHYLIP file name: -i <input>"
       print_help
fi

if [[ -z "$model_set" ]]; then
       echo "Missing required model_set option: -m <1|2|3|4|5|6|7>" warn
       print_help
fi

# Validate user-provided data and params
[[ ! -s "$infile" ]] && echo "FATAL ERROR: could not find $infile in $wkd" && exit 1

# Check input file is a relaxed or canonical PHYLIP file
if ! check_is_phylip "$infile" &> /dev/null; then 
   echo "FATAL ERROR: input file ${infile} does not seem to be a canonical phylip file. Will exit now!"
   exit 1
fi 

if (( model_set < 1 )) || (( model_set > 7 )); then
   print_help
fi

if (( boot < -5 )); then
   echo "# you are setting branch support value mode to $boot; values < -5 are not allowed!"
   print_help
fi

if (( boot > 10000 )); then
   echo "# you are setting bootstrapping to $boot; that will take a very long time to compute. Use a number of pseudoreplicates <= 10000"
   print_help
fi


# Check that the provided search_method matches the allowed set
regex='NNI|SPR|BEST'

if ! [[ "$search_method" =~ $regex ]]; then
   echo "ERROR: the provided search_method '-S $search_method' does not match the allowed set $regex"
   exit 1
fi

# ============ #
# >>> MAIN <<<
# ------------ #
# Main script logic starts here

## Check environment
# 0. Check that the input file was provided, and that the host runs bash >= v4.3
echo "# invocation: $progname " "${args[@]}"

wkd=$(pwd)


## Check Bash & PhyMLs vesions
# check PhyML version
echo "# checking PhyML version"
phymlv=$(check_phyml_version "$min_phyml_version")
phymlyr=$(echo "$phymlv" | cut -d_ -f2)


# OK, ready to start the analysis ...
start_time=$SECONDS
echo "========================================================================================="
check_bash_version "$min_bash_vers"
echo -n "# $progname v$version running on $host. Run started on: "; printf '%(%F at %T)T\n' '-1'

echo "# running with phyml v.${phymlv}"
((phymlyr < 2022)) && printf '%s\n%s\n' "# WARNING: THE SCRIPT MAY NOT WORK AS EXPECTED. You are running old PhyML version from $phymlyr!" "   Update to the latest one, using the phyml's GitHub repo: https://github.com/stephaneguindon/phyml/releases;" 

echo "# cheching basic dependencies ..."
check_dependencies

echo "# Run parameters:"
echo "# infile:$infile; model_set:$model_set; search_method:$search_method; seed trees:$n_starts; branch_support_type:$boot; mpi_OK:$mpi_OK"
echo "========================================================================================="
echo ''

# 1. get sequence stats
print_start_time
echo " # 1. Computing sequence stats for ${infile}:"

no_seq=$(awk 'NR == 1{print $1}' "$infile") 
echo "- number of sequences: $no_seq"

no_sites=$(awk 'NR == 1{print $2}' "$infile") 
echo "- number of sites: $no_sites"

no_branches=$((2 * no_seq - 3))
echo "- number of branches: $no_branches"

echo "- observed amino acid frequencies:"
compute_AA_freq_in_phylip "$infile"
# double check inout file is in PHYLIP format
(($? > 0)) && { echo "FATAL ERROR: input file ${infile} does not seem to be a canonical phylip file. Will exit now!"; exit 1 ; }

echo '--------------------------------------------------------------------------------'
echo '' 

# 2. set the selected model set, making a copy of the set array into the models array
case "$model_set" in
   1) models=( "${nuclear_genome_models[@]}" ) ;;
   2) models=( "${organelle_genemome_models[@]}" ) ;;
   3) models=( "${nuclear_and_organellar[@]}" );;
   4) models=( "${viral_genome_models[@]}" );;
   5) models=( "${nuclear_and_viral_models[@]}" );;
   6) models=( "${all_models[@]}" );;
   7) models=( "${test_models[@]}" );;
   *) echo "unknown model set!" && print_help ;;
esac
   

# 3. Compute a fast NJ tree estimating distances with the LG matrix 
print_start_time 
echo "1. Computing NJ-LG tree for input file $infile with $no_seq sequences"
echo '--------------------------------------------------------------------------------'
phyml -i "$infile" -d aa -m LG -c 1 -b 0 -o n &> /dev/null

# 2. rename the outfile for future use as usertree
if [[ -s "${infile}"_phyml_tree.txt ]]; then
   mv "${infile}"_phyml_tree.txt "${infile}"_LG-NJ.nwk
else
    echo "FATAL ERROR: could not compute ${infile}_phyml_tree.txt" && exit 1
fi

# 4. run a for loop to combine all base models with (or not) +G and or +f
#     and fill the model_scores and model_cmds hashes
echo "2. running in a for loop to combine all base models in model_set ${model_set}=>${model_options[$model_set]}, 
     with (or not) +G and or +f, and compute the model lnL, after optimizing branch lengths and rates"
echo '--------------------------------------------------------------------------------'
for mat in "${models[@]}"; do
     print_start_time && echo "# running: phyml -i $infile -d aa -m $mat -u ${infile}_LG-NJ.nwk -c 1 -v 0 -o lr"
     phyml -i "$infile" -d aa -m "$mat" -u "${infile}"_LG-NJ.nwk -c 1 -o lr &> /dev/null 
     extra_params=0 
     total_params=$((no_branches + extra_params))
     sites_by_K=$(echo 'scale=2;'"$no_sites/$total_params" | bc -l)
     score=$(awk '/Log-/{print $NF}' "${infile}"_phyml_stats.txt)
     AICi=$(compute_AICi "$score" "$no_branches" "$extra_params")
     AICc=$(compute_AICc "$score" "$no_branches" "$extra_params" "$no_sites" "$AICi")
     BICi=$(compute_BIC "$score" "$no_branches" "$extra_params" "$no_sites")
     printf -v model_string "%d\t%.5f\t%.5f\t%.5f\t%.5f\t%.5f" "$total_params" "$sites_by_K" "$score" "$AICi" "$AICc" "$BICi"
     model_scores["${mat}"]="$model_string"
     model_cmds["${mat}"]="$mat"

     print_start_time && echo "# running: phyml -i $infile -d aa -m $mat -f m -c 4 -a e -u ${infile}_LG-NJ.nwk -o lr"
     phyml -i "$infile" -d aa -m "${mat}" -f m -c 4 -a e -u "${infile}"_LG-NJ.nwk -o lr &> /dev/null
     extra_params=1 
     total_params=$((no_branches + extra_params))
     sites_by_K=$(echo 'scale=2;'"$no_sites/$total_params" | bc -l)
     score=$(awk '/Log-/{print $NF}' "${infile}"_phyml_stats.txt)
     AICi=$(compute_AICi "$score" "$no_branches" "$extra_params")
     AICc=$(compute_AICc "$score" "$no_branches" "$extra_params" "$no_sites" "$AICi")
     BICi=$(compute_BIC "$score" "$no_branches" "$extra_params" "$no_sites")
     printf -v model_string "%d\t%.5f\t%.5f\t%.5f\t%.5f\t%.5f" "$total_params" "$sites_by_K" "$score" "$AICi" "$AICc" "$BICi"
     model_scores["${mat}+G"]="$model_string"
     model_cmds["${mat}+G"]="$mat -f m -c 4 -a e"

     print_start_time && echo "# running: phyml -i $infile -d aa -m $mat -f e -c 1 -u ${infile}_LG-NJ.nwk -o lr"
     phyml -i "$infile" -d aa -m "$mat" -f e -c 1 -u "${infile}"_LG-NJ.nwk -o lr &> /dev/null
     extra_params=19 #19 from AA frequencies
     total_params=$((no_branches + extra_params))
     sites_by_K=$(echo 'scale=2;'"$no_sites/$total_params" | bc -l)
     score=$(awk '/Log-/{print $NF}' "${infile}"_phyml_stats.txt)
     AICi=$(compute_AICi "$score" "$no_branches" "$extra_params")
     AICc=$(compute_AICc "$score" "$no_branches" "$extra_params" "$no_sites" "$AICi")
     BICi=$(compute_BIC "$score" "$no_branches" "$extra_params" "$no_sites")
     printf -v model_string "%d\t%.5f\t%.5f\t%.5f\t%.5f\t%.5f" "$total_params" "$sites_by_K" "$score" "$AICi" "$AICc" "$BICi"
     model_scores["${mat}+f"]="$model_string"
     model_cmds["${mat}+f"]="$mat -f e"

     print_start_time && echo "# running: phyml -i $infile -d aa -m $mat -u ${infile}_LG-NJ.nwk -f e -a e -o lr"
     phyml -i "$infile" -d aa -m "$mat" -u "${infile}"_LG-NJ.nwk -f e -a e -c 4 -o lr &> /dev/null
     extra_params=20 #19 from AA frequencies + 1 gamma 
     total_params=$((no_branches + extra_params))
     sites_by_K=$(echo 'scale=2;'"$no_sites/$total_params" | bc -l)
     score=$(awk '/Log-/{print $NF}' "${infile}"_phyml_stats.txt)
     AICi=$(compute_AICi "$score" "$no_branches" "$extra_params")
     AICc=$(compute_AICc "$score" "$no_branches" "$extra_params" "$no_sites" "$AICi")
     BICi=$(compute_BIC "$score" "$no_branches" "$extra_params" "$no_sites")
     printf -v model_string "%d\t%.5f\t%.5f\t%.5f\t%.5f\t%.5f" "$total_params" "$sites_by_K" "$score" "$AICi" "$AICc" "$BICi"
     model_scores["${mat}+f+G"]="$model_string"
     model_cmds["${mat}+f+G"]="$mat -f e -c 4 -a e"
done

echo ''

# 5. print a sorted summary table of model fits from the model_scores hash
print_start_time

echo "# writing ${infile}_sorted_model_set_${model_set}_fits.tsv, sorted by BIC"
echo '--------------------------------------------------------------------------------------------------'
for m in "${!model_scores[@]}"; do
    echo -e "$m\t${model_scores[$m]}"
done | sort -nk7 > "${infile}"_sorted_model_set_"${model_set}"_fits.tsv


# 6 compute delta_BIC and BICw, based on "${infile}"_sorted_model_set_"${model_set}"_fits.tsv
declare -a BIC_a
declare -a BIC_deltas_a
declare -a BICw_a
declare -a BICcumW_a

BIC_a=( $(awk '{print $7}' "${infile}"_sorted_model_set_"${model_set}"_fits.tsv) )
min_BIC="${BIC_a[0]}"

# 6.1 fill BIC_deltas_a array
BIC_deltas_a=()
for i in "${BIC_a[@]}"
do
     BIC_deltas_a+=( $( echo "$i" - "$min_BIC" | bc -l) )
done

# 6.2 Compute the BICw_sums (denominator) of BICw

# e (Euler's number; constant | e = 2.718281828459) base of the natural logarithm and exponential function
#  use e^(-1/2 * delta) instead of exp(-1/2 * delta) to avoid exponential out of range messages like:
#  awk: cmd. line:1: warning: exp: argument -1233.51 is out of range # on chaac
# https://stackoverflow.com/questions/69285812/awk-error-argument-is-out-of-the-range-how-to-solve-this-problem
# https://www.rapidtables.com/math/number/e_constant.html
e=2.718281828459
BICw_sums=0

for i in "${BIC_deltas_a[@]}"; do 
   # BICw_numerator=$(awk -v delta="$i"  'BEGIN{printf "%.10f", exp(-1/2 * delta) }' 2> /dev/null) 
   BICw_numerator=$(awk -v delta="$i" -v e="$e" 'BEGIN{printf "%.10f", e^(-1/2 * delta) }' 2> /dev/null) 
    
   #echo "num:$BICw_numerator"
   BICw_sums=$(bc <<< "$BICw_sums"'+'"$BICw_numerator")
done
#echo BICw_sums:$BICw_sums

# 6.3 fill the BICw_a and BICcumW_a arrays
BICw_a=()
BICcumW_a=()
BICcumW=0
for i in "${BIC_deltas_a[@]}"; do
   #BICw_numerator=$(awk -v delta="$i" 'BEGIN{printf "%.10f", exp(-1/2 * delta) }' 2> /dev/null)   
   BICw_numerator=$(awk -v delta="$i" -v e="$e" 'BEGIN{printf "%.10f", e^(-1/2 * delta) }' 2> /dev/null) 
   BICw=$(echo "$BICw_numerator / $BICw_sums" | bc -l)
   BICw_a+=( $(printf "%.2f" "$BICw") )
   BICcumW=$(echo "$BICcumW + $BICw" | bc)
   BICcumW_a+=( $(printf "%.2f" "$BICcumW") )
done

# 6.4 paste the BIC_deltas_a & BICw_a values as a new column to "${infile}"_sorted_model_set_"${model_set}"_fits.tsv
paste "${infile}"_sorted_model_set_"${model_set}"_fits.tsv <(for i in "${BIC_deltas_a[@]}"; do echo "$i"; done) \
                                                           <(for i in "${BICw_a[@]}"; do echo "$i"; done) \
							   <(for i in "${BICcumW_a[@]}"; do echo "$i"; done) > t
							   
[[ -s t ]] && mv t "${infile}"_sorted_model_set_"${model_set}"_fits.tsv

# 6.5 Display  the final "${infile}"_sorted_model_set_"${model_set}"_fits.tsv and extract the best model name
if [[ -s "${infile}"_sorted_model_set_"${model_set}"_fits.tsv ]]; then
    # display models sorted by BIC
    best_model=$(awk 'NR == 1{print $1}' "${infile}"_sorted_model_set_"${model_set}"_fits.tsv)
    [[ -z "$best_model" ]] && echo "FATAL ERROR: unbound \$best_model at $LINENO" && exit 1

    # print table with header to STDOUT and save to file
    awk 'BEGIN{print "model\tK\tsites/K\tlnL\tAIC\tAICc\tBIC\tdeltaBIC\tBICw\tBICcumW"}{print}' "${infile}"_sorted_model_set_"${model_set}"_fits.tsv | column -t
    awk 'BEGIN{print "model\tK\tsites/K\tlnL\tAIC\tAICc\tBIC\tdeltaBIC\tBICw\tBICcumW"}{print}' "${infile}"_sorted_model_set_"${model_set}"_fits.tsv > t
    mv t "${infile}"_sorted_model_set_"${model_set}"_fits.tsv
else
    echo "ERROR: could not write ${infile}_sorted_model_set_${model_set}_fits.tsv"
fi

# cleanup: remove phyml output files from the last pass through the loop
[[ -s "${infile}"_phyml_stats.txt ]] && rm "${infile}"_phyml_stats.txt
[[ -s "${infile}"_phyml_tree.txt ]] && rm "${infile}"_phyml_tree.txt
echo '--------------------------------------------------------------------------------------------------'
echo "* NOTE 1: when sites/K < 40, the AICc is recommended over AIC."
echo "* NOTE 2: The best model is selected by BIC, because AIC is biased, favoring parameter-rich models."
echo ''


# 7. compute ML tree under best-fitting model
echo '=================================================================================================='

echo "... will estimate the ML tree under best-fitting model $best_model selected by BIC"

print_start_time

if ((n_starts == 1)); then
    echo "# running: phyml -i $infile -d aa -m ${model_cmds[$best_model]} -o tlr -s $search_method -b $boot"

    # note that on tepeu, the quotes around "${model_cmds[$best_model]}" make the comand fail
    phyml -i "$infile" -d aa -m ${model_cmds[$best_model]} -o tlr -s "$search_method"  -b "$boot" &> /dev/null
else
    echo "# running: phyml -i $infile -d aa -m ${model_cmds[$best_model]} -o tlr -s $search_method --rand_start --n_rand_starts $n_starts  -b $boot"
    
    # note that on tepeu (Bash 4.4), the quotes around "${model_cmds[$best_model]}" make the command fail
    phyml -i "$infile" -d aa -m ${model_cmds[$best_model]} -o tlr -s "$search_method" --rand_start --n_rand_starts "$n_starts"  -b "$boot" &> /dev/null

fi

# 7.1 Check and rename final phyml output files
if [[ -s "${infile}"_phyml_stats.txt ]]; then
     
     if ((n_starts == 1)); then
         mv "${infile}"_phyml_stats.txt "${infile}"_"${best_model}"_"${search_method}"moves_phyml_stats.txt
         echo "# Your results:"
         echo "  - ${infile}_${best_model}_${search_method}moves_phyml_stats.txt"
     else
         mv "${infile}"_phyml_stats.txt "${infile}"_"${best_model}"_"${n_starts}"rdmStarts_"${search_method}"moves_phyml_stats.txt
         echo "# Your results:"
         echo "  - ${infile}_${best_model}_${n_starts}rdmStarts_${search_method}moves_phyml_stats.txt"
     fi
else
     echo "FATAL ERROR: ${infile}_phyml_stats.txt was not generated!"
fi

if [[ -s "${infile}"_phyml_tree.txt ]]; then
     if ((n_starts == 1)); then
         mv "${infile}"_phyml_tree.txt "${infile}"_"${best_model}"_"${search_method}"moves_phyml_tree.txt
         echo "  - ${infile}_${best_model}_${search_method}moves_phyml_tree.txt"
     else
         mv "${infile}"_phyml_tree.txt "${infile}"_"${best_model}"_"${n_starts}"rdmStarts_"${search_method}"moves_phyml_tree.txt
         echo "  - ${infile}_${best_model}_${n_starts}rdmStarts_${search_method}moves_phyml_tree.txt"
     fi
else
     echo "FATAL ERROR: ${infile}_phyml_tree.txt was not generated!"
fi

if ((n_starts > 1)) && [[ -s "${infile}"_phyml_rand_trees.txt ]]; then
    mv "${infile}"_phyml_rand_trees.txt "${infile}"_phyml_"${n_starts}"rand_trees.txt
    echo "  - ${infile}_phyml_${n_starts}rand_trees.txt"
fi 

echo '--------------------------------------------------------------------------------------------------'

echo ''

elapsed=$(( SECONDS - start_time ))

eval "echo Elapsed time: $(date -ud "@$elapsed" +'$((%s/3600/24)) days, %H hr, %M min, %S sec')"

echo 'Done!'

print_end_message

exit 0
