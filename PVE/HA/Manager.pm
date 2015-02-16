package PVE::HA::Manager;

use strict;
use warnings;
use Digest::MD5 qw(md5_base64);

use Data::Dumper;

use PVE::HA::NodeStatus;

sub new {
    my ($this, $haenv) = @_;

    my $class = ref($this) || $this;

    my $ms = $haenv->read_manager_status();

    $ms->{master_node} = $haenv->nodename();

    my $ns = PVE::HA::NodeStatus->new($haenv, $ms->{node_status} || {});

    # fixme: use separate class  PVE::HA::ServiceStatus
    my $ss = $ms->{service_status} || {};

    my $self = bless {
	haenv => $haenv,
	ms => $ms, # master status
	ns => $ns, # PVE::HA::NodeStatus
	ss => $ss, # service status
    }, $class;

    return $self;
}

sub cleanup {
    my ($self) = @_;

    # todo: ?
}

sub flush_master_status {
    my ($self) = @_;

    my ($haenv, $ms, $ns, $ss) = ($self->{haenv}, $self->{ms}, $self->{ns}, $self->{ss});

    $ms->{node_status} = $ns->{status};
    $ms->{service_status} = $ss;

    $haenv->write_manager_status($ms);
} 

# Attention: must be idempotent (alway return the same result for same input!)
sub select_service_node {
    my ($self, $service_conf) = @_;

    my $ns = $self->{ns};
    
    my $pref_node = $service_conf->{node};

    return $pref_node if $ns->node_is_online($pref_node);

    my $online_nodes = $ns->list_online_nodes();

    return shift @$online_nodes;
}

my $uid_counter = 0;

my $valid_service_states = {
    stopped => 1,
    request_stop => 1,
    started => 1,
    fence => 1,
    migrate => 1,
    error => 1,
};

my $change_service_state = sub {
    my ($self, $sid, $new_state, %params) = @_;

    my ($haenv, $ss) = ($self->{haenv}, $self->{ss});

    my $sd = $ss->{$sid} || die "no such service '$sid";

    my $old_state = $sd->{state};
    my $old_node = $sd->{node};

    die "no state change" if $old_state eq $new_state; # just to be sure

    die "invalid CRM service state '$new_state'\n" if !$valid_service_states->{$new_state};

    foreach my $k (keys %$sd) { delete $sd->{$k}; };

    $sd->{state} = $new_state;
    $sd->{node} = $old_node;

    my $text_state = '';
    foreach my $k (keys %params) {
	my $v = $params{$k};
	$text_state .= ", " if $text_state;
	$text_state .= "$k = $v";
	$sd->{$k} = $v;
    }
    
    $uid_counter++;
    $sd->{uid} = md5_base64($new_state . $$ . time() . $uid_counter);

    $text_state = " ($text_state)" if $text_state;
    $haenv->log('info', "service '$sid': state changed from '${old_state}' to '${new_state}' $text_state\n");
};

# read LRM status for all active nodes 
sub read_lrm_status {
    my ($self) = @_;

    my $nodes = $self->{ns}->list_online_nodes();
    my $haenv = $self->{haenv};

    my $res = {};

    foreach my $node (@$nodes) {
	my $ls = $haenv->read_lrm_status($node);
	foreach my $uid (keys %$ls) {
	    next if $res->{$uid}; # should not happen
	    $res->{$uid} = $ls->{$uid};
	}
    }

    return $res;
}

# read new crm commands and save them into crm master status
sub update_crm_commands {
    my ($self) = @_;

    my ($haenv, $ms, $ns, $ss) = ($self->{haenv}, $self->{ms}, $self->{ns}, $self->{ss});

    my $cmdlist = $haenv->read_crm_commands();
    
    foreach my $cmd (split(/\n/, $cmdlist)) {
	chomp $cmd;

	if ($cmd =~ m/^migrate\s+(\S+)\s+(\S+)$/) {
	    my ($sid, $node) = ($1, $2); 
	    if (my $sd = $ss->{$sid}) {
		if (!$ns->node_is_online($node)) {
		    $haenv->log('err', "crm command error - node not online: $cmd");
		} else {
		    if ($node eq $sd->{node}) {
			$haenv->log('info', "ignore crm command - service already on target node: $cmd");
		    } else { 
			$haenv->log('info', "got crm command: $cmd");
			$ss->{$sid}->{cmd} = [ 'migrate', $node];
		    }
		}
	    } else {
		$haenv->log('err', "crm command error - no such service: $cmd");
	    }

	} else {
	    $haenv->log('err', "unable to parse crm command: $cmd");
	}
    }

}

sub manage {
    my ($self) = @_;

    my ($haenv, $ms, $ns, $ss) = ($self->{haenv}, $self->{ms}, $self->{ns}, $self->{ss});

    $ns->update($haenv->get_node_info());

    if (!$ns->node_is_online($haenv->nodename())) {
	$haenv->log('info', "master seems offline\n");
	return;
    }

    my $lrm_status = $self->read_lrm_status();

    my $sc = $haenv->read_service_config();

    # compute new service status

    # add new service
    foreach my $sid (keys %$sc) {
	next if $ss->{$sid}; # already there
	$haenv->log('info', "Adding new service '$sid'\n");
	# assume we are running to avoid relocate running service at add
	$ss->{$sid} = { state => 'started', node => $sc->{$sid}->{node}};
    }

    $self->update_crm_commands();

    for (;;) {
	my $repeat = 0;

	foreach my $sid (keys %$ss) {
	    my $sd = $ss->{$sid};
	    my $cd = $sc->{$sid} || { state => 'disabled' };

	    my $lrm_res = $sd->{uid} ? $lrm_status->{$sd->{uid}} : undef;

	    my $last_state = $sd->{state};

	    if ($last_state eq 'stopped') {

		$self->next_state_stopped($sid, $cd, $sd);

	    } elsif ($last_state eq 'started') {

		$self->next_state_started($sid, $cd, $sd);

	    } elsif ($last_state eq 'migrate') {

		# check result from LRM daemon
		if ($lrm_res) {
		    my $exit_code = $lrm_res->{exit_code};
		    if ($exit_code == 0) {
			&$change_service_state($self, $sid, 'started', node => $sd->{target});
		    } else {
			$haenv->log('err', "service '$sid' - migration failed (exit code $exit_code)");
			&$change_service_state($self, $sid, 'started', node => $sd->{node});
		    }
		}

	    } elsif ($last_state eq 'fence') {

		# do nothing here - wait until fenced

	    } elsif ($last_state eq 'request_stop') {

		# check result from LRM daemon
		if ($lrm_res) {
		    my $exit_code = $lrm_res->{exit_code};
		    if ($exit_code == 0) {
			&$change_service_state($self, $sid, 'stopped');
		    } else {
			&$change_service_state($self, $sid, 'error'); # fixme: what state?
		    }
		}

	    } elsif ($last_state eq 'error') {

		# fixme: 

	    } else {

		die "unknown service state '$last_state'";
	    }

	    $repeat = 1 if $sd->{state} ne $last_state;
	}

	# handle fencing
	my $fenced_nodes = {};
	foreach my $sid (keys %$ss) {
	    my $sd = $ss->{$sid};
	    next if $sd->{state} ne 'fence';

	    if (!defined($fenced_nodes->{$sd->{node}})) {
		$fenced_nodes->{$sd->{node}} = $ns->fence_node($sd->{node}) || 0;
	    }

	    next if !$fenced_nodes->{$sd->{node}};

	    # node fence was sucessful - mark service as stopped
	    &$change_service_state($self, $sid, 'stopped');	    
	}

	last if !$repeat;
    }

    # remove stale services
    # fixme:

    $self->flush_master_status();
}

# functions to compute next service states
# $cd: service configuration data (read only)
# $sd: service status data (read only)
#
# Note: use change_service_state() to alter state
#

sub next_state_stopped {
    my ($self, $sid, $cd, $sd) = @_;

    my $haenv = $self->{haenv};
    my $ns = $self->{ns};

    if ($sd->{node} ne $cd->{node}) {
	# this can happen if we fence a node with active migrations
	# hack: modify $sd (normally this should be considered read-only)
	$haenv->log('info', "fixup service '$sid' location ($sd->{node} => $cd->{node}");
	$sd->{node} = $cd->{node}; 
    }

    if ($sd->{cmd}) {
	my ($cmd, $target) = @{$sd->{cmd}};
	delete $sd->{cmd};

	if ($cmd eq 'migrate') {
	    if (!$ns->node_is_online($target)) {
		$haenv->log('err', "ignore service '$sid' migrate request - node '$target' not online");
	    } elsif ($sd->{node} eq $target) {
		$haenv->log('info', "ignore service '$sid' migrate request - service already on node '$target'");
	    } else {
		$haenv->change_service_location($sid, $target);
		$cd->{node} = $sd->{node} = $target; # fixme: $sd is read-only??!!	    
		$haenv->log('info', "migrate service '$sid' to node '$target' (stopped)");
	    }
	} else {
	    $haenv->log('err', "unknown command '$cmd' for service '$sid'"); 
	}
    } 

    if ($cd->{state} eq 'disabled') {
	# do nothing
	return;
    } 

    if ($cd->{state} eq 'enabled') {
	if (my $node = $self->select_service_node($cd)) {
	    if ($node && ($sd->{node} ne $node)) {
		$haenv->change_service_location($sid, $node);
	    }
	    &$change_service_state($self, $sid, 'started', node => $node);
	} else {
	    # fixme: warn 
	}

	return;
    }

    $haenv->log('err', "service '$sid' - unknown state '$cd->{state}' in service configuration");
}

sub next_state_started {
    my ($self, $sid, $cd, $sd) = @_;

    my $haenv = $self->{haenv};
    my $ns = $self->{ns};

    if (!$ns->node_is_online($sd->{node})) {

	&$change_service_state($self, $sid, 'fence');
	return;
    }
	
    if ($cd->{state} eq 'disabled') {
	&$change_service_state($self, $sid, 'request_stop');
	return;
    }

    if ($cd->{state} eq 'enabled') {
	my $node = $self->select_service_node($cd);

	if ($sd->{cmd}) {
	    my ($cmd, $target) = @{$sd->{cmd}};
	    delete $sd->{cmd};

	    if ($cmd eq 'migrate') {
		if (!$ns->node_is_online($target)) {
		    $haenv->log('err', "ignore service '$sid' migrate request - node '$target' not online");
		} elsif ($sd->{node} eq $target) {
		    $haenv->log('info', "ignore service '$sid' migrate request - service already on node '$target'");
		} else {
		    $node = $target;
		}
	    } else {
		$haenv->log('err', "unknown command '$cmd' for service '$sid'"); 
	    }
	}

	if ($node && ($sd->{node} ne $node)) {
	    $haenv->log('info', "migrate service '$sid' to node '$node' (running)");
	    &$change_service_state($self, $sid, 'migrate', node => $sd->{node}, target => $node);
	} else {
	    # do nothing
	}

	return;
    } 

    $haenv->log('err', "service '$sid' - unknown state '$cd->{state}' in service configuration");
}

1;
