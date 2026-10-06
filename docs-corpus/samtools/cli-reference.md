
Program: samtools (Tools for alignments in the SAM format)
Version: 1.23.1 (using htslib 1.23.1)

Usage:   samtools <command> [options]

Commands:
  -- Indexing
     dict           create a sequence dictionary file
     faidx          index/extract FASTA
     fqidx          index/extract FASTQ
     index          index alignment

  -- Editing
     calmd          recalculate MD/NM tags and '=' bases
     fixmate        fix mate information
     reheader       replace BAM header
     targetcut      cut fosmid regions (for fosmid pool only)
     addreplacerg   adds or replaces RG tags
     markdup        mark duplicates
     ampliconclip   clip oligos from the end of reads

  -- File operations
     collate        shuffle and group alignments by name
     cat            concatenate BAMs
     consensus      produce a consensus Pileup/FASTA/FASTQ
     merge          merge sorted alignments
     mpileup        multi-way pileup
     sort           sort alignment file
     split          splits a file by read group
     quickcheck     quickly check if SAM/BAM/CRAM file appears intact
     fastq          converts a BAM to a FASTQ
     fasta          converts a BAM to a FASTA
     import         Converts FASTA or FASTQ files to SAM/BAM/CRAM
     reference      Generates a reference from aligned data
     reset          Reverts aligner changes in reads

  -- Statistics
     bedcov         read depth per BED region
     coverage       alignment depth and percent coverage
     depth          compute the depth
     flagstat       simple stats
     idxstats       BAM index stats
     cram-size      list CRAM Content-ID and Data-Series sizes
     phase          phase heterozygotes
     stats          generate stats (former bamcheck)
     ampliconstats  generate amplicon specific stats
     checksum       produce order-agnostic checksums of sequence content

  -- Viewing
     flags          explain BAM flags
     head           header viewer
     tview          text alignment viewer
     view           SAM<->BAM<->CRAM conversion
     depad          convert padded BAM to unpadded BAM
     samples        list the samples in a set of SAM/BAM/CRAM files

  -- Misc
     help [cmd]     display this help message or help for [cmd]
     version        detailed version information


Usage: samtools view [options] <in.bam>|<in.sam>|<in.cram> [region ...]

Output options:
  -b, --bam                  Output BAM
  -C, --cram                 Output CRAM (requires -T)
  -1, --fast                 Use fast BAM compression (and default to --bam)
  -u, --uncompressed         Uncompressed BAM output (and default to --bam)
  -h, --with-header          Include header in SAM output
  -H, --header-only          Print SAM header only (no alignments)
      --no-header            Print SAM alignment records only [default]
  -c, --count                Print only the count of matching records
      --save-counts FILE     Write counts of passed/failed records to FILE
  -o, --output FILE          Write output to FILE [standard output]
  -U, --unoutput FILE, --output-unselected FILE
                             Output reads not selected by filters to FILE
  -p, --unmap                Set flag to UNMAP on reads not selected
                             then write to output file.
  -P, --fetch-pairs          Retrieve complete pairs even when outside of region

Input options:
  -t, --fai-reference FILE   FILE listing reference names and lengths
  -M, --use-index            Use index and multi-region iterator for regions
      --region[s]-file FILE  Use index to include only reads overlapping FILE
  -X, --customized-index     Expect extra index file argument after <in.bam>

Filtering options (Only include in output reads that...):
  -L, --target[s]-file FILE  ...overlap (BED) regions in FILE
  -N, --qname-file [^]FILE   ...whose read name is listed in FILE ("^" negates)
  -r, --read-group STR       ...are in read group STR or in no read group
  -R, --read-group-file [^]FILE
                             ...are in a read group listed in FILE or in none
  -n, --exclude-no-read_group
                             ...have a read group, exclude those that have not
  -d, --tag STR1[:STR2]      ...have a tag STR1 (with associated value STR2)
  -D, --tag-file STR:FILE    ...have a tag STR whose value is listed in FILE
  -q, --min-MQ INT           ...have mapping quality >= INT
  -l, --library STR          ...are in library STR
  -m, --min-qlen INT         ...cover >= INT query bases (as measured via CIGAR)
  -e, --expr STR             ...match the filter expression STR
  -f, --require-flags FLAG   ...have all of the FLAGs present
  -F, --excl[ude]-flags FLAG ...have none of the FLAGs present
      --rf, --incl-flags, --include-flags FLAG
                             ...have some of the FLAGs present
  -G FLAG                    EXCLUDE reads with all of the FLAGs present
      --subsample FLOAT      Keep only FLOAT fraction of templates/read pairs
      --subsample-seed INT   Influence WHICH reads are kept in subsampling [0]
  -s INT.FRAC                Same as --subsample 0.FRAC --subsample-seed INT

Processing options:
      --add-flags FLAG       Add FLAGs to reads
      --remove-flags FLAG    Remove FLAGs from reads
  -x, --remove-tag STR
               Comma-separated read tags to strip (repeatable) [null]
      --keep-tag STR
               Comma-separated read tags to preserve (repeatable) [null].
               Equivalent to "-x ^STR"
  -B, --remove-B             Collapse the backward CIGAR operation
  -z, --sanitize FLAGS       Perform sanitity checking and fixing on records.
                             FLAGS is comma separated (see manual). [off]

General options:
  -?, --help   Print long help, including note about region specification
  -S           Ignored (input format is auto-detected)
      --no-PG  Do not add a PG line
      --input-fmt-option OPT[=VAL]
               Specify a single input file format option in the form
               of OPTION or OPTION=VALUE
  -O, --output-fmt FORMAT[,OPT[=VAL]]...
               Specify output format (SAM, BAM, CRAM)
      --output-fmt-option OPT[=VAL]
               Specify a single output file format option in the form
               of OPTION or OPTION=VALUE
  -T, --reference FILE
               Reference sequence FASTA FILE [null]
  -@, --threads INT
               Number of additional threads to use [0]
      --write-index
               Automatically index the output files [off]
      --verbosity INT
