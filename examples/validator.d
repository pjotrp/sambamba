import bamfile;
import validation.alignment;
import sam.serialize;
import std.stdio;
import std.c.stdio : stdout;

void main(string[] args) {
    auto bam = BamFile(args[1]);

    foreach (read; bam.alignments) {
        auto msg = validate(bam.header, read);
        if (msg !is null) {
            serialize(read, bam.reference_sequences, stdout);
            writeln();
            writeln(msg);
        }
    }
}
