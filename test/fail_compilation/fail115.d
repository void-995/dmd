// https://issues.dlang.org/show_bug.cgi?id=402
// compiler crash with mixin and forward reference

template Foo(alias b)
{
    int a() { return b; }
}

void main()
{
    mixin Foo!(y) y;
}
