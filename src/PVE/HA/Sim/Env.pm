package PVE::HA::Sim::Env;

use strict;
use warnings;
use POSIX qw(strftime EINTR);
use Data::Dumper;
use JSON;
use IO::File;
use Fcntl qw(:DEFAULT :flock);

use PVE::HA::Tools;
use PVE::HA::Env;
use PVE::HA::Resources;
use PVE::HA::Sim::Resources::VirtVM;
use PVE::HA::Sim::Resources::VirtCT;
use PVE::HA::Sim::Resources::VirtFail;

PVE::HA::Sim::Resources::VirtVM->register();
PVE::HA::Sim::Resources::VirtCT->register();
PVE::HA::Sim::Resources::VirtFail->register();

PVE::HA::Resources->init();

sub new {
    my ($this, $nodename, $hardware, $log_id) = @_;

    die "missing nodename" if !$nodename;
    die "missing log_id" if !$log_id;

    my $class = ref($this) || $this;

    my $self = bless {}, $class;

    $self->{statusdir} = $hardware->statusdir();
    $self->{nodename} = $nodename;

    $self->{hardware} = $hardware;
    $self->{lock_timeout} = 120;

    $self->{log_id} = $log_id;

    return $self;
}

sub nodename {
    my ($self) = @_;

    return $self->{nodename};
}

sub hardware {
    my ($self) = @_;

    return $self->{hardware};
}

sub sim_get_lock {
    my ($self, $lock_name, $unlock) = @_;

    return 0 if !$self->quorate();

    my $filename = "$self->{statusdir}/cluster_locks";

    my $code = sub {

	my $data = PVE::HA::Tools::read_json_from_file($filename, {});

	my $res;

	my $nodename = $self->nodename();
	my $ctime = $self->get_time();

	if ($unlock) {

	    if (my $d = $data->{$lock_name}) {
		my $tdiff = $ctime - $d->{time};

		if ($tdiff > $self->{lock_timeout}) {
		    $res = 1;
		} elsif (($tdiff <= $self->{lock_timeout}) && ($d->{node} eq $nodename)) {
		    delete $data->{$lock_name};
		    $res = 1;
		} else {
		    $res = 0;
		}
	    }

	} else {

	    if (my $d = $data->{$lock_name}) {

		my $tdiff = $ctime - $d->{time};

		if ($tdiff <= $self->{lock_timeout}) {
		    if ($d->{node} eq $nodename) {
			$d->{time} = $ctime;
			$res = 1;
		    } else {
			$res = 0;
		    }
		} else {
		    $self->log('info', "got lock '$lock_name'");
		    $d->{node} = $nodename;
		    $d->{time} = $ctime;
		    $res = 1;
		}

	    } else {
		$data->{$lock_name} = {
		    time => $ctime,
		    node => $nodename,
		};
		$self->log('info', "got lock '$lock_name'");
		$res = 1;
	    }
	}

	PVE::HA::Tools::write_json_to_file($filename, $data);

	return $res;
    };

    return $self->{hardware}->global_lock($code);
}

sub read_manager_status {
    my ($self) = @_;

    my $filename = "$self->{statusdir}/manager_status";

    return PVE::HA::Tools::read_json_from_file($filename, {});
}

sub write_manager_status {
    my ($self, $status_obj) = @_;

    my $filename = "$self->{statusdir}/manager_status";

    PVE::HA::Tools::write_json_to_file($filename, $status_obj);
}

sub read_lrm_status {
    my ($self, $node) = @_;

    $node = $self->{nodename} if !defined($node);

    return $self->{hardware}->read_lrm_status($node);
}

sub write_lrm_status {
    my ($self, $status_obj) = @_;

    my $node = $self->{nodename};

    return $self->{hardware}->write_lrm_status($node, $status_obj);
}

sub is_node_shutdown {
    my ($self) = @_;

    return 0; # default to freezing services if not overwritten by subclass
}

sub read_service_config {
    my ($self) = @_;

    return $self->{hardware}->read_service_config();
}

sub read_fence_config {
    my ($self) = @_;

    return $self->{hardware}->read_fence_config();
}

# the test/sim framework has hardware enabled fencing if
# it has devices configured
sub fencing_mode {
    my ($self) = @_;

    my $cfg = $self->read_fence_config();

    return (defined($cfg) && keys %{$cfg}) ? 'hardware' : 'watchdog';
}

sub exec_fence_agent {
    my ($self, $agent, $node, @param) = @_;

    return $self->{hardware}->exec_fence_agent($agent, $node, @param);
}

sub read_group_config {
    my ($self) = @_;

    return $self->{hardware}->read_group_config();
}

# this is normally only allowed by the master to recover a _fenced_ service
sub steal_service {
    my ($self, $sid, $current_node, $new_node) = @_;

    return $self->{hardware}->change_service_location($sid, $current_node, $new_node);
}

sub queue_crm_commands {
    my ($self, $cmd) = @_;

    return $self->{hardware}->queue_crm_commands($cmd);
}

sub read_crm_commands {
    my ($self) = @_;

    return $self->{hardware}->read_crm_commands();
}

sub log {
    my ($self, $level, $msg) = @_;

    chomp $msg;

    my $time = $self->get_time();

    printf("%-5s %5d %12s: $msg\n", $level, $time, "$self->{nodename}/$self->{log_id}");
}

sub sendmail {
    my ($self, $subject, $text) = @_;

    # only log subject, not spam the regression logs
    $self->log('email', $subject);
}

sub get_time {
    my ($self) = @_;

    die "implement in subclass";
}

sub sleep {
   my ($self, $delay) = @_;

   die "implement in subclass";
}

sub sleep_until {
   my ($self, $end_time) = @_;

   die "implement in subclass";
}

sub get_ha_manager_lock {
    my ($self) = @_;

    return $self->sim_get_lock('ha_manager_lock');
}

# release the cluster wide manager lock.
# when released another CRM may step up and get the lock, thus this should only
# get called when shutting down/deactivating the current master
sub release_ha_manager_lock {
    my ($self) = @_;

    return $self->sim_get_lock('ha_manager_lock', 1);
}

sub get_ha_agent_lock_name {
    my ($self, $node) = @_;

    $node = $self->nodename() if !$node;

    return "ha_agent_${node}_lock";
}

sub get_ha_agent_lock {
    my ($self, $node) = @_;

    my $lck = $self->get_ha_agent_lock_name($node);
    return $self->sim_get_lock($lck);
}


# release the respective node agent lock.
# this should only get called if the nodes LRM gracefully shuts down with
# all services already cleanly stopped!
sub release_ha_agent_lock {
    my ($self) = @_;

    my $node = $self->nodename();

    my $lock = $self->get_ha_agent_lock_name($node);
    return $self->sim_get_lock($lock, 1);
}

# return true when cluster is quorate
sub quorate {
    my ($self) = @_;

    my ($node_info, $quorate) = $self->{hardware}->get_node_info();
    my $node = $self->nodename();
    return 0 if !$node_info->{$node}->{online};
    return $quorate;
}

sub get_node_info {
    my ($self) = @_;

    return $self->{hardware}->get_node_info();
}

sub loop_start_hook {
    my ($self, $starttime) = @_;

    # do nothing, overwrite in subclass
}

sub loop_end_hook {
    my ($self) = @_;

    # do nothing, overwrite in subclass
}

sub watchdog_open {
    my ($self) = @_;

    my $node = $self->nodename();

    return $self->{hardware}->watchdog_open($node);
}

sub watchdog_update {
    my ($self, $wfh) = @_;

    return $self->{hardware}->watchdog_update($wfh);
}

sub watchdog_close {
    my ($self, $wfh) = @_;

    return $self->{hardware}->watchdog_close($wfh);
}

sub after_fork {
    my ($self) = @_;

    # nothing to clean up in the simulation environment
}


sub get_max_workers {
    my ($self) = @_;

    return 4;
}

1;
