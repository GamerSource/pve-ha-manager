package PVE::HA::Manager;

use strict;
use warnings;

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

sub select_service_node {
    my ($self, $service_conf) = @_;

    my $ns = $self->{ns};
    
    my $pref_node = $service_conf->{node};

    return $pref_node if $ns->node_is_online($pref_node);

    my $online_nodes = $ns->list_online_nodes();

    return shift @$online_nodes;
}

sub manage {
    my ($self) = @_;

    my ($haenv, $ms, $ns, $ss) = ($self->{haenv}, $self->{ms}, $self->{ns}, $self->{ss});

    $ns->update($haenv->get_node_info());
    
    my $sc = $haenv->read_service_config();

    # compute new service status

    # add new service
    foreach my $sid (keys %$sc) {
	next if $ss->{$sid}; # already there
	$haenv->log('info', "Adding new service '$sid'\n");
	# assume we are running to avoid relocate running service at add
	$ss->{$sid} = { state => 'started', node => $sc->{$sid}->{current_node}};
    }

    foreach my $sid (keys %$ss) {
	my $sd = $ss->{$sid};
	my $cd = $sc->{$sid} || { state => 'disabled' };

	if ($sd->{state} eq 'stopped') {

	    if ($cd->{state} eq 'disabled') {
		# do nothing
	    } elsif ($cd->{state} eq 'enabled') {
		if (my $node = $self->select_service_node($cd)) {
		    $haenv->log('info', "starting service '$sid' on node '$node'\n");
		    $sd->{state} = 'started';
		    $sd->{node} = $node;
		} else {
		    # fixme: warn 
		}
	    } else {
		# do nothing - todo: log something?
	    }

	} elsif ($sd->{state} eq 'started') {

	    if (!$ns->node_is_online($sd->{node})) {

		$haenv->log('info', "fence service '$sid' on node '$sd->{node}'\n");

		$sd->{state} = 'fence';

	    } else {

		if ($cd->{state} eq 'disabled') {
		    $sd->{state} = 'request_stop';
		} elsif ($cd->{state} eq 'enabled') {
		    if ($sd->{node} ne $cd->{node}) {
			$sd->{state} = 'migrate'; # fixme: save new node
		    } else {
			# do nothing
		    }
		} else {
		    # do nothing - todo: log something?
		}
	    }

	} elsif ($sd->{state} eq 'migrate') {

	    die "implement me";

	} elsif ($sd->{state} eq 'fence') {

	    if ($ns->fence_node($sd->{node})) {
		$sd->{state} = 'stopped';
	    } else {
		# do nothing, wait until fence is successful
	    }

	} elsif ($sd->{state} eq 'request_stop') {

	    die "implement me";

	} else {

	    die "unknown service state '$sd->{state}'";
	}

    }
   

    # remove stale services
    # fixme:

    $self->flush_master_status();
}


1;
