#!/usr/bin/perl

# ------------------------------------------------------------------------------
# ngmon_agent_pushd.pl
# http://github.com/patrickviet/ngmon/ngmon-agent/
# sends events
#
# Deps: WWW::Curl, Config::Tiny
#
# ------------------------------------------------------------------------------ 


# Standard libs
use warnings;
use strict;
use WWW::Curl::Easy;
use Data::Dumper;

# ------------------------------------------------------------------------------
# Must run as root
die 'must run as root' unless $< == 0;

# ------------------------------------------------------------------------------
# Get current path - must be run before everything else - hence the BEGIN func
# The used libraries are part of perl core.
our $basedir;
BEGIN {
  use Cwd qw(realpath);
  use File::Basename;
  $basedir = dirname(realpath(__FILE__));
}

# ---
# JSON
eval {
  require JSON;
  JSON->import(qw(decode_json encode_json));
  #print "loaded JSON module\n";
};
if($@) {
  eval {
    require JSON::PP;
    JSON::PP->import(qw(decode_json encode_json));
    #print "loaded JSON::PP module\n";
  };
  if($@) {
    die "unable to load JSON or JSON::PP";
  }
}

# ------------------------------------------------------------------------------
# Internal libs (relative path...)
use lib $basedir.'/..';
use NGMon::Conf; # introduces the $conf variable ...

# ------------------------------------------------------------------------------
# Initialize
$NGMon::Conf::basedir = $basedir;
NGMon::Conf::reload();


# ------------------------------------------------------------------------------

$| = 1;
my $curl = WWW::Curl::Easy->new;
#$curl->setopt(CURLOPT_CAINFO, $conf->{notifier}->{ssl_ca_cert});
#$curl->setopt(CURLOPT_SSLCERT, $conf->{notifier}->{ssl_client_cert});
#$curl->setopt(CURLOPT_SSLKEY , $conf->{notifier}->{ssl_client_key});
#$curl->setopt(CURLOPT_SSL_VERIFYPEER, 1);
$curl->setopt(CURLOPT_POST, 1);

#print $conf->{notifier}->{ssl_ca_cert}."\n";

my %already_pushed = ();


while(1) {
  # what we do here is determine if there is a new full state we haven't transmitted yet
  # if there is either, we decide to push everything.
  # the run_probes.pl makes it so there's no more than one full state generation
  # every minute

  if(!-d $conf->{base}->{tmpdir}) { system("mkdir ".$conf->{base}->{tmpdir}); }

  opendir my $dh, $conf->{base}->{tmpdir} or die $!;
  my @file_list = grep { (!(exists $already_pushed{$_})) } 
                  grep { /^ngmon\.fullstate\.([0-9]+)$/ }
                  readdir $dh;

  if (scalar @file_list) {
    scan_and_push();
  }
  sleep 1;
}

sub scan_and_push {
  my @to_push = ();

  opendir my $dh, $conf->{base}->{tmpdir} or die $!;
  foreach my $file (readdir $dh) {
    next unless $file =~ m/^ngmon\.(fullstate|probe\..+)\.([0-9]+)$/;
    
    my ($type,$stamp) = ($1,int($2)); # the int() is used to cast. for future JSON convert.
    if (substr($type,0,6) eq 'probe.') { $type = 'probe'; }

    $file = $conf->{base}->{tmpdir}.'/'.$file;
    next unless -f $file;

    push @to_push, [ $file, $type, $stamp ];

    if (scalar @to_push >= $conf->{notifier}->{post_chunk_size}) {
      push_to_server(\@to_push);
      @to_push = ();
    }
  }
  closedir $dh;
  push_to_server(\@to_push) if scalar @to_push;
}

sub push_to_server {
  my $to_push = shift;
  my @content = ();

  foreach my $filespec (@$to_push) {
    # now all we want is to put the data in.
    # fixme: cleanly handle wrong json
    my ($file,$type,$stamp) = @$filespec;
    open my $fh, $file or die $!;
    my $buffer = "";
    while(<$fh>) { $buffer .= $_; }
    close $fh;

    my $rawdata = decode_json($buffer);

    my $node = $conf->{base}->{node};
    if (exists $rawdata->{node}) {
      if ($rawdata->{node}) {
        $node = $rawdata->{node};
      }
    }

    push @content, {
      'type'  => $type,
      'stamp' => $stamp,
      'node'  => $node,
      'data'  => $rawdata,
    };

    # FIXME: add to already_pushed on success of push.
  }

  print "push to server ".length(encode_json(\@content))."\n";
  $curl->setopt(CURLOPT_POST, 1);
  $curl->setopt(CURLOPT_URL, 'http://localhost:4567/batch_update');
  $curl->setopt(CURLOPT_POSTFIELDS,encode_json(\@content));

  my $retcode = $curl->perform();

  print "retcode= $retcode\n";
  exit;
   #   print encode_json(\@content);
}

=head



    push @content, $data;

  }
use Data::Dumper;
    print Dumper(\@content);
  exit;
}

=head



  if(scalar @content) {
  
    my $response_content;
    $curl->setopt(CURLOPT_WRITEDATA,\$response_content);
    $curl->setopt(CURLOPT_URL, $conf->{notifier}->{url});
    $curl->setopt(CURLOPT_POSTFIELDS, '['.join(',',@content).']');

    my $retcode = $curl->perform();

    if($retcode == 0) {
      # we got some stuff

      if($response_content eq "OK\n") {
        foreach my $file (@to_delete) { unlink $file or die "unable to delete $file: $!"; }
      } else {

        print "unable to push (ERR: ".substr($response_content,0,500).")\n";
        $next_wait = 5;

        if($response_content =~ m/^ERR/) {
          $next_wait = 1;
        }
      }


    } else {
      # we got an uncool error
      print "we got some error. retcode: $retcode. err:".$curl->strerror($retcode)." ".$curl->errbuf."\n";
      $next_wait = 2;
    }
  }
  sleep($next_wait);
}
