package NGMon::Probe;

# ------------------------------------------------------------------------------
# Structure of a Probe
#
# name = a name... can be in the format name.subname
# cmd = the command to run
# format = json (future=nagios)
# interval = interval in seconds
# tags = list separated by commas. optional. will be automatically added...
# description = freeform text
# timeout = in seconds, time before it fails and generates a default fail event
 

# Specific probe states
# Transient states: next_run
#     

# ------------------------------------------------------------------------------

use warnings;
use strict;
use POE qw(Wheel::Run);

sub new {
  my ($class,$probe_request) = @_;
  return bless {
    req => $probe_request,  
  },$class;  
}

sub ID {
  my $obj = shift;
  return $obj->{req}->{probe_name};
}

sub run {
  my ($obj,$resman) = @_;
  # the ressource manager must pass itself as a param
  
  $obj->{resman} = $resman;
  
  $obj->{session} = POE::Session->create(
    object_states => [ $obj => [ qw(_start _stop probe_run probe_stdout probe_stderr probe_end sig_child timeout)]],  
  );
}

sub _start {
  my ($obj,$kernel) = @_[OBJECT,KERNEL];
  $obj->{cmd} = $obj->{req}->{cmd};
  $kernel->yield('probe_run');
}

sub _stop {
  $_[0]->free_myself();
}

sub _default {
  print "default\n";
}

sub probe_run {
  my ($obj,$kernel) = @_[OBJECT,KERNEL];
  $obj->{stdout} = "",
  $obj->{stderr} = "",

  my $plugindir = $NGMon::Conf::basedir.'/../plugins';

  # check that it can run ...  
  my @sp = split(/\ /, $obj->{cmd});
  if (! -x $sp[0]) {
    if(-x $plugindir.'/'.$sp[0]) {
      $obj->{cmd} = $plugindir.'/'.$obj->{cmd};
    } else {
      if(! -e $obj->{cmd}) {
        $obj->{stderr} = $sp[0]." executable does not exist";
      } else {
          $obj->{stderr} = $sp[0]." is not executable";
      }
      
      return $kernel->yield('probe_end');      
    }
  }
  
  my $wheel;
  
  eval {
    $wheel = POE::Wheel::Run->new(
      Program => $obj->{cmd},
      StdoutEvent => 'probe_stdout',
      StderrEvent => 'probe_stderr',
    ) or $obj->{stderr} = "ERR CRIT - error at lauch: $!";
  };
  
  if($@) {
    $obj->{stderr} = "ERR CRIT - error at launch: $@";  
    return $kernel->yield('probe_end');
  }
  
  if (!$wheel) {
    $obj->{stderr} = "no wheel";
    return $kernel->yield('probe_end');
  }
  
  $obj->{wheel} = $wheel;

  # timeout
  $obj->{timeout_id} = $kernel->delay_set('timeout',$obj->{req}->{exec_timeout});

  # and sig child watch. this method is deprecated but compatible with old POE lib.
  # I'd normally use $kernel->sig_child
  $kernel->sig('CHLD', 'sig_child', $wheel->PID);
}

sub timeout {
  my ($obj,$kernel) = @_[OBJECT,KERNEL];
  $obj->{stderr} .= "exec timeout - killed after ".$obj->{req}->{exec_timeout}."sec";

  ## Here I run a hard kill ...
  $obj->{wheel}->kill('KILL');
}

sub probe_stdout {
  my ($obj,$kernel,$output) = @_[OBJECT,KERNEL,ARG0];
  if (length ($obj->{stdout}) < 512) {
    $obj->{stdout} .= $output;
  }  
}

sub probe_stderr {
  my ($obj,$kernel,$output) = @_[OBJECT,KERNEL,ARG0];
  if (length ($obj->{stdout}) < 512) {
    $obj->{stderr} .= $output;
  }
}

sub sig_child {
  my ($obj,$kernel,$sig, $pid, $exit_code, $details) = @_[OBJECT,KERNEL,ARG0..ARG3];
  
  # I only want to listen to my own PID!
  return unless $pid == $details;

  print "got a sig_child with data $sig $pid $exit_code $details\n";
  $exit_code /= 256 if $exit_code >= 256;
  $obj->{exit_code} = $exit_code;

  if    ($exit_code == 0) { $obj->{state} = 'ok'; }
  elsif ($exit_code == 1) { $obj->{state} = 'warn'; }
  else                    { $obj->{state} = 'crit'; }


  print "obj state $obj->{state}\n";
  $kernel->sig_handled();
  
  $kernel->yield('probe_end');
}

sub probe_end {
  my ($obj,$kernel) = @_[OBJECT,KERNEL];
  $obj->{wheel} = undef;

  my $ret = {};
  foreach my $k ('stderr','stdout','exit_code', 'state') {
    $ret->{$k} = (exists $obj->{$k}) ? $obj->{$k} : '';
  }

  foreach my $k ('stderr', 'stdout') {
    if (length($ret->{$k}) >= 512) {
      $ret->{$k} .= "\[truncated\]";
    }
  }

  $obj->{ret} = $ret;
  
  if(!exists $ret->{stamp}) { $ret->{stamp} = time(); }

  # this happens in case of timeout for example
  if(!exists $ret->{state}) { $ret->{state} = 'crit'; }

  # fill other values from config
  foreach my $k(keys %{$obj->{req}}) {
    if(!exists $ret->{$k}) {
      $ret->{$k} = $obj->{req}->{$k};
    }
  }

  # FIXME
  # kill timeout 

  $obj->free_myself();
  
  # not putting this in free myself...
  $kernel->alarm_remove($obj->{timeout_id});
  $kernel->post('main_loop','basic_loop');
}

sub free_myself {
  my $obj = shift;
  if($obj->{resman}) {
    $obj->{resman}->probe_unregister($obj);
    $obj->{resman} = undef;
  }
  
  $obj->{session} = undef;
  $obj->{wheel} = undef;  
}

1;