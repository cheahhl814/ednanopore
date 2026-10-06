usage: medaka [-h] [--version]
              {compress_bam,features,train,inference,smolecule,tandem,consensus_from_features,fastrle,sequence,vcf,tools}
              ...

options:
  -h, --help            show this help message and exit
  --version             show program's version number and exit

subcommands:
  valid commands

  {compress_bam,features,train,inference,smolecule,tandem,consensus_from_features,fastrle,sequence,vcf,tools}
                        additional help
    compress_bam        Compress an alignment into RLE form.
    features            Create features for inference.
    train               Train a model from features.
    inference           Run inference from a trained model and alignments.
    smolecule           Create consensus sequences from single-molecule reads.
    tandem              Call specified STR variants.
    consensus_from_features
                        Run inference from a trained model on existing
                        features.
    fastrle             Create run-length encoded fastq (lengths in quality
                        track).
    sequence            Stitch together output from medaka inference into a
                        final consensus sequence.
    vcf                 Stitch together output from medaka inference into a
                        final VCF file.
    tools               tools subcommand.
