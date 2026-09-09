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

1;
