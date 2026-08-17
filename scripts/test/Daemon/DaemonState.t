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
use Kernel::System::Daemon::DaemonState;
use Kernel::System::Cache;

{
    package Local::Config;

    sub new {
        my ( $Class, %Values ) = @_;

        return bless \%Values, $Class;
    }

    sub Get {
        my ( $Self, $Key ) = @_;

        return $Self->{$Key};
    }

    sub Set {
        my ( $Self, $Key, $Value ) = @_;

        $Self->{$Key} = $Value;

        return 1;
    }
}

{
    package Local::Cache;

    sub new {
        my ($Class) = @_;

        return bless {}, $Class;
    }

    sub Get {
        my ( $Self, %Param ) = @_;

        return $Self->{ $Param{Type} }{ $Param{Key} };
    }

    sub Set {
        my ( $Self, %Param ) = @_;

        $Self->{ $Param{Type} }{ $Param{Key} } = $Param{Value};

        return 1;
    }
}

my @TestNodeIDs = ( 991, 992, 993 );

my $ConfigObject = Local::Config->new(
    NodeID                         => $TestNodeIDs[0],
    'Daemon::HealthCheck::NodeIDs' => [],
);
my $CacheObject = Local::Cache->new();

my $DaemonStateObject = bless {
    ConfigObject => $ConfigObject,
    CacheObject  => $CacheObject,
}, 'Kernel::System::Daemon::DaemonState';

$CacheObject->Set(
    Type  => 'DaemonRunning',
    Key   => $TestNodeIDs[0],
    Value => 1,
);

my %State = $DaemonStateObject->Get();
is(
    \%State,
    {
        IsRunning      => 1,
        CheckedNodeIDs => [ $TestNodeIDs[0] ],
        RunningNodeIDs => [ $TestNodeIDs[0] ],
        InvalidNodeIDs => [],
    },
    'An empty health-node list preserves the local NodeID check.',
);

$ConfigObject->Set( 'Daemon::HealthCheck::NodeIDs', [ $TestNodeIDs[1] ] );

%State = $DaemonStateObject->Get();
is(
    \%State,
    {
        IsRunning      => 0,
        CheckedNodeIDs => [ $TestNodeIDs[1] ],
        RunningNodeIDs => [],
        InvalidNodeIDs => [],
    },
    'A configured node without a heartbeat is reported as not running.',
);

$CacheObject->Set(
    Type  => 'DaemonRunning',
    Key   => $TestNodeIDs[1],
    Value => 1,
);

%State = $DaemonStateObject->Get();
is(
    \%State,
    {
        IsRunning      => 1,
        CheckedNodeIDs => [ $TestNodeIDs[1] ],
        RunningNodeIDs => [ $TestNodeIDs[1] ],
        InvalidNodeIDs => [],
    },
    'A frontend can detect a daemon heartbeat from a separately configured node.',
);

$ConfigObject->Set(
    'Daemon::HealthCheck::NodeIDs',
    [ $TestNodeIDs[2], $TestNodeIDs[1], $TestNodeIDs[1] ],
);

%State = $DaemonStateObject->Get();
is(
    \%State,
    {
        IsRunning      => 1,
        CheckedNodeIDs => [ $TestNodeIDs[2], $TestNodeIDs[1] ],
        RunningNodeIDs => [ $TestNodeIDs[1] ],
        InvalidNodeIDs => [],
    },
    'Multiple configured nodes use any-running semantics and duplicate IDs are ignored.',
);

$ConfigObject->Set(
    'Daemon::HealthCheck::NodeIDs',
    [ 0, 1000, 'abc', undef, {}, $TestNodeIDs[1] ],
);

%State = $DaemonStateObject->Get();
is(
    \%State,
    {
        IsRunning      => 1,
        CheckedNodeIDs => [ $TestNodeIDs[1] ],
        RunningNodeIDs => [ $TestNodeIDs[1] ],
        InvalidNodeIDs => [ 0, 1000, 'abc', '<undefined>', '<reference>' ],
    },
    'Invalid configured IDs are ignored and returned diagnostically.',
);

$ConfigObject->Set( 'Daemon::HealthCheck::NodeIDs', $TestNodeIDs[1] );

%State = $DaemonStateObject->Get();
is(
    \%State,
    {
        IsRunning      => 0,
        CheckedNodeIDs => [],
        RunningNodeIDs => [],
        InvalidNodeIDs => [ $TestNodeIDs[1] ],
    },
    'A malformed non-array setting fails closed instead of silently checking another node.',
);

for my $Setting ( undef, [] ) {
    $ConfigObject->Set( 'Daemon::HealthCheck::NodeIDs', $Setting );

    for my $LocalNodeID ( '01', 1000, 'legacy-node', undef, 0, '' ) {
        $ConfigObject->Set( 'NodeID', $LocalNodeID );
        my $ExpectedNodeID = $LocalNodeID || 1;
        $CacheObject->Set(
            Type  => 'DaemonRunning',
            Key   => $ExpectedNodeID,
            Value => 1,
        );

        %State = $DaemonStateObject->Get();
        is(
            \%State,
            {
                IsRunning      => 1,
                CheckedNodeIDs => [$ExpectedNodeID],
                RunningNodeIDs => [$ExpectedNodeID],
                InvalidNodeIDs => [],
            },
            'An absent or empty setting preserves the original local cache key and fallback.',
        );
    }
}

# Use the real cache wrapper to exercise its non-expiring in-memory layer.
my $Backend = Local::Cache->new();
my $LayeredCache = bless {
    CacheObject    => $Backend,
    CacheInMemory  => 1,
    CacheInBackend => 1,
}, 'Kernel::System::Cache';
$DaemonStateObject->{CacheObject} = $LayeredCache;
$ConfigObject->Set( 'Daemon::HealthCheck::NodeIDs', [993] );
$Backend->Set( Type => 'DaemonRunning', Key => 993, Value => 1 );

# Simulate a prior consumer having populated the in-memory cache.
is( $LayeredCache->Get( Type => 'DaemonRunning', Key => 993 ), 1, 'Prime in-memory heartbeat.' );
%State = $DaemonStateObject->Get();
is( $State{IsRunning}, 1, 'A live backend heartbeat is healthy.' );

# Model backend TTL expiry without a wall-clock delay.
delete $Backend->{DaemonRunning}{993};
%State = $DaemonStateObject->Get();
is( $State{IsRunning}, 0, 'An expired backend heartbeat overrides stale in-memory state.' );

$Backend->Set( Type => 'DaemonRunning', Key => 993, Value => 1 );
%State = $DaemonStateObject->Get();
is( $State{IsRunning}, 1, 'A renewed backend heartbeat becomes healthy again.' );

done_testing();
