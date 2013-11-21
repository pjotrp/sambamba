# Sambamba programmer manual 

Sambamba allows rapid access to SAM and BAM data, leveraging the cores on your
computer. That is enticing to use it as a tool for transforming or viewing
sequenced data. Sambamba offers more in the form of accessible source code that
allows programmers to add more functionality. This manual is meant to help
software developers work on the source code.

Sambamba is (mostly) written in the D progamming language. D is a modern
compiled, strictly typed, hybrid OOP-functional language, that means it
supports both the OOP paradigm and the FP paradigm. In addition D is
interesting because it fast. Hopefully Sambamba will also let you appreciate
the power of D.

# main.d

Sambamba calls into several modules for indexing, sorting etc. The CLI
starts from main.d and multiplexes into, for example, markup.d

# markup.d

The first task of the function markdup_main is to parse the command
line. Next a TaskPool is set up for multi-core processing. The main 
program sizes the Hash table and sets up the BAM reader, which
uses the thread taskpool. BamReader is defined in BioD/bio/bam/reader.d,
which is part of the BioD project repository (git pulls in that repo 
when you clone sambamba). SamReader and BamReader share a common 
interface for access, defined by IBamSamReader. BamReader handles
parallel decompression of BGZF blocks, see below for more.

# BioD/bio/bam/reader.d

Interesting methods are header() which returns the SAM header in
the BAM file; getBgzfBlockAt(), which get a BGZF block at a given file offset;
reference_sequences get information on reference sequences; 



