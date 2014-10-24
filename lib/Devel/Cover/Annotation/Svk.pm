# Copyright 2005, Paul Johnson (pjcj@cpan.org)

# This software is free.  It is licensed under the same terms as Perl itself.

# The latest version of this software should be available from my homepage:
# http://www.pjcj.net

package Devel::Cover::Annotation::Svk;

use strict;
use warnings;

our $VERSION = "0.54";

use Getopt::Long;

sub new
{
    my $class = shift;
    my $self =
    {
        annotations => [ qw( version author date ) ],
        command     => "svk annotate [[file]]",
        @_
    };
    bless $self, $class
}

sub get_annotations
{
    my $self = shift;
    my ($file) = @_;

    return if exists $self->{_annotations}{$file};
    my $a = $self->{_annotations}{$file} = [];

    my $command = $self->{command};
    $command =~ s/\[\[file\]\]/$file/g;
    open my $c, "-|", $command or warn "Can't run $command: $!\n", return;
    <$c>; <$c>;  # ignore first two lines
    while (<$c>)
    {
        my @a = /(\d+)\s*\(\s*(\S+)\s*(.*?)\):/;
        push @$a, \@a;
    }
    close $c or warn "Failed running $command: $!\n"
}

sub get_options
{
    my ($self, $opt) = @_;
    $self->{$_} = 1 for @{$self->{annotations}};
    die "Bad option" unless
        GetOptions($self,
                   qw(
                       author
                       command=s
                       date
                       version
                     ));
}

sub count
{
    my $self = shift;
    $self->{author} + $self->{date} + $self->{version}
}

sub header
{
    my $self = shift;
    my ($annotation) = @_;
    $self->{annotations}[$annotation]
}

sub width
{
    my $self = shift;
    my ($annotation) = @_;
    (7, 10, 10)[$annotation]
}

sub text
{
    my $self = shift;
    my ($file, $line, $annotation) = @_;
    return "" unless $line;
    $self->get_annotations($file);
    $self->{_annotations}{$file}[$line - 1][$annotation]
}

sub error
{
    my $self = shift;
    my ($file, $line, $annotation) = @_;
    0
}

sub class
{
    my $self = shift;
    my ($file, $line, $annotation) = @_;
    ""
}

1

__END__

=head1 NAME

Devel::Cover::Annotation::Svk - Annotate with svk information

=head1 SYNOPSIS

 cover -report xxx -annotation svk

=head1 DESCRIPTION

Annotate coverage reports with svk annotation information.
This module is designed to be called from the C<cover> program.

=head1 SEE ALSO

 Devel::Cover

=head1 BUGS

Huh?

=head1 VERSION

Version 0.54 - 13th September 2005

=head1 LICENCE

Copyright 2005, Paul Johnson (pjcj@cpan.org)

This software is free.  It is licensed under the same terms as Perl itself.

The latest version of this software should be available from my homepage:
http://www.pjcj.net

=cut
