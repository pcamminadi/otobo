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

{
    package Local::DB;

    sub new {
        return bless { PrepareCalls => [] }, shift;
    }

    sub Prepare {
        my ( $Self, %Param ) = @_;

        push @{ $Self->{PrepareCalls} }, \%Param;
        if ( $Param{SQL} =~ m{article_version} ) {
            $Self->{Rows} = [ [10], [12] ];
        }
        elsif ( $Param{SQL} =~ m{article_flag} ) {
            $Self->{Rows} = [ [ 10, 'Important', 1 ] ];
        }
        else {
            $Self->{Rows} = [
                [ 10, 'a.txt', 'text/plain', 3, '', 0, 'attachment' ],
                [ 10, 'image.png', 'image/png', 5, '<cid>', 0, '' ],
            ];
        }

        return 1;
    }

    sub FetchrowArray {
        my ($Self) = @_;

        return if !@{ $Self->{Rows} };

        return @{ shift @{ $Self->{Rows} } };
    }
}

my $DBObject = Local::DB->new();
my $EditStates = Kernel::System::Ticket::Article::ListData->EditStates(
    DBObject   => $DBObject,
    TicketID   => 20,
    ArticleIDs => [ 10, 11 ],
);
is(
    $EditStates,
    {
        TicketID => 20,
        States   => { 10 => 1, 11 => 0 },
    },
    'edit state is indexed for the selected article page',
);

my $EditFallbackCalls = 0;
is(
    Kernel::System::Ticket::Article::ListData->IsEdited(
        ArticleID          => 10,
        TicketID           => 20,
        PreloadedEditStates => $EditStates,
        Fetch              => sub { $EditFallbackCalls++; return 0 },
    ),
    1,
    'matching preloaded edit state is reused',
);
is( $EditFallbackCalls, 0, 'edit-state reuse avoids the original lookup' );
is(
    Kernel::System::Ticket::Article::ListData->IsEdited(
        ArticleID          => 10,
        TicketID           => 21,
        PreloadedEditStates => $EditStates,
        Fetch              => sub { $EditFallbackCalls++; return 0 },
    ),
    0,
    'a mismatched ticket uses the edit-state fallback',
);

is(
    Kernel::System::Ticket::Article::ListData->ImportantFlags(
        DBObject => $DBObject,
        TicketID => 20,
        UserID   => 1,
    ),
    { 10 => { Important => 1 } },
    'important flags are loaded once for the ticket',
);

my $AttachmentIndexes = Kernel::System::Ticket::Article::ListData->AttachmentIndexes(
    DBObject   => $DBObject,
    TicketID   => 20,
    ArticleIDs => [ 10, 11 ],
);
is(
    $AttachmentIndexes->{Indexes}->{10},
    {
        1 => {
            Filename           => 'a.txt',
            ContentType        => 'text/plain',
            FilesizeRaw        => 3,
            ContentID          => '',
            ContentAlternative => '',
            Disposition        => 'attachment',
        },
        2 => {
            Filename           => 'image.png',
            ContentType        => 'image/png',
            FilesizeRaw        => 5,
            ContentID          => '<cid>',
            ContentAlternative => '',
            Disposition        => 'inline',
        },
    },
    'attachment metadata keeps native ordering and disposition defaults',
);

my $AttachmentFallbackCalls = 0;
my %AttachmentIndex = Kernel::System::Ticket::Article::ListData->AttachmentIndex(
    ArticleID                 => 10,
    TicketID                  => 20,
    BackendObject             => bless( {}, 'Kernel::System::Ticket::Article::Backend::MIMEBase::ArticleStorageDB' ),
    PreloadedAttachmentIndexes => $AttachmentIndexes,
    Fetch                     => sub { $AttachmentFallbackCalls++; return () },
);
is( \%AttachmentIndex, $AttachmentIndexes->{Indexes}->{10}, 'matching DB metadata is reused' );
$AttachmentIndex{1}->{Filename} = 'changed';
is(
    $AttachmentIndexes->{Indexes}->{10}->{1}->{Filename},
    'a.txt',
    'preloaded attachment metadata is copied before filtering',
);
is( $AttachmentFallbackCalls, 0, 'attachment reuse avoids the original backend lookup' );

%AttachmentIndex = Kernel::System::Ticket::Article::ListData->AttachmentIndex(
    ArticleID                 => 11,
    TicketID                  => 20,
    BackendObject             => bless( {}, 'Kernel::System::Ticket::Article::Backend::MIMEBase::ArticleStorageDB' ),
    PreloadedAttachmentIndexes => $AttachmentIndexes,
    Fetch                     => sub { $AttachmentFallbackCalls++; return ( 1 => { Filename => 'fallback' } ) },
);
is( $AttachmentIndex{1}->{Filename}, 'fallback', 'missing preloaded rows use the backend fallback' );
is( $AttachmentFallbackCalls, 1, 'attachment fallback was called once' );

done_testing();
