/*
TEST_OUTPUT:
---
fail_compilation/misc_parser_err_cov1.d(31): Error: `__traits(identifier, args...)` expected
fail_compilation/misc_parser_err_cov1.d(31): Error: semicolon expected following auto declaration, not `o`
fail_compilation/misc_parser_err_cov1.d(31): Error: expression expected, not `)`
fail_compilation/misc_parser_err_cov1.d(32): Error: `type identifier : specialization` expected following `is`
fail_compilation/misc_parser_err_cov1.d(33): Error: semicolon expected following auto declaration, not `auto`
fail_compilation/misc_parser_err_cov1.d(33): Error: found `+` when expecting `(` following `mixin`
fail_compilation/misc_parser_err_cov1.d(34): Error: need size of rightmost array, not type `float`
fail_compilation/misc_parser_err_cov1.d(35): Error: `key:value` expected for associative array literal
fail_compilation/misc_parser_err_cov1.d(36): Error: basic type expected, not `;`
fail_compilation/misc_parser_err_cov1.d(36): Error: `{ members }` expected for anonymous class
fail_compilation/misc_parser_err_cov1.d(38): Error: template argument expected following `!`
fail_compilation/misc_parser_err_cov1.d(38): Error: found `if` when expecting `)`
fail_compilation/misc_parser_err_cov1.d(38): Error: found `)` instead of statement
fail_compilation/misc_parser_err_cov1.d(39): Error: identifier expected following `(type)`.
fail_compilation/misc_parser_err_cov1.d(39): Error: expression expected, not `;`
fail_compilation/misc_parser_err_cov1.d(40): Error: semicolon expected following auto declaration, not `auto`
fail_compilation/misc_parser_err_cov1.d(40): Error: identifier expected following `.`, not `+`
fail_compilation/misc_parser_err_cov1.d(41): Error: declaration expected, not `(`
fail_compilation/misc_parser_err_cov1.d(42): Error: unrecognized declaration
---
*/
module misc_parser_err_cov1;


void main()
{
    // cover errors from line 7930 to EOF
    auto tt = __traits(<o<);
    auto b = is ;
    auto mx1 = mixin +);
    auto aa1 = new char[float];
    aa +=  [key:value, key];
    auto anon1 = new class;
    auto anon2 = new class {};
    if (parseShift !if){}
    auto unaryExParseError = immutable(int).+;
    auto postFixParseError = int.max.+;
    (int).+;
}
