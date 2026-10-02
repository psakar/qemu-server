package PVE::QemuServer::DBusVMState;

use strict;
use warnings;

use IO::Select;
use IO::Socket::UNIX;
use Net::DBus;
use Net::DBus::RemoteService;
use POSIX ();
use Socket qw(SOCK_DGRAM);
use Time::HiRes qw(time);

use PVE::InitSystem;
use PVE::SafeSyslog;
use PVE::Systemd;
use PVE::Tools;

use PVE::QemuServer::Helpers;

use constant {
    DBUS_VMSTATE_EXE => '/usr/libexec/qemu-server/dbus-vmstate',
    # how long to wait for the helper to be ready when starting it directly
    DBUS_VMSTATE_START_TIMEOUT => 30,
};

# Call a method for an object from a specific interface name.
# In contrast to calling the method directly by using $obj->Method(), this
# actually respects the owner of the object and thus can be used for interfaces
# with might have multiple (queued) owners on the DBus.
my sub dbus_call_method {
    my ($obj, $interface, $method, $params, $timeout) = @_;

    $timeout = 10 if !$timeout;

    my $con = $obj->{service}->get_bus()->get_connection();

    my $call = $con->make_method_call_message(
        $obj->{service}->get_service_name(),
        $obj->{object_path},
        $interface,
        $method,
    );

    $call->set_destination($obj->get_service()->get_owner_name());
    $call->append_args_list($params->@*) if $params;

    return $con->send_with_reply_and_block($call, $timeout * 1000)->get_args_list();
}

# Retrieves a property from an object from a specific interface name.
# In contrast to accessing the property directly by using $obj->Property, this
# actually respects the owner of the object and thus can be used for interfaces
# with might have multiple (queued) owners on the DBus.
my sub dbus_get_property {
    my ($obj, $interface, $name) = @_;

    my @reply =
        dbus_call_method($obj, 'org.freedesktop.DBus.Properties', 'Get', [$interface, $name]);
    return $reply[0];
}

# Starts the dbus-vmstate helper D-Bus service daemon and adds the needed
# object to the appropriate QEMU instance for the specified VM.
sub qemu_add_dbus_vmstate {
    my ($vmid) = @_;

    if (!PVE::QemuServer::Helpers::vm_running_locally($vmid)) {
        die "VM $vmid must be running locally\n";
    }

    # In case some leftover, previous instance is running, stop it. Otherwise
    # we run into errors, as a systemd service instance is unique.
    if (defined(qemu_del_dbus_vmstate($vmid, quiet => 1))) {
        warn "stopped previously running dbus-vmstate helper for VM $vmid\n";
    }

    # Start the actual service, which will then register itself with QEMU. Init systems
    # without the pve-dbus-vmstate@ template service (e.g. sysvinit or OpenRC, see the
    # pkg.qemu-server.lsbservice build profile) get the helper started directly.
    my $service = "pve-dbus-vmstate\@$vmid";
    eval {
        if (PVE::InitSystem::service_status($service)->{load_state} ne 'not-found') {
            PVE::InitSystem::start_service($service);
        } else {
            start_dbus_vmstate_helper($vmid);
        }
    };
    if (my $err = $@) {
        die "failed to start DBus VMState service for VM $vmid: $err\n";
    }
}

# Start the dbus-vmstate helper without the pve-dbus-vmstate@ service, like the service
# would: in its own scope in qemu.slice, and returning only once it reported to be ready
# (Type=notify), which it does via PVE::Systemd::notify to the NOTIFY_SOCKET we provide.
sub start_dbus_vmstate_helper {
    my ($vmid) = @_;

    my $scope = "pve-dbus-vmstate-$vmid";
    my $notify_path = "/run/qemu-server/dbus-vmstate-$vmid.notify";

    unlink($notify_path);
    my $notify = IO::Socket::UNIX->new(Type => SOCK_DGRAM, Local => $notify_path)
        or die "unable to create notify socket '$notify_path' - $!\n";

    # double fork, so that the helper doesn't stay our child
    my $pid = fork() // die "fork failed - $!\n";
    if (!$pid) {
        eval {
            POSIX::setsid();
            my $helper = fork() // die "fork failed - $!\n";
            POSIX::_exit(0) if $helper;

            PVE::InitSystem::enter_systemd_scope(
                $scope,
                "PVE DBus VMState Helper (VM $vmid)",
                Slice => 'qemu.slice',
            );
            open(STDIN, '<', '/dev/null');
            open(STDOUT, '>', '/dev/null');
            open(STDERR, '>&', \*STDOUT);
            $ENV{NOTIFY_SOCKET} = $notify_path;
            exec(DBUS_VMSTATE_EXE, $vmid) or die "exec failed - $!\n";
        };
        syslog('err', "starting dbus-vmstate helper for VM $vmid failed: $@") if $@;
        POSIX::_exit(1);
    }
    waitpid($pid, 0);

    my $select = IO::Select->new($notify);
    my $deadline = time() + DBUS_VMSTATE_START_TIMEOUT;
    my $ready = 0;
    my $seen_running = 0;
    while (!$ready && time() < $deadline) {
        if ($select->can_read(0.2)) {
            $notify->recv(my $msg, 4096);
            $ready = 1 if $msg =~ m/^READY=1$/m;
            next;
        }
        # fail early if the helper exited without getting ready
        my $running = PVE::InitSystem::is_unit_active("$scope.scope");
        $seen_running ||= $running;
        last if $seen_running && !$running;
    }

    close($notify);
    unlink($notify_path);

    if (!$ready) {
        eval { PVE::InitSystem::stop_scope("$scope.scope") };
        die "dbus-vmstate helper did not get ready\n";
    }

    return;
}

# Stops the dbus-vmstate helper D-Bus service daemon and removes the associated
# object from QEMU for the specified VM.
#
# Returns the number of migrated conntrack entries, or undef in case of error.
sub qemu_del_dbus_vmstate {
    my ($vmid, %params) = @_;

    my $num_entries = undef;
    my $dbus = eval { Net::DBus->system(); };
    if (my $err = $@) {
        # log fundamental error even if $params{quiet} is set
        syslog('warn', "failed to connect to DBus system bus: $err");
        return undef;
    }

    my $dbus_obj = eval { $dbus->get_bus_object(); };
    if (my $err = $@) {
        # log fundamental error even if $params{quiet} is set
        syslog('warn', "failed to get DBus bus object: $err");
        return undef;
    }

    my $owners = eval { $dbus_obj->ListQueuedOwners('org.qemu.VMState1') };
    if (my $err = $@) {
        syslog('warn', "failed to retrieve org.qemu.VMState1 owners: $err\n")
            if !$params{quiet};
        return undef;
    }

    # Iterate through all name owners for 'org.qemu.VMState1' and compare
    # the ID. If we found the corresponding one for $vmid, retrieve the
    # `NumMigratedEntries` property and call the `Quit()` method on it.
    # Any D-Bus interaction might die/croak, so try to be careful here and
    # swallow any hard errors.
    foreach my $owner (@$owners) {
        my $service = eval { Net::DBus::RemoteService->new($dbus, $owner, 'org.qemu.VMState1') };
        if (my $err = $@) {
            syslog('warn', "failed to get org.qemu.VMState1 service from D-Bus $owner: $err\n")
                if !$params{quiet};
            next;
        }

        my $object = eval { $service->get_object('/org/qemu/VMState1') };
        if (my $err = $@) {
            syslog('warn', "failed to get /org/qemu/VMState1 object from D-Bus $owner: $err\n")
                if !$params{quiet};
            next;
        }

        my $id = eval { dbus_get_property($object, 'org.qemu.VMState1', 'Id') };
        if (defined($id) && $id eq "pve-vmstate-$vmid") {
            my $helperobj =
                eval { $service->get_object('/org/qemu/VMState1', 'com.proxmox.VMStateHelper') };
            if (my $err = $@) {
                syslog(
                    'warn',
                    "found dbus-vmstate helper, but does not implement com.proxmox.VMStateHelper? ($err)\n",
                ) if !$params{quiet};
                last;
            }

            $num_entries = eval {
                dbus_get_property($object, 'com.proxmox.VMStateHelper', 'NumMigratedEntries');
            };
            # Quit() does QMP object-del which has a timeout of 60 seconds
            eval { dbus_call_method($object, 'com.proxmox.VMStateHelper', 'Quit', [], 70); };
            if (my $err = $@) {
                syslog('warn', "failed to call quit on dbus-vmstate for VM $vmid: $err\n")
                    if !$params{quiet};
            }

            last;
        }
    }

    return $num_entries;
}

1;
