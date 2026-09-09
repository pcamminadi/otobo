# --
# OTOBO is a web-based ticketing system for service organisations.
# --
# Copyright (C) 2019-2026 Rother OSS GmbH, https://otobo.io/
# --
# This program is free software: you can redistribute it and/or modify it under
# the terms of the GNU General Public License as published by the Free Software
# Foundation, either version 3 of the License, or (at your option) any later version.
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.
# --

use v5.24;
use strict;
use warnings;
use utf8;

# CPAN modules
use Test2::V0;

# OTOBO modules
use Kernel::System::Ticket::Article::ListData;

my $FetchCalls = 0;
my $Fetch      = sub {
    $FetchCalls++;

    return ( ArticleID => 10, TicketID => 20, Subject => 'fallback' );
};

my $PreloadedArticle = {
    ArticleID    => 10,
    TicketID     => 20,
    Body         => 'body',
    Subject      => 'subject',
    IsEdited     => 0,
    DynamicField => { Value => ['original'] },
};

my %Article = Kernel::System::Ticket::Article::ListData->ArticleForFields(
    ArticleID       => 10,
    TicketID        => 20,
    PreloadedArticle => $PreloadedArticle,
    Fetch           => $Fetch,
);
is( $FetchCalls, 0, 'matching complete article data avoids a duplicate fetch' );
is( \%Article, $PreloadedArticle, 'preloaded article data is returned unchanged' );

$Article{DynamicField}->{Value}->[0] = 'changed';
is(
    $PreloadedArticle->{DynamicField}->{Value}->[0],
    'original',
    'nested article data is copied before view modules can mutate it',
);

for my $Test (
    {
        Name   => 'ticket mismatch',
        Params => { TicketID => 21 },
    },
    {
        Name   => 'article mismatch',
        Params => { ArticleID => 11 },
    },
    {
        Name   => 'deleted article',
        Article => { ArticleDeleted => 1 },
    },
    {
        Name   => 'version view',
        Params => { VersionView => 1 },
    },
    {
        Name   => 'incomplete snapshot',
        Article => { Body => undef },
        Remove  => 'IsEdited',
    },
    )
{
    my %Candidate = %{$PreloadedArticle};
    @Candidate{ keys %{ $Test->{Article} || {} } } = values %{ $Test->{Article} || {} };
    delete $Candidate{ $Test->{Remove} } if $Test->{Remove};

    my %Result = Kernel::System::Ticket::Article::ListData->ArticleForFields(
        ArticleID        => 10,
        TicketID         => 20,
        PreloadedArticle => \%Candidate,
        Fetch            => $Fetch,
        %{ $Test->{Params} || {} },
    );
    is( $Result{Subject}, 'fallback', "$Test->{Name} uses the original fetch path" );
}

is( $FetchCalls, 5, 'all unsafe preload cases use the fallback' );

done_testing();
