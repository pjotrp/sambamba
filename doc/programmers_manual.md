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

One thing to appreciate is that Sambamba is built around multiple worker 
threads, using (lazy) functions, when you, for example, read a file,
it is delivered to you in chunks, rather than reading all the data
in RAM. D helps to abstract away most of the plumbing. Some typical
approach may look like:

        import std.functional, std.stdio, bio.bam.reader;
        void progress(lazy float p) {
            static uint n;
            if (++n % 63 == 0) writeln(p); // prints progress after every 63 records
        }
        ...
        foreach (read; bam.readsWithProgress(toDelegate(&progress))) {
            ...
        }

where the foreach loop is executed in parallel and progress() is passed
in as a lazy function. The progress function is made lazy so the user
can control the amount of times progress is calculated, which may be
expensive.

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

In the next step all (bgzf) offsets for the reads are gathered and stored in a
list/array of VirtualOffset type using the function getDuplicateOffsets().

Note that this function uses malloc/free to allocate memory on the heap.  D
allows you to do that in addition to using the (standard) way of the garbage
collector. Another point of interest it the compression of data, such as with
SingleEndBasicInfo wich counts 8 bytes.

# BioD/bio/bam/reader.d

Interesting methods are header() which returns the SAM header in the BAM file;
getBgzfBlockAt(), which get a BGZF block at a given file offset;
reference_sequences() and reference() get information on reference sequences;
reads() and readsWithProgress() fetch reads; getReadAt(); getReadsBetween();
unmappedReads(); all read related.

In a way the BamReader class is one of the more complex ones as it supports
multi-threading, multiple policies and ways of accessing data (seekable with
index, sequential, compressed, uncompressed etc.).

