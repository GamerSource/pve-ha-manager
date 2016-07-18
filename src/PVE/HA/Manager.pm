package PVE::HA::Manager;

use strict;
use warnings;
use Digest::MD5 qw(md5_base64);

use Data::Dumper;
use PVE::Tools;
use PVE::HA::Tools ':exit_codes';
use PVE::HA::NodeStatus;

sub new {
    my ($this, $haenv) = @_;

    my $class = ref($this) || $this;

    my $self = bless { haenv => $haenv }, $class;

    my $old_ms = $haenv->read_manager_status();

    # we only copy the state part of the manager which cannot be auto generated

    $self->{ns} = PVE::HA::NodeStatus->new($haenv, $old_ms->{node_status} || {});

    # fixme: use separate class  PVE::HA::ServiceStatus
    $self->{ss} = $old_ms->{service_status} || {};

    $self->{ms} = { master_node => $haenv->nodename() };

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
    $ms->{timestamp} = $haenv->get_time();
    
    $haenv->write_manager_status($ms);
} 

sub select_service_node {
    my ($groups, $online_node_usage, $service_conf, $current_node, $try_next) = @_;

    my $group = {};
    # add all online nodes to default group to allow try_next when no group set
    foreach my $node (keys %$online_node_usage) {
	$group->{nodes}->{$node} = 1;
    }

    # overwrite default if service is bound to a specific group
    $group =  $groups->{ids}->{$service_conf->{group}} if $service_conf->{group} && 
	$groups->{ids}->{$service_conf->{group}};

    my $pri_groups = {};
    my $group_members = {};
    foreach my $entry (keys %{$group->{nodes}}) {
	my ($node, $pri) = ($entry, 0);
	if ($entry =~ m/^(\S+):(\d+)$/) {
	    ($node, $pri) = ($1, $2);
	}
	next if !defined($online_node_usage->{$node}); # offline
	$pri_groups->{$pri}->{$node} = 1;
	$group_members->{$node} = $pri;
    }

    
    # add non-group members to unrestricted groups (priority -1)
    if (!$group->{restricted}) {
	my $pri = -1;
	foreach my $node (keys %$online_node_usage) {
	    next if defined($group_members->{$node});
	    $pri_groups->{$pri}->{$node} = 1;
	    $group_members->{$node} = -1;
	}
    }


    my @pri_list = sort {$b <=> $a} keys %$pri_groups;
    return undef if !scalar(@pri_list);

    # stay on current node if possible (avoids random migrations)
    if (!$try_next && $group->{nofailback} && defined($group_members->{$current_node})) {
	return $current_node;
    }

    # select node from top priority node list

    my $top_pri = $pri_list[0];

    my @nodes = sort { 
	$online_node_usage->{$a} <=> $online_node_usage->{$b} || $a cmp $b
    } keys %{$pri_groups->{$top_pri}};

    my $found;
    for (my $i = scalar(@nodes) - 1; $i >= 0; $i--) {
	my $node = $nodes[$i];
	if ($node eq $current_node) {
	    $found = $i;
	    last;
	}
    }

    if ($try_next) {

	if (defined($found) && ($found < (scalar(@nodes) - 1))) {
	    return $nodes[$found + 1];
	} else {
	    return $nodes[0];
	}

    } else {

	return $nodes[$found] if defined($found);

	return $nodes[0];

    }
}

my $uid_counter = 0;

sub compute_new_uuid {
    my ($state) = @_;
    
    $uid_counter++;
    return md5_base64($state . $$ . time() . $uid_counter);
}

my $valid_service_states = {
    stopped => 1,
    request_stop => 1,
    started => 1,
    fence => 1,
    migrate => 1,
    relocate => 1,
    freeze => 1,
    error => 1,
};

sub recompute_online_node_usage {
    my ($self) = @_;

    my $online_node_usage = {};

    my $online_nodes = $self->{ns}->list_online_nodes();

    foreach my $node (@$online_nodes) {
	$online_node_usage->{$node} = 0;
    }

    foreach my $sid (keys %{$self->{ss}}) {
	my $sd = $self->{ss}->{$sid};
	my $state = $sd->{state};
	if (defined($online_node_usage->{$sd->{node}})) {
	    if (($state eq 'started') || ($state eq 'request_stop') || 
		($state eq 'fence') || ($state eq 'freeze') || ($state eq 'error')) {
		$online_node_usage->{$sd->{node}}++;
	    } elsif (($state eq 'migrate') || ($state eq 'relocate')) {
		$online_node_usage->{$sd->{target}}++;
	    } elsif ($state eq 'stopped') {
		# do nothing
	    } else {
		die "should not be reached";
	    }
	}
    }

    $self->{online_node_usage} = $online_node_usage;
}

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
    foreach my $k (sort keys %params) {
	my $v = $params{$k};
	$text_state .= ", " if $text_state;
	$text_state .= "$k = $v";
	$sd->{$k} = $v;
    }

    $self->recompute_online_node_usage();

    $sd->{uid} = compute_new_uuid($new_state);

    $text_state = "  ($text_state)" if $text_state;
    $haenv->log('info', "service '$sid': state changed from '${old_state}'" .
		" to '${new_state}'$text_state");
};

# after a node was fenced this recovers the service to a new node
my $recover_fenced_service = sub {
    my ($self, $sid, $cd) = @_;

    my ($haenv, $ss) = ($self->{haenv}, $self->{ss});

    my $sd = $ss->{$sid};

    if ($sd->{state} ne 'fence') { # should not happen
	$haenv->log('err', "cannot recover service '$sid' from fencing," .
		    " wrong state '$sd->{state}'");
	return;
    }

    my $fenced_node = $sd->{node}; # for logging purpose

    $self->recompute_online_node_usage(); # we want the most current node state

    my $recovery_node = select_service_node($self->{groups},
					    $self->{online_node_usage},
					    $cd, $sd->{node});

    if ($recovery_node) {
	$haenv->log('info', "recover service '$sid' from fenced node " .
		    "'$fenced_node' to node '$recovery_node'");

	$haenv->steal_service($sid, $sd->{node}, $recovery_node);

	# $sd *is normally read-only*, fencing is the exception
	$cd->{node} = $sd->{node} = $recovery_node;
	&$change_service_state($self, $sid, 'started', node => $recovery_node);
    } else {
	# no node found, let the service in 'fence' state and try again
	$haenv->log('err', "recovering service '$sid' from fenced node " .
		    "'$fenced_node' failed, no recovery node found");
    }
};

# read LRM status for all nodes 
sub read_lrm_status {
    my ($self) = @_;

    my $nodes = $self->{ns}->list_nodes();
    my $haenv = $self->{haenv};

    my $results = {};
    my $modes = {};
    foreach my $node (@$nodes) {
	my $lrm_status = $haenv->read_lrm_status($node);
	$modes->{$node} = $lrm_status->{mode} || 'active';
	foreach my $uid (keys %{$lrm_status->{results}}) {
	    next if $results->{$uid}; # should not happen
	    $results->{$uid} = $lrm_status->{results}->{$uid};
	}
    }

    
    return ($results, $modes);
}

# read new crm commands and save them into crm master status
sub update_crm_commands {
    my ($self) = @_;

    my ($haenv, $ms, $ns, $ss) = ($self->{haenv}, $self->{ms}, $self->{ns}, $self->{ss});

    my $cmdlist = $haenv->read_crm_commands();
    
    foreach my $cmd (split(/\n/, $cmdlist)) {
	chomp $cmd;

	if ($cmd =~ m/^(migrate|relocate)\s+(\S+)\s+(\S+)$/) {
	    my ($task, $sid, $node) = ($1, $2, $3); 
	    if (my $sd = $ss->{$sid}) {
		if (!$ns->node_is_online($node)) {
		    $haenv->log('err', "crm command error - node not online: $cmd");
		} else {
		    if ($node eq $sd->{node}) {
			$haenv->log('info', "ignore crm command - service already on target node: $cmd");
		    } else { 
			$haenv->log('info', "got crm command: $cmd");
			$ss->{$sid}->{cmd} = [ $task, $node];
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
	$haenv->log('info', "master seems offline");
	return;
    }

    my ($lrm_results, $lrm_modes) = $self->read_lrm_status();

    my $sc = $haenv->read_service_config();

    $self->{groups} = $haenv->read_group_config(); # update

    # compute new service status

    # add new service
    foreach my $sid (sort keys %$sc) {
	next if $ss->{$sid}; # already there
	$haenv->log('info', "adding new service '$sid' on node '$sc->{$sid}->{node}'");
	# assume we are running to avoid relocate running service at add
	$ss->{$sid} = { state => 'started', node => $sc->{$sid}->{node},
			uid => compute_new_uuid('started') };
    }

    # remove stale service from manager state
    foreach my $sid (keys %$ss) {
	next if $sc->{$sid};
	$haenv->log('info', "removing stale service '$sid' (no config)");
	delete $ss->{$sid};
    }

    # remove stale relocation try entries
    foreach my $sid (keys %{$ms->{relocate_trial}}) {
	delete $ms->{relocate_trial}->{$sid} if !$ss->{$sid};
    }

    $self->update_crm_commands();

    for (;;) {
	my $repeat = 0;
	
	$self->recompute_online_node_usage();

	foreach my $sid (sort keys %$ss) {
	    my $sd = $ss->{$sid};
	    my $cd = $sc->{$sid} || { state => 'disabled' };

	    my $lrm_res = $sd->{uid} ? $lrm_results->{$sd->{uid}} : undef;

	    my $last_state = $sd->{state};

	    if ($last_state eq 'stopped') {

		$self->next_state_stopped($sid, $cd, $sd, $lrm_res);

	    } elsif ($last_state eq 'started') {

		$self->next_state_started($sid, $cd, $sd, $lrm_res);

	    } elsif ($last_state eq 'migrate' || $last_state eq 'relocate') {

		$self->next_state_migrate_relocate($sid, $cd, $sd, $lrm_res);

	    } elsif ($last_state eq 'fence') {

		# do nothing here - wait until fenced

	    } elsif ($last_state eq 'request_stop') {

		$self->next_state_request_stop($sid, $cd, $sd, $lrm_res);

	    } elsif ($last_state eq 'freeze') {

		my $lrm_mode = $sd->{node} ? $lrm_modes->{$sd->{node}} : undef;
		# unfreeze
		&$change_service_state($self, $sid, 'started') 
		    if $lrm_mode && $lrm_mode eq 'active';

	    } elsif ($last_state eq 'error') {

		$self->next_state_error($sid, $cd, $sd, $lrm_res);

	    } else {

		die "unknown service state '$last_state'";
	    }

	    my $lrm_mode = $sd->{node} ? $lrm_modes->{$sd->{node}} : undef;
	    if ($lrm_mode && $lrm_mode eq 'restart') {
		if (($sd->{state} eq 'started' || $sd->{state} eq 'stopped' ||
		     $sd->{state} eq 'request_stop')) {
		    &$change_service_state($self, $sid, 'freeze');
		}
	    }

	    $repeat = 1 if $sd->{state} ne $last_state;
	}

	# handle fencing
	my $fenced_nodes = {};
	foreach my $sid (sort keys %$ss) {
	    my $sd = $ss->{$sid};
	    next if $sd->{state} ne 'fence';

	    if (!defined($fenced_nodes->{$sd->{node}})) {
		$fenced_nodes->{$sd->{node}} = $ns->fence_node($sd->{node}) || 0;
	    }

	    next if !$fenced_nodes->{$sd->{node}};

	    # node fence was successful - recover service
	    &$recover_fenced_service($self, $sid, $sc->{$sid});
	}

	last if !$repeat;
    }

    $self->flush_master_status();
}

# functions to compute next service states
# $cd: service configuration data (read only)
# $sd: service status data (read only)
#
# Note: use change_service_state() to alter state
#

sub next_state_request_stop {
    my ($self, $sid, $cd, $sd, $lrm_res) = @_;

    my $haenv = $self->{haenv};
    my $ns = $self->{ns};

    # check result from LRM daemon
    if ($lrm_res) {
	my $exit_code = $lrm_res->{exit_code};
	if ($exit_code == SUCCESS) {
	    &$change_service_state($self, $sid, 'stopped');
	    return;
	} else {
	    $haenv->log('err', "service '$sid' stop failed (exit code $exit_code)");
	    &$change_service_state($self, $sid, 'error'); # fixme: what state?
	    return;
	}
    }

    if ($ns->node_is_offline_delayed($sd->{node})) {
	&$change_service_state($self, $sid, 'fence');
	return;
    }
}

sub next_state_migrate_relocate {
    my ($self, $sid, $cd, $sd, $lrm_res) = @_;

    my $haenv = $self->{haenv};
    my $ns = $self->{ns};

    # check result from LRM daemon
    if ($lrm_res) {
	my $exit_code = $lrm_res->{exit_code};
	my $req_state = $cd->{state} eq 'enabled' ? 'started' : 'request_stop';
	if ($exit_code == SUCCESS) {
	    &$change_service_state($self, $sid, $req_state, node => $sd->{target});
	    return;
	} elsif ($exit_code == EWRONG_NODE) {
	    $haenv->log('err', "service '$sid' - migration failed: service" .
			" registered on wrong node!");
	    &$change_service_state($self, $sid, 'error');
	} else {
	    $haenv->log('err', "service '$sid' - migration failed (exit code $exit_code)");
	    &$change_service_state($self, $sid, $req_state, node => $sd->{node});
	    return;
	}
    }

    if ($ns->node_is_offline_delayed($sd->{node})) {
	&$change_service_state($self, $sid, 'fence');
	return;
    }
}


sub next_state_stopped {
    my ($self, $sid, $cd, $sd, $lrm_res) = @_;

    my $haenv = $self->{haenv};
    my $ns = $self->{ns};

    if ($sd->{node} ne $cd->{node}) {
	# this can happen if we fence a node with active migrations
	# hack: modify $sd (normally this should be considered read-only)
	$haenv->log('info', "fixup service '$sid' location ($sd->{node} => $cd->{node})");
	$sd->{node} = $cd->{node}; 
    }

    if ($sd->{cmd}) {
	my ($cmd, $target) = @{$sd->{cmd}};
	delete $sd->{cmd};

	if ($cmd eq 'migrate' || $cmd eq 'relocate') {
	    if (!$ns->node_is_online($target)) {
		$haenv->log('err', "ignore service '$sid' $cmd request - node '$target' not online");
	    } elsif ($sd->{node} eq $target) {
		$haenv->log('info', "ignore service '$sid' $cmd request - service already on node '$target'");
	    } else {
		&$change_service_state($self, $sid, $cmd, node => $sd->{node},
				       target => $target);
		return;
	    }
	} else {
	    $haenv->log('err', "unknown command '$cmd' for service '$sid'"); 
	}
    }

    if ($cd->{state} eq 'disabled') {
	# NOTE: do nothing here, the stop state is an exception as we do not
	# process the LRM result here, thus the LRM always tries to stop the
	# service (protection for the case no CRM is active)
	return;
    }

    if ($cd->{state} eq 'enabled') {
	# simply mark it started, if it's on the wrong node
	# next_state_started will fix that for us
	&$change_service_state($self, $sid, 'started', node => $sd->{node});
	return;
    }

    $haenv->log('err', "service '$sid' - unknown state '$cd->{state}' in service configuration");
}

sub next_state_started {
    my ($self, $sid, $cd, $sd, $lrm_res) = @_;

    my $haenv = $self->{haenv};
    my $master_status = $self->{ms};
    my $ns = $self->{ns};

    if (!$ns->node_is_online($sd->{node})) {
	if ($ns->node_is_offline_delayed($sd->{node})) {
	    &$change_service_state($self, $sid, 'fence');
	}
	return;
    }
	
    if ($cd->{state} eq 'disabled') {
	&$change_service_state($self, $sid, 'request_stop');
	return;
    }

    if ($cd->{state} eq 'enabled') {

	if ($sd->{cmd}) {
	    my ($cmd, $target) = @{$sd->{cmd}};
	    delete $sd->{cmd};

	    if ($cmd eq 'migrate' || $cmd eq 'relocate') {
		if (!$ns->node_is_online($target)) {
		    $haenv->log('err', "ignore service '$sid' $cmd request - node '$target' not online");
		} elsif ($sd->{node} eq $target) {
		    $haenv->log('info', "ignore service '$sid' $cmd request - service already on node '$target'");
		} else {
		    $haenv->log('info', "$cmd service '$sid' to node '$target'");
		    &$change_service_state($self, $sid, $cmd, node => $sd->{node}, target => $target);
		}
	    } else {
		$haenv->log('err', "unknown command '$cmd' for service '$sid'"); 
	    }
	} else {

	    my $try_next = 0;
	    if ($lrm_res) {
		my $ec = $lrm_res->{exit_code};
		if ($ec == SUCCESS) {

		    $master_status->{relocate_trial}->{$sid} = 0;

		} elsif ($ec == ERROR) {
		    # apply our relocate policy if we got ERROR from the LRM

		    my $try = $master_status->{relocate_trial}->{$sid} || 0;

		    if ($try < $cd->{max_relocate}) {

			$try++;
			# tell select_service_node to relocate if possible
			$try_next = 1;

			$haenv->log('warning', "starting service $sid on node".
				   " '$sd->{node}' failed, relocating service.");
			$master_status->{relocate_trial}->{$sid} = $try;

		    } else {

			$haenv->log('err', "recovery policy for service".
				   " $sid failed, entering error state!");
			&$change_service_state($self, $sid, 'error');
			return;

		    }
		} else {
		    $haenv->log('err', "service '$sid' got unrecoverable error" .
				" (exit code $ec))");
		    # we have no save way out (yet) for other errors
		    &$change_service_state($self, $sid, 'error');
		    return;
		}
	    }

	    my $node = select_service_node($self->{groups}, $self->{online_node_usage}, 
					   $cd, $sd->{node}, $try_next);

	    if ($node && ($sd->{node} ne $node)) {
		if ($cd->{type} eq 'vm') {
		    $haenv->log('info', "migrate service '$sid' to node '$node' (running)");
		    &$change_service_state($self, $sid, 'migrate', node => $sd->{node}, target => $node);
		} else {
		    $haenv->log('info', "relocate service '$sid' to node '$node'");
		    &$change_service_state($self, $sid, 'relocate', node => $sd->{node}, target => $node);
		}
	    } else {
		# ensure service get started again if it went unexpected down
		$sd->{uid} = compute_new_uuid($sd->{state});
	    }
	}

	return;
    }

    $haenv->log('err', "service '$sid' - unknown state '$cd->{state}' in service configuration");
}

sub next_state_error {
    my ($self, $sid, $cd, $sd, $lrm_res) = @_;

    my $ns = $self->{ns};

    if ($cd->{state} eq 'disabled') {
	&$change_service_state($self, $sid, 'stopped');
	return;
    }

    if ($ns->node_is_offline_delayed($sd->{node})) {
	&$change_service_state($self, $sid, 'fence');
	return;
    }

}

1;
