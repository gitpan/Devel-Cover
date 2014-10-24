#!/usr/bin/perl

# Copyright 2004, Paul Johnson (pjcj@cpan.org)

# This software is free.  It is licensed under the same terms as Perl itself.

# The latest version of this software should be available from my homepage:
# http://www.pjcj.net

# __COVER__ select -select eval2

use strict;
use warnings;

use Devel::Cover::Test 0.52;

my $t = "eval2";
my $g = "eval_use.t";

sub run_test
{
    my $test = shift;

    $test->run_command($test->test_command);

    $test->{test_parameters} .= " -merge 1";

    $test->{test_file_parameters} = "5";
    $test->run_command($test->test_command);

    $test->{test_file_parameters} = "7";
    $test->run_command($test->test_command);

    $test->{test_file_parameters} = "0";
    $test->run_command($test->test_command);
}

my $test = Devel::Cover::Test->new
(
    $t,
    golden_test => $g,
    run_test    => \&run_test,
    changes     => 'if (/^Run: /) { $get_line->() for 1 .. 5; redo }',
    tests       => sub { $_[0] - 30 },
);

$test->run_test
