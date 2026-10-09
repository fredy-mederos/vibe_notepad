import Foundation

/// Language definitions for `CodeLexer`.
enum CodeSpecs {
    private static func words(_ s: String) -> Set<String> {
        Set(s.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init))
    }

    private static let cComments: [(open: [UInt16], close: [UInt16])] = [(u16("/*"), u16("*/"))]
    private static let slashes = [u16("//")]
    private static let hash = [u16("#")]

    // MARK: Apple & JVM

    static let swift: CodeSpec = {
        var s = CodeSpec()
        s.lineComments = slashes
        s.blockComments = cComments
        s.nestedComments = true
        s.strings = [
            StringSpec("\"\"\"", multiline: true, interpolation: .backslashParen),
            StringSpec("#\"", "\"#", escape: false),
            StringSpec("\"", interpolation: .backslashParen),
        ]
        s.keywords = words("""
        associatedtype class deinit enum extension fileprivate func import init inout internal let open operator
        private precedencegroup protocol public rethrows static struct subscript typealias var break case catch
        continue default defer do else fallthrough for guard if in repeat return throw switch where while as is
        try await async throws any some actor nonisolated isolated consuming borrowing consume copy discard each
        macro package sending convenience dynamic final indirect lazy mutating nonmutating optional override
        required unowned weak get set willSet didSet self super Self Type
        """)
        s.constants = words("true false nil")
        s.types = words("Int Int8 Int16 Int32 Int64 UInt UInt8 UInt16 UInt32 UInt64 Double Float Bool String Character Void Never Any AnyObject")
        s.functionDeclarations = words("func macro")
        s.typeDeclarations = words("class struct enum protocol extension actor typealias associatedtype")
        s.capitalizedTypes = true
        s.allCapsConstants = false
        s.annotationPrefix = Ch.at
        s.hashDirectives = true
        return s
    }()

    static let objectiveC: CodeSpec = {
        var s = c
        s.strings = [StringSpec("\"", prefixes: ["@", ""]), StringSpec("'")]
        s.keywords.formUnion(words("""
        interface implementation end property synthesize protocol class selector encode try catch finally throw
        autoreleasepool optional required public private protected package dynamic import self super instancetype
        nonatomic atomic strong weak copy assign retain readonly readwrite nullable nonnull getter setter in out inout
        bycopy byref oneway __block __weak __strong __unsafe_unretained __bridge __kindof
        """))
        s.types.formUnion(words("id BOOL SEL Class IMP NSInteger NSUInteger CGFloat"))
        s.constants.formUnion(words("YES NO nil Nil"))
        s.annotationPrefix = Ch.at
        s.annotationKind = .keyword
        s.capitalizedTypes = true
        return s
    }()

    static let kotlin: CodeSpec = {
        var s = CodeSpec()
        s.lineComments = slashes
        s.blockComments = cComments
        s.nestedComments = true
        s.strings = [
            StringSpec("\"\"\"", escape: false, multiline: true, interpolation: .dollarNameAndBrace),
            StringSpec("\"", interpolation: .dollarNameAndBrace),
            StringSpec("'"),
        ]
        s.keywords = words("""
        package import class interface fun object val var typealias constructor by companion init this super where
        if else when try catch finally for do while throw return continue break as is in out abstract final enum
        open annotation sealed data override lateinit inner private protected public internal suspend tailrec
        operator infix inline noinline crossinline external const vararg reified expect actual value get set field
        """)
        s.constants = words("true false null")
        s.types = words("Int Long Short Byte Double Float Boolean Char String Unit Any Nothing")
        s.functionDeclarations = words("fun")
        s.typeDeclarations = words("class interface object typealias")
        s.capitalizedTypes = true
        s.annotationPrefix = Ch.at
        s.blockCallsAreFunctions = true
        return s
    }()

    static let java: CodeSpec = {
        var s = CodeSpec()
        s.lineComments = slashes
        s.blockComments = cComments
        s.strings = [StringSpec("\"\"\"", multiline: true), StringSpec("\""), StringSpec("'")]
        s.keywords = words("""
        abstract assert break case catch class const continue default do else enum extends final finally for goto
        if implements import instanceof interface native new package private protected public return static strictfp
        super switch synchronized this throw throws transient try volatile while var record sealed permits yield
        module requires exports opens uses provides with to transitive
        """)
        s.types = words("boolean byte char short int long float double void")
        s.constants = words("true false null")
        s.typeDeclarations = words("class interface enum record")
        s.capitalizedTypes = true
        s.annotationPrefix = Ch.at
        return s
    }()

    static let groovy: CodeSpec = {
        var s = java
        s.strings = [
            StringSpec("\"\"\"", multiline: true, interpolation: .dollarNameAndBrace),
            StringSpec("'''", multiline: true),
            StringSpec("\"", interpolation: .dollarNameAndBrace),
            StringSpec("'"),
        ]
        s.keywords.formUnion(words("def as in trait it"))
        s.functionDeclarations = words("def")
        s.blockCallsAreFunctions = true
        return s
    }()

    static let scala: CodeSpec = {
        var s = CodeSpec()
        s.lineComments = slashes
        s.blockComments = cComments
        s.nestedComments = true
        s.strings = [
            StringSpec("\"\"\"", prefixes: ["s", "f", "raw", ""], multiline: true, interpolation: .dollarNameAndBrace),
            StringSpec("\"", prefixes: ["s", "f"], interpolation: .dollarNameAndBrace),
            StringSpec("\""),
            StringSpec("'"),
        ]
        s.keywords = words("""
        abstract case catch class def do else extends final finally for forSome if implicit import lazy match new
        object override package private protected return sealed super this throw trait try type val var while with
        yield given using enum export then end extension derives inline opaque transparent
        """)
        s.constants = words("true false null")
        s.functionDeclarations = words("def")
        s.typeDeclarations = words("class trait object type enum")
        s.capitalizedTypes = true
        s.annotationPrefix = Ch.at
        return s
    }()

    // MARK: C family

    static let c: CodeSpec = {
        var s = CodeSpec()
        s.lineComments = slashes
        s.blockComments = cComments
        s.strings = [StringSpec("\""), StringSpec("'")]
        s.keywords = words("""
        auto break case const continue default do else enum extern for goto if inline register restrict return sizeof
        static struct switch typedef union volatile while _Alignas _Alignof _Atomic _Bool _Complex _Generic
        _Imaginary _Noreturn _Static_assert _Thread_local
        """)
        s.types = words("char double float int long short signed unsigned void bool")
        s.constants = words("NULL true false")
        s.typeDeclarations = words("struct union enum typedef")
        s.preprocessor = true
        s.typeSuffixT = true
        return s
    }()

    static let cpp: CodeSpec = {
        var s = c
        s.strings = [StringSpec("R\"(", ")\"", escape: false, multiline: true), StringSpec("\""), StringSpec("'")]
        s.keywords.formUnion(words("""
        alignas alignof and and_eq asm bitand bitor catch class compl concept consteval constexpr constinit const_cast
        co_await co_return co_yield decltype delete dynamic_cast explicit export friend mutable namespace new noexcept
        not not_eq operator or or_eq private protected public reinterpret_cast requires static_assert static_cast
        template this thread_local throw try typeid typename using virtual xor xor_eq override final
        """))
        s.types.formUnion(words("wchar_t char8_t char16_t char32_t auto string"))
        s.constants.formUnion(words("nullptr"))
        s.typeDeclarations = words("class struct union enum namespace typedef")
        s.capitalizedTypes = true
        return s
    }()

    static let csharp: CodeSpec = {
        var s = CodeSpec()
        s.lineComments = slashes
        s.blockComments = cComments
        s.strings = [
            StringSpec("\"\"\"", multiline: true),
            StringSpec("\"", prefixes: ["$@", "@$"], escape: false, multiline: true, interpolation: .braces, doubledCloseEscapes: true),
            StringSpec("\"", prefixes: ["@"], escape: false, multiline: true, doubledCloseEscapes: true),
            StringSpec("\"", prefixes: ["$"], interpolation: .braces),
            StringSpec("\""),
            StringSpec("'"),
        ]
        s.keywords = words("""
        abstract as base break case catch checked class const continue default delegate do else enum event explicit
        extern finally fixed for foreach goto if implicit in interface internal is lock namespace new operator out
        override params private protected public readonly ref return sealed sizeof stackalloc static struct switch
        this throw try typeof unchecked unsafe using virtual volatile while add alias ascending async await by
        descending dynamic equals from get global group into join let nameof on orderby partial remove select set
        value var when where yield record init required with file scoped
        """)
        s.types = words("bool byte char decimal double float int long object sbyte short string uint ulong ushort void nint nuint")
        s.constants = words("true false null")
        s.typeDeclarations = words("class struct interface enum record namespace")
        s.capitalizedTypes = true
        s.allCapsConstants = false
        s.preprocessor = true
        return s
    }()

    static let go: CodeSpec = {
        var s = CodeSpec()
        s.lineComments = slashes
        s.blockComments = cComments
        s.strings = [StringSpec("`", escape: false, multiline: true), StringSpec("\""), StringSpec("'")]
        s.keywords = words("""
        break case chan const continue default defer else fallthrough for func go goto if import interface map
        package range return select struct switch type var
        """)
        s.types = words("bool byte complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string uint uint8 uint16 uint32 uint64 uintptr any comparable")
        s.constants = words("true false nil iota")
        s.builtins = words("append cap clear close complex copy delete imag len make max min new panic print println real recover")
        s.functionDeclarations = words("func")
        s.typeDeclarations = words("type")
        return s
    }()

    static let rust: CodeSpec = {
        var s = CodeSpec()
        s.lineComments = slashes
        s.blockComments = cComments
        s.nestedComments = true
        s.strings = [
            StringSpec("\"", prefixes: ["r#"], escape: false, multiline: true),
            StringSpec("\"", prefixes: ["r", "b", "br", "c", ""], multiline: true),
            StringSpec("'", prefixes: ["b", ""]),
        ]
        s.keywords = words("""
        as async await break const continue crate dyn else enum extern fn for if impl in let loop match mod move mut
        pub ref return self Self static struct super trait type unsafe use where while yield macro_rules union
        """)
        s.types = words("i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 bool char str")
        s.constants = words("true false None Some Ok Err")
        s.functionDeclarations = words("fn")
        s.typeDeclarations = words("struct enum trait type union")
        s.capitalizedTypes = true
        s.rust = true
        return s
    }()

    // MARK: Web

    static let javascript: CodeSpec = {
        var s = CodeSpec()
        s.lineComments = slashes
        s.blockComments = cComments
        s.strings = [
            StringSpec("`", multiline: true, interpolation: .dollarBrace),
            StringSpec("\""),
            StringSpec("'"),
        ]
        s.keywords = words("""
        async await break case catch class const continue debugger default delete do else export extends finally
        for from function get if import in instanceof let new of return set static super switch this throw try
        typeof var void while with yield as
        """)
        s.constants = words("true false null undefined NaN Infinity")
        s.builtins = words("console window document require module exports process globalThis setTimeout setInterval clearTimeout clearInterval fetch parseInt parseFloat")
        s.functionDeclarations = words("function")
        s.typeDeclarations = words("class extends")
        s.identExtra = Ch.dollar
        s.capitalizedTypes = true
        s.regexLiterals = true
        s.jsx = true
        s.annotationPrefix = Ch.at
        return s
    }()

    static let typescript: CodeSpec = {
        var s = javascript
        s.keywords.formUnion(words("""
        abstract any asserts bigint boolean declare enum implements infer interface is keyof module namespace never
        number object private protected public readonly string symbol type unique unknown override satisfies accessor
        """))
        s.typeDeclarations = words("class interface type enum namespace extends implements")
        return s
    }()

    static let php: CodeSpec = {
        var s = CodeSpec()
        s.lineComments = slashes + hash
        s.blockComments = cComments
        s.strings = [StringSpec("\"", multiline: true, interpolation: .dollarNameAndBrace), StringSpec("'", multiline: true)]
        s.keywords = words("""
        abstract and array as break callable case catch class clone const continue declare default do echo else
        elseif empty enddeclare endfor endforeach endif endswitch endwhile enum extends final finally fn for foreach
        function global goto if implements include include_once instanceof insteadof interface isset list match
        namespace new or print private protected public readonly require require_once return static switch throw
        trait try unset use var while xor yield php self parent
        """)
        s.types = words("int float string bool array object mixed void never iterable callable null")
        s.constants = words("true false null")
        s.caseInsensitive = false
        s.functionDeclarations = words("function fn")
        s.typeDeclarations = words("class interface trait enum extends implements")
        s.variablePrefixes = [Ch.dollar]
        s.capitalizedTypes = true
        return s
    }()

    // MARK: Scripting

    static let python: CodeSpec = {
        var s = CodeSpec()
        s.lineComments = hash
        let fPrefixes = ["f", "rf", "fr"]
        let plainPrefixes = ["", "r", "b", "u", "rb", "br"]
        s.strings = [
            StringSpec("\"\"\"", prefixes: fPrefixes, multiline: true, interpolation: .braces),
            StringSpec("'''", prefixes: fPrefixes, multiline: true, interpolation: .braces),
            StringSpec("\"\"\"", prefixes: plainPrefixes, multiline: true),
            StringSpec("'''", prefixes: plainPrefixes, multiline: true),
            StringSpec("\"", prefixes: fPrefixes, interpolation: .braces),
            StringSpec("'", prefixes: fPrefixes, interpolation: .braces),
            StringSpec("\"", prefixes: plainPrefixes),
            StringSpec("'", prefixes: plainPrefixes),
        ]
        s.keywords = words("""
        and as assert async await break class continue def del elif else except finally for from global if import
        in is lambda nonlocal not or pass raise return try while with yield match case
        """)
        s.constants = words("True False None NotImplemented Ellipsis __name__ __file__ __main__")
        s.variables = words("self cls")
        s.builtins = words("""
        abs all any bin bool bytes callable chr classmethod dict dir divmod enumerate eval exec filter float format
        frozenset getattr globals hasattr hash help hex id input int isinstance issubclass iter len list locals map
        max min next object oct open ord pow print property range repr reversed round set setattr slice sorted
        staticmethod str sum super tuple type vars zip
        """)
        s.functionDeclarations = words("def")
        s.typeDeclarations = words("class")
        s.capitalizedTypes = true
        s.annotationPrefix = Ch.at
        return s
    }()

    static let ruby: CodeSpec = {
        var s = CodeSpec()
        s.lineComments = hash
        s.blockComments = [(u16("=begin"), u16("=end"))]
        s.strings = [
            StringSpec("\"", multiline: true, interpolation: .hashBrace),
            StringSpec("'", multiline: true),
            StringSpec("`", interpolation: .hashBrace),
        ]
        s.keywords = words("""
        BEGIN END alias and begin break case class def defined? do else elsif end ensure for if in module next not or
        redo rescue retry return self super then undef unless until when while yield __method__ require
        require_relative include extend prepend attr_accessor attr_reader attr_writer private protected public raise
        lambda proc loop
        """)
        s.constants = words("true false nil")
        s.builtins = words("puts print p pp format sprintf gets")
        s.functionDeclarations = words("def")
        s.typeDeclarations = words("class module")
        s.identExtra = Ch.question
        s.identExtra2 = Ch.bang
        s.variablePrefixes = [Ch.at, Ch.dollar]
        s.symbolPrefix = Ch.colon
        s.capitalizedTypes = true
        s.regexLiterals = true
        return s
    }()

    static let lua: CodeSpec = {
        var s = CodeSpec()
        s.lineComments = [u16("--")]
        s.blockComments = [(u16("--[["), u16("]]"))]
        s.strings = [StringSpec("[[", "]]", escape: false, multiline: true), StringSpec("\""), StringSpec("'")]
        s.keywords = words("and break do else elseif end for function goto if in local not or repeat return then until while")
        s.constants = words("true false nil")
        s.variables = words("self")
        s.builtins = words("""
        print pairs ipairs require type tostring tonumber setmetatable getmetatable error assert pcall xpcall select
        next rawget rawset rawequal unpack table string math os io coroutine debug utf8
        """)
        s.functionDeclarations = words("function")
        return s
    }()

    static let dart: CodeSpec = {
        var s = CodeSpec()
        s.lineComments = slashes
        s.blockComments = cComments
        s.nestedComments = true
        s.strings = [
            StringSpec("'''", prefixes: ["r", ""], multiline: true, interpolation: .dollarNameAndBrace),
            StringSpec("\"\"\"", prefixes: ["r", ""], multiline: true, interpolation: .dollarNameAndBrace),
            StringSpec("'", prefixes: ["r", ""], interpolation: .dollarNameAndBrace),
            StringSpec("\"", prefixes: ["r", ""], interpolation: .dollarNameAndBrace),
        ]
        s.keywords = words("""
        abstract as assert async await base break case catch class const continue covariant default deferred do
        dynamic else enum export extends extension external factory final finally for Function get hide if implements
        import in interface is late library mixin new of on operator part required rethrow return sealed set show
        static super switch sync this throw try typedef var void when while with yield
        """)
        s.constants = words("true false null")
        s.types = words("int double num String bool List Map Set Future Stream Object Never Iterable")
        s.typeDeclarations = words("class mixin enum extension typedef")
        s.capitalizedTypes = true
        s.annotationPrefix = Ch.at
        return s
    }()

    static let perl: CodeSpec = {
        var s = CodeSpec()
        s.lineComments = hash
        s.strings = [StringSpec("\"", multiline: true, interpolation: .dollarNameAndBrace), StringSpec("'", multiline: true), StringSpec("`")]
        s.keywords = words("""
        my our local sub if elsif else unless while until for foreach do last next redo return use no require package
        BEGIN END and or not eq ne lt gt le ge cmp qw q qq m s tr y print printf die warn eval defined undef wantarray
        ref bless scalar shift push pop splice keys values each exists delete chomp chop join split sprintf open close
        """)
        s.functionDeclarations = words("sub")
        s.typeDeclarations = words("package")
        s.variablePrefixes = [Ch.dollar, Ch.at, Ch.percent]
        s.regexLiterals = true
        return s
    }()

    static let r: CodeSpec = {
        var s = CodeSpec()
        s.lineComments = hash
        s.strings = [StringSpec("\"", multiline: true), StringSpec("'", multiline: true), StringSpec("`", kind: .variable)]
        s.keywords = words("if else repeat while function for in next break return library require")
        s.constants = words("TRUE FALSE NULL Inf NaN NA NA_integer_ NA_real_ NA_character_ T F")
        s.identExtra = Ch.dot
        return s
    }()

    static let elixir: CodeSpec = {
        var s = CodeSpec()
        s.lineComments = hash
        s.strings = [
            StringSpec("\"\"\"", multiline: true, interpolation: .hashBrace),
            StringSpec("\"", multiline: true, interpolation: .hashBrace),
            StringSpec("'", multiline: true),
        ]
        s.keywords = words("""
        def defp defmodule defmacro defmacrop defprotocol defimpl defstruct defdelegate defguard defexception do end
        if else unless case cond fn when import alias require use quote unquote receive try catch rescue after raise
        in and or not with for
        """)
        s.constants = words("true false nil")
        s.functionDeclarations = words("def defp defmacro defmacrop defguard")
        s.typeDeclarations = words("defmodule defprotocol defimpl")
        s.identExtra = Ch.question
        s.identExtra2 = Ch.bang
        s.symbolPrefix = Ch.colon
        s.annotationPrefix = Ch.at
        s.capitalizedTypes = true
        s.identBeforeColonIsProperty = true
        return s
    }()

    static let haskell: CodeSpec = {
        var s = CodeSpec()
        s.lineComments = [u16("--")]
        s.blockComments = [(u16("{-"), u16("-}"))]
        s.nestedComments = true
        s.strings = [StringSpec("\""), StringSpec("'")]
        s.keywords = words("""
        module where import qualified as hiding data type newtype class instance deriving let in if then else case of
        do forall infix infixl infixr default
        """)
        s.constants = words("True False Nothing Just Left Right")
        s.typeDeclarations = words("data type newtype class instance")
        s.identExtra = Ch.apostrophe
        s.capitalizedTypes = true
        s.allCapsConstants = false
        return s
    }()

    static let sql: CodeSpec = {
        var s = CodeSpec()
        s.lineComments = [u16("--"), u16("#")]
        s.blockComments = cComments
        s.strings = [
            StringSpec("'", escape: false, multiline: true, doubledCloseEscapes: true),
            StringSpec("\"", escape: false, kind: .property),
            StringSpec("`", escape: false, kind: .property),
        ]
        s.caseInsensitive = true
        s.keywords = words("""
        select from where and or not insert into values update set delete create table drop alter add column primary
        key foreign references index unique default constraint check join inner left right full outer cross on as
        distinct group by order having limit offset union all exists in between like ilike is case when then else end
        begin commit rollback transaction view trigger function procedure returns return declare if while loop for
        with recursive grant revoke database schema use show describe explain asc desc nulls first last over
        partition window cascade truncate replace merge using matched fetch next rows only top percent pivot unpivot
        lateral returning conflict do nothing temporary temp sequence auto_increment identity generated always
        stored virtual collate language security definer immutable stable volatile execute perform raise notice
        exception elsif deferrable initially deferred restrict
        """)
        s.types = words("""
        int integer smallint bigint tinyint mediumint decimal numeric float real double precision char varchar text
        nchar nvarchar date time timestamp timestamptz interval boolean bool blob clob bytea json jsonb uuid serial
        bigserial money xml array enum bit varbinary binary longtext mediumtext tinytext datetime year inet cidr
        """)
        s.constants = words("true false null")
        s.builtins = words("""
        count sum avg min max coalesce nullif cast convert now current_date current_time current_timestamp lower upper
        trim ltrim rtrim substring substr length concat round floor ceil ceiling abs date_trunc extract to_char
        to_date row_number rank dense_rank lag lead string_agg array_agg json_agg jsonb_build_object greatest least
        """)
        s.variablePrefixes = [Ch.at]
        s.allCapsConstants = false
        s.propertyAfterDot = true
        return s
    }()

    static let powershell: CodeSpec = {
        var s = CodeSpec()
        s.lineComments = hash
        s.blockComments = [(u16("<#"), u16("#>"))]
        s.strings = [
            StringSpec("@\"", "\"@", escape: false, multiline: true, interpolation: .dollarNameAndBrace),
            StringSpec("@'", "'@", escape: false, multiline: true),
            StringSpec("\"", escape: false, multiline: true, interpolation: .dollarNameAndBrace, doubledCloseEscapes: true),
            StringSpec("'", escape: false, multiline: true, doubledCloseEscapes: true),
        ]
        s.caseInsensitive = true
        s.keywords = words("""
        begin break catch class continue data define do dynamicparam else elseif end enum exit filter finally for
        foreach from function hidden if in param process return static switch throw trap try until using var while
        workflow parallel sequence inlinescript
        """)
        s.constants = words("$true $false $null")
        s.functionDeclarations = words("function filter workflow")
        s.typeDeclarations = words("class enum")
        s.variablePrefixes = [Ch.dollar]
        s.identExtra = Ch.minus
        s.dashOperators = true
        s.allCapsConstants = false
        return s
    }()

    // MARK: Data & schema

    static let graphql: CodeSpec = {
        var s = CodeSpec()
        s.lineComments = hash
        s.strings = [StringSpec("\"\"\"", multiline: true), StringSpec("\"")]
        s.keywords = words("query mutation subscription fragment on type interface union enum input scalar schema extend directive implements repeatable")
        s.constants = words("true false null")
        s.types = words("Int Float String Boolean ID")
        s.typeDeclarations = words("type interface union enum input scalar fragment")
        s.variablePrefixes = [Ch.dollar]
        s.annotationPrefix = Ch.at
        s.capitalizedTypes = true
        s.allCapsConstants = false
        s.identBeforeColonIsProperty = true
        return s
    }()

    static let protobuf: CodeSpec = {
        var s = CodeSpec()
        s.lineComments = slashes
        s.blockComments = cComments
        s.strings = [StringSpec("\""), StringSpec("'")]
        s.keywords = words("syntax edition package import public weak option message enum service rpc returns repeated optional required oneof map reserved extend stream to max extensions group")
        s.types = words("double float int32 int64 uint32 uint64 sint32 sint64 fixed32 fixed64 sfixed32 sfixed64 bool string bytes")
        s.constants = words("true false")
        s.typeDeclarations = words("message enum service")
        s.functionDeclarations = words("rpc")
        s.capitalizedTypes = true
        s.allCapsConstants = true
        return s
    }()

    static let hcl: CodeSpec = {
        var s = CodeSpec()
        s.lineComments = hash + slashes
        s.blockComments = cComments
        s.strings = [StringSpec("\"", interpolation: .dollarBrace)]
        s.keywords = words("""
        resource data variable output locals module provider terraform required_providers backend for in if else
        for_each count depends_on lifecycle dynamic content each self var local path moved import check removed
        """)
        s.constants = words("true false null")
        s.identBeforeEqualsIsProperty = true
        s.identExtra = Ch.minus
        s.allCapsConstants = false
        return s
    }()

    static let appleStrings: CodeSpec = {
        var s = CodeSpec()
        s.lineComments = slashes
        s.blockComments = cComments
        s.strings = [StringSpec("\"")]
        s.keyStringsBefore = [Ch.equals]
        s.identBeforeEqualsIsProperty = true
        s.allCapsConstants = false
        s.callsAreFunctions = false
        return s
    }()
}
