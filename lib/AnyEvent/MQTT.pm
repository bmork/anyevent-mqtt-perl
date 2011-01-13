use strict;
use warnings;
package AnyEvent::MQTT;

# ABSTRACT: AnyEvent module for an MQTT client

=head1 SYNOPSIS

  use AnyEvent::MQTT;
  my $mqtt = AnyEvent::MQTT->new;
  $mqtt->subscribe('/topic' => sub {
                                 my ($topic, $message) = @_;
                                 print $topic, ' ', $message, "\n"
                               });

  # publish a simple message
  $mqtt->publish('simple message' => '/topic');

  # publish line-by-line from file handle
  $mqtt->publish(\*STDIN => '/topic');

=head1 DESCRIPTION

AnyEvent module for MQTT client.  THIS API IS AN EARLY RELEASE AND IS
STILL SUBJECT TO SIGNIFICANT CHANGE.

=cut

use constant DEBUG => $ENV{ANYEVENT_MQTT_DEBUG};
use AnyEvent;
use AnyEvent::Handle;
use Net::MQTT::Constants;
use Net::MQTT::Message;
use Carp qw/croak carp/;

=method C<new(%params)>

Constructs a new C<AnyEvent::MQTT> object.  The supported parameters
are:

=over

=item C<host>

The server host.  Defaults to C<127.0.0.1>.

=item C<port>

The server port.  Defaults to C<1883>.

=item C<timeout>

The timeout for responses from the server.

=item C<keep_alive_timer>

The keep alive timer.

=item C<will_topic>

Set topic for will message.  Default is undef which means no will
message will be configured.

=item C<will_qos>

Set QoS for will message.  Default is 'at-most-once'.

=item C<will_retain>

Set retain flag for will message.  Default is 0.

=item C<will_message>

Set message for will message.  Default is the empty message.

=item C<client_id>

Sets the client id for the client overriding the default which
is C<Net::MQTT::Message[NNNNN]> where NNNNN is the process id.

=back

=cut

sub new {
  my ($pkg, %p) = @_;
  my $self =
    bless {
           socket => undef,
           host => '127.0.0.1',
           port => '1883',
           timeout => 30,
           keep_alive_timer => 120,
           qos => MQTT_QOS_AT_MOST_ONCE,
           message_id => 1,
           user_name => undef,
           password => undef,
           will_topic => undef,
           will_qos => MQTT_QOS_AT_MOST_ONCE,
           will_retain => 0,
           will_message => '',
           client_id => undef,
           connect_queue => [],
           %p,
          }, $pkg;
}

sub cleanup {
  my $self = shift;
  print STDERR "cleanup\n" if DEBUG;
  delete $self->{handle};
  delete $self->{connected};
  $self->{connect_queue} = [];
  $self->{on_error}->(@_) if ($self->{on_error});
}

sub publish {
  my ($self, $data, $topic, %p) = @_;
  my $qos = $p{qos} || MQTT_QOS_AT_MOST_ONCE;
  unless (ref $data) {
    print STDERR "publish: simple[$data] => $topic\n" if DEBUG;
    my $mid = $self->{message_id}++;
    $self->_send(message_type => MQTT_PUBLISH,
                 qos => $qos,
                 topic => $topic,
                 message_id => $mid,
                 message => $data);
    return;
  }
  my $handle;
  if ($data->isa('AnyEvent::Handle')) {
    $handle = $data;
  } else {
    my @args = @{$p{handle_args}||[]};
    print STDERR "publish: IO[$data] => $topic @args\n" if DEBUG;
    $handle = AnyEvent::Handle->new(fh => $data, @args);
  }
  my @push_read_args = @{$p{push_read_args}||['line']};
  my $sub; $sub = sub {
    my ($hdl, $chunk, @args) = @_;
    print STDERR "publish: $chunk => $topic\n" if DEBUG;
    my $mid = $self->{message_id}++;
    $self->_send(message_type => MQTT_PUBLISH,
                 qos => $qos,
                 topic => $topic,
                 message_id => $mid,
                 message => $chunk);
    $handle->push_read(@push_read_args => $sub);
    return;
  };
  $handle->push_read(@push_read_args => $sub);
  return $handle;
}

sub subscribe {
  my ($self, $topic, $sub, $qos, $cv) = @_;
  $cv = AnyEvent->condvar unless (defined $cv);
  my $mid = $self->_add_subscription($topic, $sub, $cv);
  if (defined $mid) { # not already subscribed/subscribing
    $qos = MQTT_QOS_AT_MOST_ONCE unless (defined $qos);
    $self->_send(Net::MQTT::Message->new(message_type => MQTT_SUBSCRIBE,
                                         message_id => $mid,
                                         topics => [[$topic, $qos]]));
  }
  $cv
}

sub _add_subscription {
  my ($self, $topic, $sub, $cv) = @_;
  my $rec = $self->{_sub}->{$topic};
  if ($rec) {
    # existing subscription
    push @{$rec->{cb}}, $sub;
    $cv->send($rec->{qos});
    return;
  }
  $rec = $self->{_sub_pending}->{$topic};
  if ($rec) {
    # existing pending subscription
    push @{$rec->{cb}}, $sub;
    push @{$rec->{cv}}, $cv;
    return;
  }
  my $mid = $self->{message_id}++;
  $self->{_sub_pending_by_message_id}->{$mid} = $topic;
  $self->{_sub_pending}->{$topic} = { cb => [ $sub ], cv => [ $cv ] };
  $mid;
}

sub _confirm_subscription {
  my ($self, $mid, $qos) = @_;
  my $topic = delete $self->{_sub_pending_by_message_id}->{$mid};
  unless (defined $topic) {
    carp "Got SubAck with no pending subscription for message id: $mid\n";
    return;
  }
  my $re = topic_to_regexp($topic); # convert MQTT pattern to regexp
  my $rec;
  if ($re) {
    $rec = $self->{_subre}->{$topic} = delete $self->{_sub_pending}->{$topic};
    $rec->{re} = $re;
  } else {
    $rec = $self->{_sub}->{$topic} = delete $self->{_sub_pending}->{$topic};
  }
  $rec->{qos} = $qos;

  foreach my $cv (@{$rec->{cv}}) {
    $cv->send($qos);
  }
}

sub _send {
  my $self = shift;
  my $msg = ref $_[0] ? $_[0] : Net::MQTT::Message->new(@_);
  $self->{connected} ? $self->_real_send($msg) : $self->_connect($msg);
}

sub _real_send {
  my ($self, $msg) = @_;
  print STDERR "Sending: ", $msg->string, "\n" if DEBUG;
  undef $self->{_keep_alive_handle};
  $self->{_keep_alive_handle} =
    AnyEvent->timer(after => $self->{keep_alive_timer},
                    cb => sub { $self->_send(message_type => MQTT_PINGREQ) });
  return $self->{handle}->push_write($msg->bytes);
}

sub _connect {
  my ($self, $msg) = @_;
  if ($msg) {
    push @{$self->{connect_queue}}, $msg;
  }
  return if ($self->{handle});
  my $hd;
  $hd = $self->{handle} =
    AnyEvent::Handle->new(connect => [$self->{host}, $self->{port}],
                          on_error => sub {
                            print STDERR "handle error $_[2]\n" if DEBUG;
                            $_[0]->destroy;
                            if ($_[1]) {
                              $self->cleanup($_[2]);
                            }
                          },
                          on_eof => sub {
                            print STDERR "handle eof\n" if DEBUG;
                            $_[0]->destroy;
                            $self->cleanup('Connection closed');
                          },
                          on_connect => sub {
                            print STDERR "TCP handshake complete\n" if DEBUG;
                            my $msg =
                              Net::MQTT::Message->new(
                                message_type => MQTT_CONNECT,
                                keep_alive_timer => $self->{keep_alive_timer},
                                client_id => $self->{client_id},
                                will_topic => $self->{will_topic},
                                will_qos => $self->{will_qos},
                                will_retain => $self->{will_retain},
                                will_message => $self->{will_message},
                              );
                            $self->_real_send($msg);
                            $hd->timeout($self->{timeout});
                            $hd->push_read(ref $self => sub {
                                             $self->_handle_message(@_);
                                             return;
                                           });
                          });
  return
}

sub _handle_message {
  my ($self, $handle, $msg, $error) = @_;
  return $self->cleanup($error) if ($error);
  my $type = $msg->message_type;
  if ($type == MQTT_CONNACK) {
    $handle->timeout(undef);
    print STDERR "Connection ready:\n", $msg->string('  '), "\n" if DEBUG;
    while (@{$self->{connect_queue}}) {
      my $msg = shift @{$self->{connect_queue}};
      $self->_real_send($msg);
    }
    $self->{connected} = 1;
    return
  }
  if ($type == MQTT_SUBACK) {
    print STDERR "Confirmed subscription:\n", $msg->string('  '), "\n" if DEBUG;
    $self->_confirm_subscription($msg->message_id, $msg->qos_levels->[0]);
    return
  }
  if ($type == MQTT_PUBLISH) {
    # TODO: handle puback, etc
    my $msg_topic = $msg->topic;
    my $msg_data = $msg->message;
    my $rec = $self->{_sub}->{$msg_topic};
    my %matched;
    if ($rec) {
      foreach my $cb (@{$rec->{cb}}) {
        next if ($matched{$cb}++);
        $cb->($msg_topic, $msg_data, $msg);
      }
    }
    foreach my $topic (keys %{$self->{_subre}}) {
      $rec = $self->{_subre}->{$topic};
      my $re = $rec->{re};
      next unless ($msg_topic =~ $re);
      foreach my $cb (@{$rec->{cb}}) {
        next if ($matched{$cb}++);
        $cb->($msg_topic, $msg_data, $msg);
      }
    }
    unless (scalar keys %matched) {
      print STDERR "Unexpected publish:\n", $msg->string('  '), "\n" if DEBUG;
    }
    return
  }
  print STDERR $msg->string(), "\n";
}

sub anyevent_read_type {
  my ($handle, $cb) = @_;
  sub {
    my $rbuf = \$handle->{rbuf};
    return unless (defined $$rbuf);
    while (1) {
      my $msg = Net::MQTT::Message->new_from_bytes($$rbuf, 1);
      return unless ($msg);
      $cb->($handle, $msg);
    }
    return;
  };
}

1;
