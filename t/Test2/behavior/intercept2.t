use strict;
use warnings;
use Test2::API qw/intercept/;

{
    package t2;
    use Test2::Tools::Tiny;

    package tm;
    use Test::More;
}

my $res = intercept {
#    t2::ok(1, "pass");
#    t2::diag("xxx");
#    t2::ok(0, "fail");
#    t2::todo(foo => sub { t2::ok(0, "fail") });
#    t2::tests(t2_subtest => sub {
#        t2::ok(1, "pass");
#        t2::ok(0, "fail");
#    });
#    t2::note("xxx");
#
#    tm::ok(1, "pass");
    tm::diag("xxx");
#    tm::ok(0, "fail");
#    {
#        local $tm::TODO = "foo";
#        tm::ok(0, "fail");
#    }
    tm::subtest(t2_subtest => sub {
        t2::ok(1, "pass");
        t2::ok(0, "fail");
    });
    tm::note("xxx");
#
    t2::plan(6);
#    tm::BAIL_OUT("foo");
};

use Data::Dumper;
print Dumper($res->state);
print Dumper($res->squash_info->flatten(include_subevents => 1));

t2::ok(1);

t2::done_testing();


1;