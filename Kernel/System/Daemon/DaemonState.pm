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

package Kernel::System::Daemon::DaemonState;

use strict;
use warnings;

our @ObjectDependencies = (
    'Kernel::Config',
    'Kernel::System::Cache',
);

=head1 NAME

Kernel::System::Daemon::DaemonState - shared daemon health state

=head1 DESCRIPTION

Provides a single daemon health check for all consumers. By default, it checks
the heartbeat of the local C<NodeID>. If C<Daemon::HealthCheck::NodeIDs> is
configured, it checks those daemon nodes instead. This supports installations
where frontend and daemon processes run on separate hosts or containers.

Heartbeat checks across hosts require a shared cache backend, such as Redis.

=head1 PUBLIC INTERFACE

=head2 new()

Creates a daemon state object. Do not use it directly, instead use:

    my $DaemonStateObject = $Kernel::OM->Get('Kernel::System::Daemon::DaemonState');

=cut

sub new {
    my ( $Type, %Param ) = @_;

    my $Self = bless {}, $Type;

    $Self->{ConfigObject} = $Kernel::OM->Get('Kernel::Config');
    $Self->{CacheObject}  = $Kernel::OM->Get('Kernel::System::Cache');

    return $Self;
}

=head2 Get()

Returns the daemon health state. The daemon is considered running when any
checked node has a fresh C<DaemonRunning> heartbeat.

    my %State = $DaemonStateObject->Get();

    # %State contains:
    # IsRunning      => 1,
    # CheckedNodeIDs => [3],
    # RunningNodeIDs => [3],
    # InvalidNodeIDs => [],

Invalid configured node IDs are ignored and returned in C<InvalidNodeIDs>.
Valid node IDs are integers from 1 through 999. Duplicate IDs are checked only
once. The default local NodeID lookup is preserved without validation or
normalization for backwards compatibility.

=cut

sub Get {
    my ($Self) = @_;

    my $ConfiguredNodeIDs = $Self->{ConfigObject}->Get('Daemon::HealthCheck::NodeIDs');

    my @NodeIDs;
    my @InvalidNodeIDs;
    my @CheckedNodeIDs;

    if ( !defined $ConfiguredNodeIDs ) {
        @CheckedNodeIDs = ( $Self->{ConfigObject}->Get('NodeID') || 1 );
    }
    elsif ( ref $ConfiguredNodeIDs eq 'ARRAY' ) {
        @NodeIDs = @{$ConfiguredNodeIDs};

        if ( !@NodeIDs ) {
            @CheckedNodeIDs = ( $Self->{ConfigObject}->Get('NodeID') || 1 );
        }
    }
    else {
        @InvalidNodeIDs = ( ref $ConfiguredNodeIDs ? '<reference>' : $ConfiguredNodeIDs );
    }

    my %Seen;

    NODEID:
    for my $NodeID (@NodeIDs) {
        if (
            !defined $NodeID
            || ref $NodeID
            || $NodeID !~ m{\A[1-9][0-9]{0,2}\z}
            )
        {
            push @InvalidNodeIDs,
                !defined $NodeID ? '<undefined>'
                : ref $NodeID    ? '<reference>'
                :                  $NodeID;
            next NODEID;
        }

        next NODEID if $Seen{$NodeID}++;

        push @CheckedNodeIDs, 0 + $NodeID;
    }

    my @RunningNodeIDs;
    for my $NodeID (@CheckedNodeIDs) {
        my $Running = $Self->{CacheObject}->Get(
            Type          => 'DaemonRunning',
            Key           => $NodeID,
            CacheInMemory => 0,
        );

        push @RunningNodeIDs, $NodeID if $Running;
    }

    return (
        IsRunning      => @RunningNodeIDs ? 1 : 0,
        CheckedNodeIDs => \@CheckedNodeIDs,
        RunningNodeIDs => \@RunningNodeIDs,
        InvalidNodeIDs => \@InvalidNodeIDs,
    );
}

1;
