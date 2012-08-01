module validation.alignment;

import alignment;
import samheader;
import tagvalue;

import std.math;
import std.conv;
import std.ascii;
import utils.algo;

abstract class AbstractValidationError(T)
    if (is(T == Alignment) || is(T == Value))
{
    static string description; /// Description of the validation error.
    static int severity; /// Error severity (default is 0).
    static int priority; /// Error priority (default is 0).

    static if (is(T == Alignment)) {
        // NOTE: I don't have any f*cking idea why the bloody compiler forces 
        //       these functions to be @safe, so I just mark them as @trusted
        //       to shut it up.
        abstract string validate(const SamHeader header, Alignment read) @trusted;
    } else {
        abstract string validate(const SamHeader header, Alignment read, Value value) @trusted;
    }
}

alias AbstractValidationError!Alignment ReadValidationError;
alias AbstractValidationError!Value     TagValidationError;

public {
    /// Validators for flags
    __gshared ReadValidationError[string] invalidFlag;

    /// Validators for record fields
    __gshared ReadValidationError[string] invalidField;

    /// Validators for individual predefined tags
    __gshared TagValidationError[string] invalidTag;

    /// Validators for CIGAR
    __gshared ReadValidationError cigarInternalHardClipping,
                                  cigarInternalSoftClipping,
                                  cigarInconsistentLength,
                                  cigarEmptyForMappedRead;

    /// Array of validators for CIGAR
    __gshared ReadValidationError[] cigarValidationErrors; // populated in CigarValidationError constructor

    /// Validators for tags (overall).
    __gshared ReadValidationError invalidTagsForEmptyRead,
                                  invalidTagsDuplicateTagNames;

    /// Array of validators for tags (overall)
    __gshared ReadValidationError[] invalidTagsValidationErrors;

    /// Array of all validators for reads
    __gshared ReadValidationError[] readValidationErrors;

    /// General validators for individual tags
    __gshared TagValidationError tagInvalidCharacterValue,
                                 tagInvalidStringValue,
                                 tagInvalidHexStringValue;

    /// Array of general validators for individual tags
    __gshared TagValidationError[] generalTagValidationErrors;

    /// General tag validators (see above) + predefined tag validators
    __gshared TagValidationError[] tagValidationErrors;
}

private {

    template AbstractValidationSettings(T, string idtype, string dictionaryname)
        if (is(T == Alignment) || is(T == Value))
    {
        template AbstractValidationSettings(string id) {
            enum description = idtype ~ "'" ~ id ~ "' is invalid";

            alias T Type;

            void save(AbstractValidationError!T e) @trusted {
                mixin(dictionaryname ~ `["` ~ id ~ `"] = e;`);
            }
        }
    }

    alias AbstractValidationSettings!(Alignment, "flag",  "invalidFlag")   FlagValidationSettings;
    alias AbstractValidationSettings!(Alignment, "field", "invalidField")  FieldValidationSettings;
    alias AbstractValidationSettings!(Value,     "tag",   "invalidTag")    TagValidationSettings;

    /// A special type for quality strings
    struct QualityString {
        string val;
        alias val this;
    }

    struct ValidationEngine(alias ValidationSettings) 
    {
        auto opDispatch(string id)() @property {

            alias ValidationSettings!id.Type T; 

            static struct Result(string id) {

                static if (is(T == Value)) {
                    static string expected_type;
                    static int expected_tag;

                    ref Result mustBe(ExpectedType)() @property @trusted {

                        static if (is(ExpectedType == QualityString)) {
                            expected_type = "quality string";
                            expected_tag = GetTypeId!string;
                        } else {
                            expected_type = ExpectedType.stringof;
                            expected_tag = GetTypeId!ExpectedType;
                        }

                        class TypeValidator : TagValidationError {
                            override string validate(const SamHeader _, Alignment read, Value v) @trusted {
                                static if (is(ExpectedType == int)) {
                                    if (!v.is_integer)
                                        return "expected integer value";
                                } else static if (is(ExpectedType == string)) {
                                    if (!v.is_string)
                                        return "expected string value";
                                } else static if (is(ExpectedType == QualityString)) {
                                    if (!v.is_string)
                                        return "expected string value";
                                    auto qual = cast(string)v;
                                    if (qual != "*" && !all!"a >= '!' && a <= '~'"(qual))
                                        return "quality string contains invalid characters";
                                } else {
                                    if (v.tag != expected_tag)
                                        return "expected value of type " ~ expected_type;
                                }
                                return null;
                            }
                        }

                        invalidTag[id] = new TypeValidator();

                        return this;
                    }
                }

                void isInvalidIf(string checker)() @property {

                    class Validator : AbstractValidationError!T {

                        static this() {
                            description = ValidationSettings!id.description;
                        }

                        static if (is(T == Alignment)) {
                            override string validate(const SamHeader header, T read) @trusted {
                                with (read) { mixin(checker); }
                                return null;
                            }
                        } else static if (is(T == Value)) {
                            override string validate(const SamHeader header, Alignment read, T value) @trusted {
                                if (expected_type !is null && value.tag != expected_tag) 
                                    return "expected " ~ expected_type;

                                with (value) { mixin(checker); }
                                return null;
                            }

                        } else static assert(false);
                    }

                    AbstractValidationError!T v = new Validator();
                    ValidationSettings!id.save(v);
                }
            }

            return Result!id();
        }
    }

    alias ValidationEngine!FlagValidationSettings  FlagValidationEngine;
    alias ValidationEngine!FieldValidationSettings FieldValidationEngine;
    alias ValidationEngine!TagValidationSettings   TagValidationEngine;

    FlagValidationEngine  flag;
    FieldValidationEngine field;
    TagValidationEngine   tag;
}

static this() {

    alias bool function(const SamHeader, Alignment) ValidateFunc;

    // -------------------------------- CIGAR ----------------------------------

    class CigarValidationError : ReadValidationError {
        this(string description, ValidateFunc is_invalid) {
            this.description = "field 'cigar' is invalid: " ~ description;
            _is_invalid = is_invalid;

            cigarValidationErrors ~= this;
        }

        private ValidateFunc _is_invalid;

        override string validate(const SamHeader header, Alignment read) @trusted {
            return _is_invalid(header, read) ? description : null;
        }
    }

    cigarInternalHardClipping = new CigarValidationError(
            "internal hard clipping",
            function (const SamHeader header, Alignment read) {
                return (read.cigar.length > 2 && 
                        any!"a.operation == 'H'"(read.cigar[1..$-1]));
            });

    cigarInternalSoftClipping = new CigarValidationError(
            "internal soft clipping",
            function (const SamHeader header, Alignment read) {
                return (read.cigar.length > 2 && 
                        any!"a.operation == 'H'"(read.cigar[1..$-1]));
            });

    cigarInconsistentLength = new CigarValidationError(
            "sum of lengths of M/I/=/S/X operations is not equal to sequence length",
            function (const SamHeader header, Alignment read) {
                return (read.sequence_length > 0 &&
                        read.sequence_length != reduce!`a + b`(0, 
                                                  map!`a.length`(
                                                    filter!`canFind("MIS=X", a.operation)`(
                                                      read.cigar))));
            });

    cigarEmptyForMappedRead = new CigarValidationError(
            "CIGAR must not be empty for mapped read",
            function (const SamHeader header, Alignment read) {
                return !read.is_unmapped && read.cigar.length == 0;
            });

    // ---------------------------------- tags (overall) -----------------------

    class TagsValidationError : ReadValidationError {
        this(string description, ValidateFunc is_invalid) {
            this.description = "invalid tag data: " ~ description;
            _is_invalid = is_invalid;

            invalidTagsValidationErrors ~= this;
        }

        private ValidateFunc _is_invalid;

        override string validate(const SamHeader header, Alignment read) @trusted {
            return _is_invalid(header, read) ? description : null;
        }
    }

    invalidTagsForEmptyRead = new TagsValidationError(
            "empty read must have one of [FZ], [CS], [CQ] flags set",
            function (const SamHeader header, Alignment read) {
                if (read.sequence_length != 0) 
                    return false;
                foreach (k, _; read) {
                    switch (k) {
                        case "FZ":
                        case "CS":
                        case "CQ":
                            return false;
                        default:
                            break;
                    }
                }
                return true;
            });

    invalidTagsDuplicateTagNames = new TagsValidationError(
            "duplicate tag names",
            function (const SamHeader header, Alignment read) {
                bool all_distinct = true;

                // Optimize for small number of tags
                ushort[256] keys = void;
                size_t i = 0;

                // Check each tag in turn.
                foreach (k, v; read) {
                    if (i < keys.length) {
                        keys[i] = *cast(ushort*)(k.ptr);

                        if (all_distinct) {
                            for (size_t j = 0; j < i; ++j) {
                                if (keys[i] == keys[j]) {
                                    all_distinct = false;
                                    break;
                                }
                            }
                        }

                        i += 1;
                    } else {
                        if (all_distinct) {
                            // must be exactly one
                            int found = 0;
                            foreach (k2, v2; read) {
                                if (*cast(ushort*)(k2.ptr) == *cast(ushort*)(k.ptr)) {
                                    if (found == 1) {
                                        all_distinct = false;
                                        break;
                                    } else {
                                        ++found;
                                    }
                                }
                            }
                        }
                    }
                }

                return !all_distinct;
            });

    // -------------------------------- flags ----------------------------------

    flag.proper_pair.isInvalidIf!q{
        if (!is_paired && proper_pair)
            return "read is unpaired but flag 'proper_pair' is set";
    };

    flag.mate_is_unmapped.isInvalidIf!q{
        if (!is_paired && mate_is_unmapped) 
            return "read is unpaired but flag 'mate_is_unmapped' is set";
        if (is_paired && !mate_is_unmapped && next_ref_id == -1)
            return "mate reference ID is -1 but flag 'mate_is_unmapped' is unset";
    };

    flag.mate_is_reverse_strand.isInvalidIf!q{
        if (!is_paired && mate_is_reverse_strand)
            return "read is unpaired but flag 'mate_is_reverse_strand' is set";
    };

    flag.is_first_of_pair.isInvalidIf!q{
        if (!is_paired && is_first_of_pair)
            return "read is unpaired but flag 'is_first_of_pair' is set";
    };

    flag.is_second_of_pair.isInvalidIf!q{
        if (!is_paired && is_second_of_pair)
            return "read is unpaired but flag 'is_second_of_pair' is set";
    };

    flag.is_secondary_alignment.isInvalidIf!q{
        if (is_unmapped && is_secondary_alignment)
            return "read is unmapped but flag 'is_secondary_alignment' is set";
    };

    // -------------------------------- fields ---------------------------------

    field.read_name.isInvalidIf!q{
        if (read_name.length == 0)
            return "read name must be nonempty";
        if (read_name.length > 255)
            return "read name length must be <= 255";
        
        foreach (char c; read_name) 
        {
            if ((c < '!') || (c > '~') || (c == '@')) {
                return "read name contains invalid characters";
            }
        }
    };

    field.position.isInvalidIf!q{
        if (position < -1 || position > ((1<<29) - 2))
            return "position must lie in range -1 .. 2^29 - 2";
    };

    field.phred_base_quality.isInvalidIf!q{
        if (!all!"a == 0xFF"(phred_base_quality) &&
            !all!"0 <= a && a <= 93"(phred_base_quality))
            return "quality data contains invalid elements";
    };

    field.cigar.isInvalidIf!q{
        foreach (e; cigarValidationErrors) {
            auto res = e.validate(header, read);
            if (res !is null) 
                return res;
        }
    };

    field.mapping_quality.isInvalidIf!q{
        if (is_unmapped && mapping_quality != 0)
            return "mapping quality must be 0 for unmapped read";
    };

    field.template_length.isInvalidIf!q{
        if (abs(template_length) > (1 << 29))
            return "template length must be in range -2^29 .. 2^29";
    };

    field.ref_id.isInvalidIf!q{
        if (ref_id != -1 && ref_id >= header.sequences.length)
            return "header contains " ~ to!string(header.sequences.length) ~ 
                   " sequences but read reference ID is " ~ to!string(ref_id);
    };

    field.next_ref_id.isInvalidIf!q{
        if (!is_paired && next_ref_id != -1)
            return "read is unpaired but mate reference ID != -1";
    };

    readValidationErrors = invalidFlag.values ~ invalidField.values ~ 
                           cigarValidationErrors ~ invalidTagsValidationErrors;

    // --------------------------------- tags ----------------------------------
    
    tag.AM.mustBe!int;
    tag.AS.mustBe!int;
    tag.BC.mustBe!string;

    tag.BQ.mustBe!string.isInvalidIf!q{
        auto s = cast(string)value;
        if (s.length != read.sequence_length)
            return "length is " ~ to!string(s.length) ~
                   " which is not equal to sequence length (" ~ 
                   to!string(read.sequence_length) ~ ")";
    };

    tag.CC.mustBe!string;
    tag.CM.mustBe!int;
    tag.CP.mustBe!int;
    tag.CQ.mustBe!QualityString;
    tag.CS.mustBe!string;

    tag.E2.mustBe!QualityString.isInvalidIf!q{
        auto s = cast(string)value;
        if (s.length != read.sequence_length)
            return "length is " ~ to!string(s.length) ~
                   " which is not equal to sequence length (" ~ 
                   to!string(read.sequence_length) ~ ")";
    };

    tag.FI.mustBe!int;
    tag.FS.mustBe!string;
    tag.FZ.mustBe!(ushort[]);
    tag.LB.mustBe!string;
    tag.H0.mustBe!int;
    tag.H1.mustBe!int;
    tag.H2.mustBe!int;
    tag.HI.mustBe!int;
    tag.IH.mustBe!int;

    tag.MD.mustBe!string.isInvalidIf!q{
        auto s = cast(string)value;

        auto descr = "[MD] tag must match regex /^[0-9]+(([A-Z]|\\^[A-Z]+)[0-9]+)*$/";

        bool valid = true;
        if (s.length == 0) valid = false;
        if (!isDigit(s[0])) valid = false;
        size_t i = 1;
        while (i < s.length && isDigit(s[i])) 
            ++i;
        while (i < s.length) {
            if (isUpper(s[i])) {
                ++i; // [A-Z]
            } else if (s[i] == '^') { // \^[A-Z]+
                ++i;
                if (i == s.length || !isUpper(s[i])) {
                    valid = false;
                    break;
                }
                while (i < s.length && isUpper(s[i]))
                    ++i;
            } else {
                valid = false;
                break;
            }
            // now [0-9]+
            if (i == s.length || !isDigit(s[i])) {
                valid = false;
                break;
            }
            while (i < s.length && isDigit(s[i]))
                ++i;
        }

        if (i < s.length) {
            valid = false;
        }
        
        if (!valid) 
            return descr;
    };

    tag.MQ.mustBe!int;
    tag.NH.mustBe!int;
    tag.NM.mustBe!int;
    tag.OQ.mustBe!QualityString;
    tag.OP.mustBe!int;
    tag.OC.mustBe!string;

    tag.PG.mustBe!string.isInvalidIf!q{
        if (cast(string)value !in header.programs)
            return "[PG] tag value not found in header";
    };

    tag.PQ.mustBe!int;
    tag.PU.mustBe!string;
    tag.Q2.mustBe!QualityString;
    tag.R2.mustBe!string;

    tag.RG.mustBe!string.isInvalidIf!q{
        if (cast(string)value !in header.read_groups)
            return "[RG] tag value not found in header";
    };

    tag.SM.mustBe!int;
    tag.TC.mustBe!int;
    tag.U2.mustBe!QualityString;
    tag.UQ.mustBe!int;

    class GeneralTagValidationError : TagValidationError {
        this(string description, 
             bool function(const SamHeader, Alignment, Value) is_invalid)
        {
            this.description = description;
            _is_invalid = is_invalid;

            generalTagValidationErrors ~= this;
        }

        override string validate(const SamHeader header, Alignment read, Value value)
            @trusted
        {
            return _is_invalid(header, read, value) ? description : null;
        }

        private bool function(const SamHeader, Alignment, Value) _is_invalid;
    }

    tagInvalidCharacterValue = new GeneralTagValidationError(
            "character must be in range [!-~]",
            function (const SamHeader _, Alignment __, Value v) {
                if (!v.is_character) 
                    return false;
                auto c = cast(char)v;
                return !(c >= '!' && c <= '~');
            });

    tagInvalidStringValue = new GeneralTagValidationError(
            "string must match regex /[ !-~]+/",
            function (const SamHeader _, Alignment __, Value v) {
                if (v.tag != GetTypeId!string) 
                    return false;
                
                auto s = cast(string)v;
                if (s.length == 0)
                    return true;
                if (!all!"a >= ' ' && a <= '~'"(s))
                    return true;
                return false;
            });

    tagInvalidHexStringValue = new GeneralTagValidationError(
            "hexadecimal string must be non-empty and consist of hex. digits only",
            function (const SamHeader _, Alignment __, Value v) {
                if (v.tag != hexStringTag)
                    return false;
                auto s = cast(string)v;
                if (s.length == 0)
                    return true;
                if (!(all!isHexDigit(s)))
                    return true;
                return false;
            });

    tagValidationErrors = generalTagValidationErrors ~ invalidTag.values;
}

/// If the read is valid returns null,
/// otherwise returns a descriptive error message.
string validate(const SamHeader header, Alignment read) {
    foreach (e; readValidationErrors) {
        auto msg = e.validate(header, read);
        if (msg !is null)
            return msg;
    }

    foreach (k, v; read) {
        foreach (e; generalTagValidationErrors) {
            auto msg = e.validate(header, read, v);
            if (msg !is null)
                return "[" ~ k ~ "] tag is invalid: " ~ msg;
        }

        auto e = k in invalidTag;
        if (e !is null) {
            auto msg = e.validate(header, read, v);
            if (msg !is null)
                return "[" ~ k ~ "] tag is invalid: " ~ msg;
        }
    }

    return null;
}

/// Returns whether a ${D read) is valid or not.
bool isValid(const SamHeader header, Alignment read) {
    foreach (e; readValidationErrors) {
        if (e.validate(header, read) !is null)
            return false;
    }

    foreach (k, v; read) {
        foreach (e; generalTagValidationErrors) {
            if (e.validate(header, read, v) !is null)
                return false;
        }

        auto e = k in invalidTag;
        if (e !is null && (e.validate(header, read, v) !is null))
            return false;
    }

    return true;
}

unittest {
    import std.stdio;

    auto read = Alignment("ABCDEF",
                          "ACGT",
                          [CigarOperation(4, 'M')]);
    read.is_paired = true;
    read.is_second_of_pair = true;
    read.mate_is_unmapped = false;

    read.next_ref_id = -1;

    read["RG"] = 25;
    read["PG"] = -12.612f;
    read["FZ"] = to!(ushort[])([17, 28, 19, 52]);
    read["Q2"] = "#@#SD";
    read["BQ"] = read["Q2"];

    Value v = "ACDEFADC0121251";
    v.setHexadecimalFlag();
    read["X0"] = v;

    v = cast(string)v ~ "G";
    v.setHexadecimalFlag();
    read["X1"] = v;

    read["X2"] = '\0';
    read["X3"] = '~';
    read["X4"] = "abcdefg!hijk~lmn";
    read["X5"] = "abcdefg\nhijklmn";

    auto header = new SamHeader();

    assert(invalidFlag["is_second_of_pair"].validate(header, read) is null);
    assert(invalidFlag["mate_is_unmapped"].validate(header, read) !is null);
    assert(invalidField["ref_id"].validate(header, read) is null);
    assert(invalidField["next_ref_id"].validate(header, read) is null);
    assert(invalidTag["Q2"].validate(header, read, read["Q2"]) is null);
    assert(invalidTag["BQ"].validate(header, read, read["BQ"]) !is null);
    assert(tagInvalidHexStringValue.validate(header, read, read["X0"]) is null);
    assert(tagInvalidHexStringValue.validate(header, read, read["X1"]) !is null);
    assert(tagInvalidCharacterValue.validate(header, read, read["X2"]) !is null);
    assert(tagInvalidCharacterValue.validate(header, read, read["X3"]) is null);
    assert(tagInvalidStringValue.validate(header, read, read["X4"]) is null);
    assert(tagInvalidStringValue.validate(header, read, read["X5"]) !is null);
}
