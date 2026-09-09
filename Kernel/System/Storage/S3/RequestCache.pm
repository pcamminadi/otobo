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

package Kernel::System::Storage::S3::RequestCache;

use v5.24;
use strict;
use warnings;

# core modules
use Fcntl     qw(:flock);
use File::Temp qw(tempfile);
use JSON::PP   ();
use Time::HiRes ();

sub Listing {
    my ( $Class, %Param ) = @_;

    my $Lock;
    if ( open $Lock, '>>', "$Param{Path}.lock" ) {
        if ( flock $Lock, LOCK_SH | LOCK_NB ) {
            my $Value = $Class->_ListingRead( Path => $Param{Path} );
            close $Lock;

            return $Value if defined $Value;
        }
        else {
            close $Lock;
        }
    }

    # Never retain a local lock while the callback performs S3/network I/O.
    my $Value = $Param{Fetch}->();
    return if !defined $Value;

    return $Value if !open $Lock, '>>', "$Param{Path}.lock";
    return $Value if !flock $Lock, LOCK_EX | LOCK_NB;

    my ( $Filehandle, $TemporaryPath ) = tempfile(
        '.otobo-s3-list-XXXXXX',
        DIR    => $Param{Path} =~ s{/[^/]+\z}{}r,
        UNLINK => 0,
    );
    print {$Filehandle} JSON::PP::encode_json(
        {
            Expires => Time::HiRes::time() + 2,
            Value   => $Value,
        }
    );
    close $Filehandle;
    rename $TemporaryPath, $Param{Path} or unlink $TemporaryPath;
    close $Lock;

    return $Value;
}

sub _ListingRead {
    my ( $Class, %Param ) = @_;

    open my $Filehandle, '<', $Param{Path} or return;
    local $/;
    my $Data = eval { JSON::PP::decode_json(<$Filehandle>) };
    close $Filehandle;

    return if ref $Data ne 'HASH';
    return if ref $Data->{Value} ne 'HASH';

    my $Now = Time::HiRes::time();
    return if ( $Data->{Expires} // 0 ) <= $Now;
    return if $Data->{Expires} > $Now + 2;

    return $Data->{Value};
}

sub InvalidateListing {
    my ( $Class, %Param ) = @_;

    open my $Lock, '>>', "$Param{Path}.lock" or return;
    flock $Lock, LOCK_EX | LOCK_NB or return;
    unlink $Param{Path};
    close $Lock;

    return 1;
}

sub Exists {
    my ( $Class, %Param ) = @_;

    return 1 if $Param{CacheObject}->Get(
        Type          => 'Loader',
        Key           => $Param{Key},
        CacheInMemory => 0,
    );

    my $Exists = $Param{Fetch}->();
    if ($Exists) {
        $Param{CacheObject}->Set(
            Type          => 'Loader',
            Key           => $Param{Key},
            Value         => 1,
            TTL           => 300,
            CacheInMemory => 0,
        );
    }

    return $Exists;
}

1;
