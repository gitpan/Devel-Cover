# Copyright 2002-2014, Paul Johnson (paul@pjcj.net)

# This software is free.  It is licensed under the same terms as Perl itself.

# The latest version of this software should be available from my homepage:
# http://www.pjcj.net

package Module1;

my $y = 7;
$y++;

sub _aa {
    $y++;
    die;
    die;
}

sub xx {
    $y++;
    die;
}

sub yy {
    $y++;
}

sub zz {
    my $x = shift;
    $x++;
}

1

__END__

=head2 yy

yy

=cut
