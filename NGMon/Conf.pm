package NGMon::Conf;

use warnings;
use strict;
use Exporter;
use Config::Tiny;
use Carp qw(croak carp);

use vars qw($conf $conf_probes $basedir);
our @ISA = qw(Exporter);
our @EXPORT = qw($conf $conf_probes);

## improved version: reads files from other directories and stuff
## You must set $NGMon::Conf::basedir before running a reload


sub reload {
  die 'needs basedir' unless -d $basedir;

  # first part: the 'generic' configuration
  # ---------------------------------------
  my $new_conf = Config::Tiny->read("$basedir/../etc/ngmon.conf");
  if(!$new_conf) {
    carp "unable to load config file $basedir/../etc/ngmon.conf: $!";
    if($conf) {
      carp "keeping current config running";
      return;
    } else {
      # this is a first run
      croak "interrupting startup";
    }
  }

  my $new_conf_local = Config::Tiny->read("$basedir/../etc/ngmon.local.conf");
  if($new_conf_local) {
    override($new_conf,$new_conf_local);
  } else {
    carp "unable to load local config file $basedir/../etc/ngmon.local.conf: $!";
  }

  $conf = $new_conf;

  # node defaults to hostname
  if(!exists $conf->{base}->{node}) {
    my $node = `hostname`;
    chomp($node);
    $conf->{base}->{node} = $node;
  }


  # second part: the 'probe' configuration
  # -------------------------------------

  my $new_conf_probes = Config::Tiny->read("$basedir/../etc/ngmon.probes.conf");
  if(!$new_conf_probes) {
    carp "unable to load config file $basedir/../etc/ngmon.probes.conf: $!";
    if($conf_probes) {
        carp "keeping current running config";
      } else {
        croak "interrupting startup";
      }
  }

  

  # add 'special probe': the hello
  $new_conf_probes->{hello} = {
    'cmd' => '/bin/true',
    'exec_interval' => $conf->{base}->{hello_interval}, # this means it times out after 2x this
    'state' => 'ok',
    'rs_length' => 1,
    'rs_max_warn' => 1,
    'rs_max_crit' => 1,
    'rs_persistent' => 1, # make it persistent: stays there until deleted manually
  };

  my $conf_probes_d = $basedir.'/../etc/ngmon.probes.conf.d';

  if (-d $conf_probes_d) {
    opendir(my $dh, $conf_probes_d) or die "unable to open dir $conf_probes_d: $!";
    foreach my $file (readdir $dh) {
      next unless -f "$conf_probes_d/$file";
      next unless $file =~ m/(.*)\.conf$/; # only get .conf files ...

      my $default_probe_name = $1;
      my $localconf = Config::Tiny->read("$conf_probes_d/$file");

      if ($localconf) {
        # auto fill in ----
        if(exists $localconf->{_}) {
          $localconf->{$default_probe_name} = delete $localconf->{_};
        }

        override($new_conf_probes,$localconf);
      
      } else {
        carp "unable to load $conf_probes_d/$file: $!";
      }
    }
    
    closedir($dh); 
  }

  # set default values
  foreach my $probe_name (keys %$conf_probes) {
    foreach my $key (keys %{$conf->{default_probe_values}}) {
      if(!exists $conf_probes->{$probe_name}->{$key}) {
        $new_conf_probes->{$probe_name}->{$key} = $conf->{default_probe_values}->{$key};
      } else { print "$key already exists\n"}
    }

    # get rid of inactive probes
    if (!$conf_probes->{$probe_name}->{active}) {
      delete $conf_probes->{$probe_name};
    } else {
      # the active flag is not really useful for now anyway... let's not keep it for now
      delete $conf_probes->{$probe_name}->{active};
    }

  }

  $conf_probes = $new_conf_probes;
}



sub override {
  my ($elem1,$elem2) = @_;

  if (ref($elem2) eq 'ARRAY') {
    foreach (@$elem2) {
      if (ref($_)) {
        override($elem1->[$_],$elem2->[$_]);
        # attention il n'y a pas de deep copy!!
      } else {
        $elem1->[$_] = $elem2->[$_];
      }
    }
  } elsif (ref ($elem2) eq 'HASH' or ref ($elem2) eq 'Config::Tiny') {
    foreach (keys %$elem2) {
      if (ref($elem2->{$_})) {
        if(ref($elem1->{$_})) {
          override($elem1->{$_},$elem2->{$_});
        } else {
          $elem1->{$_} = deep_copy($elem2->{$_});
        }
      } else {
        $elem1->{$_} = $elem2->{$_};
      }
    }
  } else {
    die "drole de ref! $_?";
  }
}

sub deep_copy {
  my $this = shift;
  if (not ref $this) {
    $this;
  } elsif (ref $this eq "ARRAY") {
    [map deep_copy($_), @$this];
  } elsif (ref $this eq "HASH") {
    +{map { $_ => deep_copy($this->{$_}) } keys %$this};
  } else { die "what type is $_?" }
}


1;
