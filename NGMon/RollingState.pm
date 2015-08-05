package NGMon::RollingState;

use warnings;
use strict;
use POE;
use NGMon::Conf;
use JSON::PP;
use File::Path;

# This loads state
my $fullstate = {};
my $last_state_dump = 0;
my $jsoncoder = JSON::PP->new->ascii->allow_nonref;

#FIXME: do the load better
sub firstload {
  print "firstload\n";
  my $tmpdir = $conf->{base}->{tmpdir};
  mkpath($tmpdir) unless -d $tmpdir;
  opendir my $dh, $tmpdir or die $!;
  my @cfiles = ();
  foreach (readdir $dh) {
    next unless m/^ngmon\.fullstate\.([0-9]+)$/;
    push @cfiles, $_;
  }
  closedir($dh);
  print "try to load\n";
  if (scalar @cfiles) {
    print "load\n";
    my $file_to_read = pop @cfiles;
    my $buffer = "";
    if (open my $fh, "$tmpdir/$file_to_read") {
      my $buffer = "";
      while (<$fh>) {
        $buffer .= $_;
      }
      close $fh;

      #FIXME: check syntax.
      print $buffer."\n";
      $fullstate = $jsoncoder->decode($buffer);
      undef $buffer;

    } else {
      rename $file_to_read, $file_to_read.".invalid";
    }
  }
}

sub insert_probe_result {
  firstload() unless scalar keys %$fullstate;
  my $probe = shift;

  my $probe_name = $probe->{probe_name};
  my $rs_length = $probe->{rs_length} || 4;
  my $rs_max_crit = $probe->{rs_max_crit} || 2;
  my $rs_max_warn = $probe->{rs_max_warn} || 2;

  # normalize
  $rs_length = 10 if $rs_length > 10;
  $rs_max_crit = $rs_length if $rs_max_crit > $rs_length;
  $rs_max_warn = $rs_length if $rs_max_warn > $rs_length;


  my $rs = [];
  my $state = 'ok';
  if (exists $fullstate->{$probe_name}) {
    $rs = $fullstate->{$probe_name}->{rollstate};
    $state = $fullstate->{$probe_name}->{state};
  }

  # push new probe in there
  push @$rs, $probe->{state};

  # length of pattern
  while(scalar @$rs < $rs_length) { unshift @$rs, 'ok'; }
  while(scalar @$rs > $rs_length) { shift @$rs; }

  # behavior differs depending on current state
  my $newstate = $state;
  if ($state eq 'ok') {
    # From here we can go to warn or crit
    if (scalar grep(/^(warn|crit)$/, @$rs) >= $rs_max_warn) { $newstate = 'warn'; }
    if (scalar grep(/^crit$/, @$rs) >= $rs_max_crit) { $newstate = 'crit'; }
  }
  else
  {
    # this counts the number of consecutive trailing OK
    my $last_ok_count = 0;
    for (my $x = 1 ; $x < scalar @$rs && $rs->[-$x] eq 'ok' ; $x++) {
      $last_ok_count++;
    }

    if ($last_ok_count >= 3 or $last_ok_count == $rs_length) {

      # it goes to ok AND 
      $newstate = 'ok';
      foreach(1..$rs_length) { shift @$rs ; push @$rs, 'ok'; }
    }
    elsif ($state eq 'warn') {
      # last possibility is going from warn to crit. there's no crit to warn
      if (scalar grep(/^crit$/, @$rs) >= $rs_max_crit) { $newstate = 'crit'; }
    }
  }

  print "rolling state: probe $probe_name pattern (".join(',',@$rs).")\n";

  my $last_output = $probe->{stdout};
  $last_output .= ' ' if $last_output and $probe->{stderr};
  $last_output .= "(STDERR: ".$probe->{stderr}.")" if $probe->{stderr};

  $fullstate->{$probe_name} = {
    'state'       => $newstate,
    'oldstate'    => $state,
    'rollstate'   => $rs,
    'last_output' => $last_output,
    'next_run'    => $probe->{next_run},
    'stamp'       => $probe->{stamp},
  };

  if ($newstate ne $state) {
    print "$probe_name state change $state > $newstate\n";
  }

  if ($newstate ne $state or $last_state_dump + $conf->{base}->{full_state_dump_interval} < time()) {
    state_dump();
  }
}

#last_output, next_run, exec_stamp

sub state_dump {
  my $tmpdir = $conf->{base}->{tmpdir};
  die unless $tmpdir;
  if(!-d $tmpdir) { system("mkdir -p $tmpdir"); }
  
  my $tmpfile = "$tmpdir/ngmon.tmp.fullstate.".time();
  my $statefile = "$tmpdir/ngmon.fullstate.".time();
  open TMP, ">", $tmpfile;
  print TMP $jsoncoder->encode($fullstate);
  close TMP;
  rename $tmpfile, $statefile;
  $last_state_dump = scalar time();
}

1;