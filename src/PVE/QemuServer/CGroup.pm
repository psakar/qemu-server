package PVE::QemuServer::CGroup;

use strict;
use warnings;

use PVE::InitSystem;
use base('PVE::CGroup');

sub get_subdir {
    my ($self, $controller, $limiting) = @_;
    my $vmid = $self->{vmid};
    return "qemu.slice/$vmid.scope/";
}

sub scope {
    my ($self) = @_;
    return $self->{vmid} . '.scope';
}

# Update the 'cpulimit' of VM.
# Note that this is the init system's scope API and we expect a value for
# `CPUQuota` (percent of one CPU) as set on VM startup, rather than cgroup
# values. undef removes the limit.
sub change_cpu_quota {
    my ($self, $quota, $period) = @_;

    die "period is not controlled for VMs\n" if defined($period);

    PVE::InitSystem::set_scope_properties($self->scope(), CPUQuota => $quota);

    return;
}

# Update the 'cpuunits' of a VM.
# Note that this is the init system's scope API and we expect a value for
# `CPUWeight`/`CPUShares` as set on VM startup, rather than cgroup values. undef
# resets it to the default.
sub change_cpu_shares {
    my ($self, $shares) = @_;

    my $property = PVE::CGroup::cgroup_mode() == 2 ? 'CPUWeight' : 'CPUShares';
    PVE::InitSystem::set_scope_properties($self->scope(), $property => $shares);

    return;
}

1;
