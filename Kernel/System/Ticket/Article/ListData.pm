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

package Kernel::System::Ticket::Article::ListData;

use v5.24;
use strict;
use warnings;

# core modules
use Storable qw(dclone);

sub ArticleForFields {
    my ( $Class, %Param ) = @_;

    my $Article = $Param{PreloadedArticle};
    if (
        ref $Article eq 'HASH'
        && !$Param{VersionView}
        && !$Param{SourceArticleID}
        && !$Article->{ArticleDeleted}
        && !$Article->{IsDeleted}
        && defined $Article->{TicketID}
        && defined $Article->{ArticleID}
        && $Article->{TicketID} eq ( $Param{TicketID} // '' )
        && $Article->{ArticleID} eq ( $Param{ArticleID} // '' )
        && exists $Article->{Body}
        && exists $Article->{Subject}
        && exists $Article->{IsEdited}
        )
    {
        # Article view modules may mutate nested dynamic-field values while rendering.
        return %{ dclone($Article) };
    }

    return $Param{Fetch}->();
}

sub EditStates {
    my ( $Class, %Param ) = @_;

    return if !$Param{TicketID};
    return if ref $Param{ArticleIDs} ne 'ARRAY';

    my %States = map { $_ => 0 } @{ $Param{ArticleIDs} };
    return if !%States;

    return if !$Param{DBObject}->Prepare(
        SQL  => 'SELECT DISTINCT source_article_id FROM article_version WHERE ticket_id = ? AND article_delete <> 1',
        Bind => [ \$Param{TicketID} ],
    );
    while ( my @Row = $Param{DBObject}->FetchrowArray() ) {
        $States{ $Row[0] } = 1 if exists $States{ $Row[0] };
    }

    return {
        States   => \%States,
        TicketID => $Param{TicketID},
    };
}

sub IsEdited {
    my ( $Class, %Param ) = @_;

    my $State = $Param{PreloadedEditStates};
    if (
        !$Param{VersionView}
        && ref $State eq 'HASH'
        && ( $State->{TicketID} // '' ) eq ( $Param{TicketID} // '' )
        && ref $State->{States} eq 'HASH'
        && exists $State->{States}->{ $Param{ArticleID} }
        )
    {
        return $State->{States}->{ $Param{ArticleID} };
    }

    return $Param{Fetch}->();
}

sub ImportantFlags {
    my ( $Class, %Param ) = @_;

    return if !$Param{TicketID};
    return if !$Param{UserID};

    return if !$Param{DBObject}->Prepare(
        SQL => 'SELECT article.id, article_flag.article_key, article_flag.article_value'
            . ' FROM article_flag, article'
            . ' WHERE article.id = article_flag.article_id'
            . ' AND article.ticket_id = ? AND article_flag.create_by = ?',
        Bind => [ \$Param{TicketID}, \$Param{UserID} ],
    );

    my %Flags;
    while ( my @Row = $Param{DBObject}->FetchrowArray() ) {
        $Flags{ $Row[0] }->{ $Row[1] } = $Row[2];
    }

    return \%Flags;
}

sub AttachmentIndexes {
    my ( $Class, %Param ) = @_;

    return if !$Param{TicketID};
    return if ref $Param{ArticleIDs} ne 'ARRAY';

    my %ArticleIDs = map { $_ => 1 }
        grep { defined $_ && $_ =~ m{\A[1-9][0-9]*\z} } @{ $Param{ArticleIDs} };
    my @ArticleIDs = sort { $a <=> $b } keys %ArticleIDs;
    return if !@ArticleIDs;

    my %Counters;
    my %Indexes;
    while (@ArticleIDs) {
        my @Batch       = splice @ArticleIDs, 0, 500;
        my $Placeholders = join ',', ('?') x @Batch;
        return if !$Param{DBObject}->Prepare(
            SQL => "SELECT att.article_id, att.filename, att.content_type, att.content_size,"
                . " att.content_id, att.content_alternative, att.disposition"
                . " FROM article_data_mime_attachment att INNER JOIN article a ON a.id = att.article_id"
                . " WHERE a.ticket_id = ? AND att.article_id IN ($Placeholders)"
                . " ORDER BY att.article_id, att.filename, att.id",
            Bind => [ \$Param{TicketID}, map { \$_ } @Batch ],
        );
        while ( my @Row = $Param{DBObject}->FetchrowArray() ) {
            my $ArticleID  = shift @Row;
            my $Disposition = $Row[5];
            if ( !$Disposition ) {
                $Disposition =
                    ( $Row[3] && $Row[1] =~ m{image}i ) || $Row[0] =~ m{file-[12]}
                    ? 'inline'
                    : 'attachment';
            }
            $Indexes{$ArticleID}->{ ++$Counters{$ArticleID} } = {
                Filename           => $Row[0],
                ContentType        => $Row[1],
                FilesizeRaw        => $Row[2] || 0,
                ContentID          => $Row[3] || '',
                ContentAlternative => $Row[4] || '',
                Disposition        => $Disposition,
            };
        }
    }

    return {
        Indexes  => \%Indexes,
        TicketID => $Param{TicketID},
    };
}

sub AttachmentIndex {
    my ( $Class, %Param ) = @_;

    my $State = $Param{PreloadedAttachmentIndexes};
    if (
        ref $Param{BackendObject} eq 'Kernel::System::Ticket::Article::Backend::MIMEBase::ArticleStorageDB'
        && !$Param{VersionView}
        && !$Param{SourceArticleID}
        && !$Param{ArticleDeleted}
        && ref $State eq 'HASH'
        && $Param{TicketID}
        && ( $State->{TicketID} // '' ) eq $Param{TicketID}
        && ref $State->{Indexes} eq 'HASH'
        && ref $State->{Indexes}->{ $Param{ArticleID} } eq 'HASH'
        )
    {
        return %{ dclone( $State->{Indexes}->{ $Param{ArticleID} } ) };
    }

    return $Param{Fetch}->();
}

1;
