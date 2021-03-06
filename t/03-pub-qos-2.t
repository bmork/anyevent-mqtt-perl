#!/usr/bin/perl
#
# Copyright (C) 2011 by Mark Hindess

use strict;
use constant {
  DEBUG => $ENV{ANYEVENT_MQTT_TEST_DEBUG}
};
use File::Temp qw/tempfile/;
use Net::MQTT::Constants;

$|=1;

BEGIN {
  require Test::More;
  $ENV{PERL_ANYEVENT_MODEL} = 'Perl' unless ($ENV{PERL_ANYEVENT_MODEL});
  eval { require AnyEvent; import AnyEvent;
         require AnyEvent::Socket; import AnyEvent::Socket };
  if ($@) {
    import Test::More skip_all => 'No AnyEvent::Socket module installed: $@';
  }
  eval { require AnyEvent::MockTCPServer; import AnyEvent::MockTCPServer };
  if ($@) {
    import Test::More skip_all => 'No AnyEvent::MockTCPServer module: '.$@;
  }
  import Test::More;
}

my $published;
my @connections =
  (
   [
    [ packrecv => '10 17 00 06  4D 51 49 73   64 70 03 02  00 78 00 09
                   61 63 6D 65  5F 6D 71 74   74', q{connect} ],
    [ packsend => '20 02 00 00', q{connack} ],
    [ packrecv => '34 12 00 06  2F 74 6F 70   69 63 00 01  6D 65 73 73
                   61 67 65 31', q{publish} ],
    [ packsend => '50 02 00 01', q{pubrec} ],
    [ packrecv => '62 02 00 01', q{pubrel} ],
    [ packsend => '70 02 00 01', q{pubcomp} ],
    [ code => sub { $published->send(1) }, q{publish complete} ],
   ],
  );

my $server;
eval { $server = AnyEvent::MockTCPServer->new(connections => \@connections); };
plan skip_all => "Failed to create dummy server: $@" if ($@);

my ($host, $port) = $server->connect_address;

plan tests => 8;

use_ok('AnyEvent::MQTT');

my $mqtt = AnyEvent::MQTT->new(host => $host, port => $port,
                               client_id => 'acme_mqtt');

ok($mqtt, 'instantiate AnyEvent::MQTT object');

$published = AnyEvent->condvar;
my $cv = $mqtt->publish(message => 'message1', topic => '/topic',
                     qos => MQTT_QOS_EXACTLY_ONCE);
ok($cv, 'message publish with qos 2');
is($cv->recv, 1, '... client complete');
is($published->recv, 1, '... server complete');
