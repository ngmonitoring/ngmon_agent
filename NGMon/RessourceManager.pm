package NGMon::RessourceManager;


use warnings;
use strict;
use POE;
use NGMon::Conf;
use JSON::PP;
use NGMon::RollingState;

my $jsoncoder = JSON::PP->new->ascii->allow_nonref;

sub new {
  my $class = shift;
  
  return bless {
    running => {},
    queue => {}  
  },$class;
}

sub reload {

  my ($obj,$msg) = @_;
  if($msg) { print "reload: $msg\n"; } 
  my $queue = $obj->{queue};
  
  NGMon::Conf::reload();
  
  ## so here I do a big 'diff' which is kinda fun ...
  ## if cmd or exec_interval change then I'll put next run at now
  
  # delete non existing stuff
  foreach my $probe_id (keys %$queue) {
    if(!exists $conf_probes->{$probe_id}) {
      delete $queue->{$probe_id};
      delete $obj->{running}->{$probe_id}; # if it's running that will take care of it ...
    }
  }
  
  # add new stuff and update existing
  foreach my $probe_id (keys %$conf_probes) {
    next if $probe_id  =~ m/^\_/; # ignore everything that starts with an underscore

    
    if(exists $queue->{$probe_id}) {
      my $next_run = 0;

      # reset next run to right now if the exec interval changed
      if ($queue->{$probe_id}->{exec_interval} eq $conf_probes->{$probe_id}->{exec_interval}
        && $queue->{$probe_id}->{exec_interval} eq $queue->{$probe_id}->{exec_interval}) {

        $next_run = $queue->{$probe_id}->{next_run};

      }
      
      %{$queue->{$probe_id}} = %{$conf_probes->{$probe_id}}; 
      $queue->{$probe_id}->{next_run} = $next_run; 
             
    
    } else {
      %{$queue->{$probe_id}} = %{$conf_probes->{$probe_id}}; # defer to make a real copy
      $queue->{$probe_id}->{next_run} = 0;          
    }    
  }
  
  
}

sub already_running {
  my ($obj,$probe_request) = @_;
  if(exists $obj->{running}->{$probe_request->{probe_name}})  { return 1; }
}

sub probe_register {
  my ($obj,$probe) = @_;
  $obj->{running}->{$probe->ID} = $probe;
  $probe->{resman} = $obj;
  $probe->run($obj);
}

sub can_run_new_probe {
  my $obj = shift;
  if(scalar keys %{$obj->{running}} < $conf->{base}->{max_simultaneous_probes}) {
    return 1;
  }
}

sub get_queue {
  my $obj = shift;
  my $queue = [];
  my $now = time();
  
  # not fast but I won't have millions either so it's OK I guess ...
  foreach my $probe_id (keys %{$obj->{queue}}) {
    my $probe_request = $obj->{queue}->{$probe_id};
    if($probe_request->{next_run} <= $now) {
      # must run.
      $probe_request->{probe_name} = $probe_id;
      push @$queue, $probe_request;
    }
  }
  
  return $queue;
} 
  
sub probe_unregister {
  my ($obj,$probe) = @_;
  my $probe_id = $probe->ID;
  delete $obj->{running}->{$probe_id};
  
  $obj->{queue}->{$probe_id}->{next_run} = time() + $obj->{queue}->{$probe_id}->{exec_interval};

  # add a node value (can be overridden)
  if(!exists $probe->{ret}->{node}) { $probe->{ret}->{node} = $conf->{base}->{node}; }
  
  NGMon::RollingState::insert_probe_result($probe->{ret});

  #FIXME
  use Data::Dumper;

  my $tmpfile;
  my $tmpdir = $conf->{base}->{tmpdir};
  die unless $tmpdir;
  if(!-d $tmpdir) { system("mkdir -p $tmpdir"); }
  
  do {
    $tmpfile = "$tmpdir/ngmon.probe.".$probe->{ret}->{probe_name}.".".time();  
  }
  while(-f $tmpfile);
  

  print Dumper($probe->{ret});
  
  open my $fh, ">$tmpfile" or die $!;
  print $fh $jsoncoder->encode($probe->{ret});
  close $fh;
  
}

1;
