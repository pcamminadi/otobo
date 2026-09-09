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
use Test2::V0;

# OTOBO modules
use Kernel::System::Storage::S3::RequestCache;

my $Class = 'Kernel::System::Storage::S3::RequestCache';
my $Directory = tempdir( CLEANUP => 1 );
my $Path      = "$Directory/list.json";
my $Clock     = 100;
my $Calls     = 0;

no warnings 'redefine';
local *Time::HiRes::time = sub { return $Clock };

my $Fetch = sub {
    $Calls++;

    return { config => { Mtime => $Clock } };
};

is( $Class->Listing( Path => $Path, Fetch => $Fetch )->{config}->{Mtime}, 100, 'initial listing is fetched' );
$Clock = 101;
is( $Class->Listing( Path => $Path, Fetch => $Fetch )->{config}->{Mtime}, 100, 'listing is reused within two seconds' );
is( $Calls, 1, 'a cache hit avoids a second remote call' );
$Clock = 102;
is( $Class->Listing( Path => $Path, Fetch => $Fetch )->{config}->{Mtime}, 102, 'listing expires after two seconds' );

$Class->InvalidateListing( Path => $Path );
$Clock = 102.1;
is( $Class->Listing( Path => $Path, Fetch => $Fetch )->{config}->{Mtime}, 102.1, 'invalidation is immediate' );

$Class->InvalidateListing( Path => $Path );
my $Failures = 0;
for ( 1 .. 2 ) {
    ok(
        !defined $Class->Listing(
            Path  => $Path,
            Fetch => sub {
                $Failures++;
                return;
            },
        ),
        'failed listing is returned',
    );
}
is( $Failures, 2, 'failed listings are not cached' );

open my $Filehandle, '>', $Path or die "Could not write corrupt cache: $!";
print {$Filehandle} 'invalid-json';
close $Filehandle;
is( $Class->Listing( Path => $Path, Fetch => $Fetch )->{config}->{Mtime}, 102.1, 'corrupt cache data is replaced' );

{
    package Local::Cache;

    sub Get {
        my ( $Self, %Param ) = @_;

        die 'in-memory cache is not allowed' if $Param{CacheInMemory};

        return $Self->{ $Param{Type} }->{ $Param{Key} };
    }

    sub Set {
        my ( $Self, %Param ) = @_;

        die 'unexpected TTL' if $Param{TTL} != 300;
        $Self->{ $Param{Type} }->{ $Param{Key} } = $Param{Value};

        return 1;
    }
}

my $CacheObject = bless {}, 'Local::Cache';
my $HeadCalls   = 0;
for ( 1 .. 2 ) {
    ok(
        $Class->Exists(
            CacheObject => $CacheObject,
            Key         => 'scope:key',
            Fetch       => sub {
                $HeadCalls++;
                return 1;
            },
        ),
        'existing object is reported',
    );
}
is( $HeadCalls, 1, 'positive existence result is cached' );

for ( 1 .. 2 ) {
    ok(
        !$Class->Exists(
            CacheObject => $CacheObject,
            Key         => 'missing',
            Fetch       => sub {
                $HeadCalls++;
                return 0;
            },
        ),
        'missing object is reported',
    );
}
is( $HeadCalls, 3, 'negative existence results are not cached' );

$Class->InvalidateListing( Path => $Path );
local $SIG{ALRM} = sub { die 'reentrant listing deadlocked' };
alarm 3;
my $Nested = $Class->Listing(
    Path  => $Path,
    Fetch => sub {
        $Class->InvalidateListing( Path => $Path );

        return $Class->Listing(
            Path  => $Path,
            Fetch => sub { return { nested => 1 } },
        );
    },
);
alarm 0;
is( $Nested, { nested => 1 }, 'network callbacks can reenter cache operations without deadlock' );

done_testing();
