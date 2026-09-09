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

# core modules
use File::Temp qw(tempdir);

# CPAN modules
use Mojo::Transaction::HTTP;
use Test2::V0;

# OTOBO modules
use Kernel::System::Storage::S3;

{
    package Local::UserAgent;

    sub start {
        return $_[1];
    }
}

{
    package Local::S3;

    sub signed_request {
        return $_[0]->{Transaction};
    }
}

{
    package Local::Log;

    sub Log {
        my ( $Self, %Param ) = @_;

        push @{ $Self->{Messages} }, $Param{Message};

        return;
    }
}

{
    package Local::ObjectManager;

    sub Get {
        return $_[0]->{LogObject};
    }
}

my $LogObject = bless { Messages => [] }, 'Local::Log';
$Kernel::OM = bless { LogObject => $LogObject }, 'Local::ObjectManager';

sub StorageObjectCreate {
    my (%Param) = @_;

    my $Transaction = Mojo::Transaction::HTTP->new();
    $Transaction->res->code( $Param{Code} );
    $Transaction->res->body( $Param{Body} // '' );
    $Transaction->res->headers->content_length( $Param{ContentLength} )
        if defined $Param{ContentLength};
    $Transaction->res->headers->last_modified( $Param{LastModified} )
        if $Param{LastModified};

    return bless {
        Bucket     => 'bucket',
        HomePrefix => 'OTOBO',
        Host       => 'localhost',
        S3Object   => bless( { Transaction => $Transaction }, 'Local::S3' ),
        Scheme     => 'http',
        UserAgent  => bless( {}, 'Local::UserAgent' ),
    }, 'Kernel::System::Storage::S3';
}

sub FileContentGet {
    my ($Location) = @_;

    open my $Filehandle, '<', $Location or die "Could not open $Location: $!";
    local $/;
    my $Content = <$Filehandle>;
    close $Filehandle;

    return $Content;
}

my $TempDirectory = tempdir( CLEANUP => 1 );
my $Location      = "$TempDirectory/object.txt";

my $StorageObject = StorageObjectCreate(
    Code           => 200,
    Body           => 'complete object',
    ContentLength  => 15,
    LastModified   => 'Sat, 23 Oct 2021 11:15:14 GMT',
);
ok(
    $StorageObject->SaveObjectToFile(
        Key      => 'object.txt',
        Location => $Location,
    ),
    'a complete object is saved',
);
ok( -e $Location, 'the completed object is published at the final location' );
is( FileContentGet($Location), 'complete object', 'the published content is complete' );
is( [ glob "$TempDirectory/.otobo-s3-download-*" ], [], 'temporary downloads are removed after publication' );

$StorageObject = StorageObjectCreate(
    Code          => 200,
    Body          => 'short',
    ContentLength => 10,
);
ok(
    !$StorageObject->SaveObjectToFile(
        Key      => 'short.txt',
        Location => "$TempDirectory/short.txt",
    ),
    'a size mismatch fails the download',
);
ok( !-e "$TempDirectory/short.txt", 'an incomplete final file is not published' );
is( [ glob "$TempDirectory/.otobo-s3-download-*" ], [], 'failed temporary downloads are removed' );

$StorageObject = StorageObjectCreate(
    Code => 503,
    Body => '<not-xml>',
);
is(
    { $StorageObject->ListObjects( Prefix => 'Kernel/Config/Files/' ) },
    {},
    'an unsuccessful listing response is rejected before XML parsing',
);
like( $LogObject->{Messages}->[-1], qr{<not-xml>}, 'the failed listing response is logged' );

done_testing();
