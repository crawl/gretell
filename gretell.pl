#!/usr/bin/perl

#
# ===========================================================================
# Copyright (C) 2007 Marc H. Thoben
# Copyright (C) 2008 Darshan Shaligram
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
# ===========================================================================
#

use strict;
use warnings;

use POE qw(Component::IRC);
use POSIX qw(setsid); # For daemonization.
use File::Find;
use File::Glob qw/:globally :nocase/;

my $nickname       = 'Gretell';
my $ircname        = 'Gretell the Crawl Bot';
# my $ircserver      = 'barjavel.freenode.net';
my $ircserver      = 'kornbluth.freenode.net';
# my $ircserver      = 'bartol.freenode.net';
# my $ircserver      = 'pratchett.freenode.net';
my $port           = 8001;
my @CHANNELS       = ('##crawl', '##crawl-dev');
my $ANNOUNCE_CHAN  = '##crawl';
my $DEV_CHAN       = '##crawl-dev';

my @stonefiles     = ('/var/lib/dgamelaunch/crawl-rel/saves/milestones',
                      '/var/lib/dgamelaunch/crawl-svn/saves/milestones',
                      '/var/lib/dgamelaunch/crawl-old/saves/milestones',
                      '/var/lib/dgamelaunch/crawl-spr/saves/milestones');
my @logfiles       = ('/var/lib/dgamelaunch/crawl-rel/saves/logfile',
                      '/var/lib/dgamelaunch/crawl-svn/saves/logfile',
                      '/var/lib/dgamelaunch/crawl-old/saves/logfile',
                      '/var/lib/dgamelaunch/crawl-spr/saves/logfile');

my $DGL_INPROGRESS_DIR    = '/var/lib/dgamelaunch/dgldir/inprogress';
my $DGL_TTYREC_DIR        = '/var/lib/dgamelaunch/dgldir/ttyrec';
my $INACTIVE_IDLE_CEILING_SECONDS = 300;

my $MAX_LENGTH = 450;
my $SERVER_BASE_URL = 'http://crawl.develz.org';
my $MORGUE_BASE_URL = "$SERVER_BASE_URL/morgues";

my %COMMANDS = (
  '@whereis' => \&cmd_whereis,
  '@dump' => \&cmd_dump,
  '!cdo'     => \&cmd_players,
  '@players' => \&cmd_players,
  '@??' => \&cmd_trunk_monsterinfo,
  '@?' => \&cmd_monsterinfo,
);

## Daemonify. http://www.webreference.com/perl/tutorial/9/3.html
#umask 0;
#defined(my $pid = fork) or die "Unable to fork: $!";
#exit if $pid;
#setsid or die "Unable to start a new session: $!";
## Done daemonifying.

my @stonehandles = open_handles(@stonefiles);
my @loghandles = open_handles(@logfiles);

# We create a new PoCo-IRC object and component.
my $irc = POE::Component::IRC->spawn(
      nick    => $nickname,
      server  => $ircserver,
      port    => $port,
      ircname => $ircname,
      localaddr => '80.190.48.234',
) or die "Oh noooo! $!";

POE::Session->create(
      inline_states => {
        check_files => \&check_files,
        irc_public  => \&irc_public,
        irc_msg     => \&irc_msg
      },

      package_states => [
        'main' => [
          qw(_default _start irc_001 irc_255)
        ],
      ],
      heap => {
        irc => $irc
      },
);

$poe_kernel->run();
exit 0;

sub open_handles
{
  my (@files) = @_;
  my @handles;

  for my $file (@files) {
    open my $handle, '<', $file or do {
	  warn "Unable to open $file for reading: $!";
	  next;
	};
    seek($handle, 0, 2); # EOF
    push @handles, [ $file, $handle, tell($handle) ];
  }
  return @handles;
}

sub newsworthy
{
  my $g = shift;

  # Milestone type, empty if this is not a milestone.
  my $type = $$g{type} || '';

  return 0
    if $type eq 'crash';

  return 0
    if ($type eq 'enter' || $type eq 'br.enter')
      and grep {$g->{br} eq $_} qw/Temple/;

  # Suppress all Sprint events <300 turns.
  return 0
    if $g->{lv} =~ 'sprint' && ($$g{ktyp} || '') ne 'winning'
      && $$g{turn} < 300;

  return 0
    if $g->{lv} =~ 'sprint'
      and $type eq 'uniq'
        and (grep {index($g->{milestone}, $_) > -1}
             qw/Ijyb Sigmund Sonja/);

  return 0
    if (!$$g{milestone}
        && ($g->{sc} <= 2000
            && ($g->{ktyp} eq 'quitting'
                || $g->{ktyp} eq 'leaving'
                || $g->{turn} <= 30)));

  return 1;
}

sub devworthy
{
  my $g = shift;
  my $type = $$g{type} || '';
  return $type eq 'crash';
}

# Given an xlogfile hash, returns the place where the event occurred.
sub xlog_place
{
  my $g = shift;
  my $sprint = $$g{lv} =~ /sprint/i;
  my $place = $$g{place};
  if ($sprint) {
    if ($place eq 'D:1') {
      $place = 'Sprint';
    } else {
      $place = "$place (Sprint)";
    }
  }
  return $place;
}

sub report_milestone
{
  my $game_ref = shift;
  my $channel  = shift;

  my $place = xlog_place($game_ref);
  my $placestring = " ($place)";
  if ($game_ref->{milestone} eq "escaped from the Abyss!"
      || $game_ref->{milestone} eq "reached level 27 of the Dungeon.")
  {
    $placestring = "";
  }

  $irc->yield(privmsg => $channel =>
              sprintf("%s (L%s %s) %s%s",
                      $game_ref->{name},
                      $game_ref->{xl},
                      $game_ref->{char},
                      $game_ref->{milestone},
                      $placestring)
             );
}

sub parse_milestone_file
{
  my $href = shift;
  my $stonehandle = $href->[1];
  $href->[2] = tell($stonehandle);

  my $line = <$stonehandle>;
  # If the line isn't complete, seek back to where we were and wait for it
  # to be done.
  if (!defined($line) || $line !~ /\n$/) {
    seek($stonehandle, $href->[2], 0);
    return;
  }
  $href->[2] = tell($stonehandle);
  return unless defined($line) && $line =~ /\S/;

  my $game_ref = demunge_xlogline($line);

  report_milestone($game_ref, $ANNOUNCE_CHAN) if newsworthy($game_ref);
  report_milestone($game_ref, $DEV_CHAN) if devworthy($game_ref);

  seek($stonehandle, $href->[2], 0);
}

sub parse_log_file
{
  my $href = shift;
  my $loghandle = $href->[1];

  $href->[2] = tell($loghandle);
  my $line = <$loghandle>;
  if (!defined($line) || $line !~ /\n$/) {
    seek($loghandle, $href->[2], 0);
    return;
  }
  $href->[2] = tell($loghandle);
  return unless defined($line) && $line =~ /\S/;

  my $game_ref = demunge_xlogline($line);
  if (newsworthy($game_ref)) {
    my $output = pretty_print($game_ref);
    $output =~ s/ on \d{4}-\d{2}-\d{2}//;
    $irc->yield(privmsg => $ANNOUNCE_CHAN => $output);
  }
  seek($loghandle, $href->[2], 0);
}

sub check_stonefiles
{
  for my $stoneh (@stonehandles) {
    parse_milestone_file($stoneh);
  }
}

sub check_logfiles
{
  for my $logh (@loghandles) {
    parse_log_file($logh);
  }
}

sub check_files
{
  $_[KERNEL]->delay('check_files' => 1);

  check_stonefiles();
  check_logfiles();
}

# We registered for all events, this will produce some debug info.
sub _default
{
  my ($event, $args) = @_[ARG0 .. $#_];
  my @output = ( "$event: " );

  foreach my $arg ( @$args ) {
      if ( ref($arg) eq 'ARRAY' ) {
              push( @output, "[" . join(" ,", @$arg ) . "]" );
      } else {
              push ( @output, "'$arg'" );
      }
  }
  print STDOUT join ' ', @output, "\n";
  return 0;
}

sub _start
{
  my ($kernel,$heap) = @_[KERNEL,HEAP];

  # We get the session ID of the component from the object
  # and register and connect to the specified server.
  my $irc_session = $heap->{irc}->session_id();
  $kernel->post( $irc_session => register => 'all' );
  $kernel->post( $irc_session => connect => { } );
  undef;
}

sub irc_001
{
  my ($kernel,$sender) = @_[KERNEL,SENDER];

  # Get the component's object at any time by accessing the heap of
  # the SENDER
  my $poco_object = $sender->get_heap();
  print "Connected to ", $poco_object->server_name(), "\n";

  # In any irc_* events SENDER will be the PoCo-IRC session
  for my $channel (@CHANNELS) {
    $kernel->post( $sender => join => $channel );
  }
  undef;
}

sub irc_255
{
  $_[KERNEL]->yield("check_files");

  open(my $handle, '<', '.password') or warn "Unable to read .password: $!";
  my $password = <$handle>;
  chomp $password;

  $irc->yield(privmsg => "nickserv" => "identify $password");
}

sub irc_msg {
  process_irc_message('PRIVATE', @_[KERNEL,SENDER,ARG0,ARG1,ARG2]);
}

sub irc_public {
  process_irc_message(0, @_[KERNEL,SENDER,ARG0,ARG1,ARG2]);
}

sub process_irc_message {
  my ($private, $kernel,$sender,$who,$where,$verbatim) = @_;
  return unless $kernel && $sender && $who && $where && $verbatim;

  my $nick = get_nick($who) or return;
  my $command = get_command($verbatim) or return;
  my $channel = $where->[0] or return;

  process_command($private, $command, $kernel, $sender,
                  $nick, $channel, $verbatim);

  undef;
}

sub sanitise_nick {
  my $nick = shift;
  return unless $nick;
  $nick =~ tr/a-zA-Z_0-9-//cd;
  return $nick;
}

sub get_nick {
  my $who = shift;
  my ($nick) = $who =~ /(.*?)!/;
  return $nick? sanitise_nick($nick) : undef;
}

sub get_command {
  my $verbatim_input = shift;
  my ($command) = $verbatim_input =~ /^(\S+)/;
  return $command;
}

sub post_message {
  my ($kernel, $sender, $channel, $msg) = @_;
  $msg = substr($msg, 0, $MAX_LENGTH) if length($msg) > $MAX_LENGTH;
  $kernel->post($sender => privmsg => $channel => $msg);
}

#######################################################################
# Commands

sub process_command {
  my ($private, $command, $kernel, $sender, $nick, $channel, $verbatim) = @_;

  if (substr($command, 0, 3) eq '@??')
  {
    $command = "@??";
  }
  elsif (substr($command, 0, 2) eq '@?')
  {
	$command = "@?";
  }

  my $proc = $COMMANDS{$command} or return;
  &$proc($private, $kernel, $sender, $nick, $channel, $verbatim);
}

sub find_named_nick {
  my ($default, $command) = @_;
  $default = sanitise_nick($default);
  my $named = (split ' ', $command)[1] or return $default;
  return sanitise_nick($named) || $default;
}

sub make_shellsafe($) {
  my $thing = shift;
  # Toss out everything that might confuse the shell. Spaces are ok,
  # quotes are not.
  $thing =~ tr/a-zA-Z0-9_+ -//cd;
  return $thing;
}

sub cmd_trunk_monsterinfo {
  my ($private, $kernel, $sender, $nick, $channel, $verbatim) = @_;
  my $monster_name = make_shellsafe(substr($verbatim, 3));
  my $monster_info = qx/monster-trunk '$monster_name'/;
  post_message($kernel, $sender, $private ? $nick : $channel, $monster_info);
}

sub cmd_monsterinfo {
  my ($private, $kernel, $sender, $nick, $channel, $verbatim) = @_;

  my $monster_name = make_shellsafe(substr($verbatim, 2));
  my $monster_info = `monster $monster_name`;
  post_message($kernel, $sender, $private ? $nick : $channel, $monster_info);
}

sub ttyrec_idle_time_seconds($) {
  my $filename = shift;
  my ($player, $ttyrec) = $filename =~ m{.*/([^:]+):(.*)$};
  $filename = "$DGL_TTYREC_DIR/$player/$ttyrec" if $player && $ttyrec;
  my $modtime = (stat $filename)[9];
  return time() - $modtime;
}

sub active_player_hash($$) {
  my ($player_name, $ttyrec_filename) = @_;
  return { player_name => $player_name,
           idle_seconds => ttyrec_idle_time_seconds($ttyrec_filename)
         };
}

sub find_active_players {
  my @player_where_list;
  find(sub {
         my $filename = $File::Find::name;
         if (-f $filename && $filename =~ /\.ttyrec$/) {
           my ($game_version, $player_name) =
             $filename =~ m{.*/([^/]+)/(.*?):};
           if ($game_version && $player_name) {
             push @player_where_list,
               active_player_hash($player_name, $filename);
           }
         }
       },
       $DGL_INPROGRESS_DIR);

  return @player_where_list;
}

sub compare_player_where_infos($$) {
  my ($wa, $wb) = @_;
  my $axl = $$wa{where}{xl} || 0;
  my $bxl = $$wb{where}{xl} || 0;
  return $axl != $bxl? $bxl - $axl :
         ($$wa{player_name} cmp $$wb{player_name});
}

sub sort_active_player_where_infos(@) {
  return sort { compare_player_where_infos($a, $b) } @_;
}

sub player_where_stats($) {
  my $wr = shift;
  return '' unless $wr;
  my $place = xlog_place($wr);
  return "L$$wr{xl} @ $place, T:$$wr{turn}";
}

sub player_where_brief($) {
  my $wref = shift;
  my $extended = player_where_stats($$wref{where}) || '';
  $extended = " ($extended)" if $extended;
  return "$$wref{player_name}$extended";
}

sub get_active_players_line($) {
  my $check_not_idle = shift;
  my @active_players = find_active_players();
  # If the command wanted active players, toss the idle layabouts.
  if ($check_not_idle) {
    @active_players =
      grep($$_{idle_seconds} < $INACTIVE_IDLE_CEILING_SECONDS,
           @active_players);
  }
  for my $r_player_info_hash (@active_players) {
    player_whereis_add_info($r_player_info_hash);
  }
  my @sorted_players = sort_active_player_where_infos(@active_players);
  my $message = join(", ", map(player_where_brief($_), @sorted_players));
  unless ($message) {
    my $qualifier = $check_not_idle? "active " : "";
    $message = "No ${qualifier}players.";
  }
  return $message;
}

sub cmd_players {
  my ($private, $kernel, $sender, $nick, $channel, $verbatim) = @_;
  my $check_not_idle = $verbatim =~ /-a/;
  my $message = get_active_players_line($check_not_idle);
  post_message($kernel, $sender, $private ? $nick : $channel, $message);
}

sub player_whereis_file($) {
  my $realnick = shift;
  my @crawldirs      = glob('/var/lib/dgamelaunch/crawl-*');
  my @whereis_path   = map { "$_/saves" } @crawldirs;

  my $where_file;
  my $final_where;

  for my $where_path (@whereis_path) {
    my @where_files = glob("$where_path/$realnick.where*");
    if (@where_files) {
      $where_file = $where_files[0];
      if (defined($final_where) && length($final_where) > 0) {
        if ((stat($final_where))[9] < (stat($where_file))[9]) {
          $final_where = $where_file;
        }
      }
      else {
        $final_where = $where_file;
      }
    }
  }
  undef $final_where unless defined($final_where) && length($final_where) > 0;
  return $final_where;
}

sub player_whereis_line($) {
  my $realnick = shift;
  my $where_file = player_whereis_file($realnick);

  return undef unless $where_file;

  open my $in, '<', $where_file or return undef;
  chomp( my $where = <$in> );
  close $in;

  return $where;
}

sub player_whereis_hash($) {
  my $nick = shift;
  my $line = player_whereis_line($nick);
  return $line ? demunge_xlogline($line) : undef;
}

sub player_whereis_add_info($) {
  my $phash = shift;
  $$phash{where} = player_whereis_hash($$phash{player_name});
}

sub cmd_whereis {
  my ($private, $kernel, $sender, $nick, $channel, $verbatim) = @_;

  # Get the nick to act on.
  my $realnick = find_named_nick($nick, $verbatim);
  my $where = player_whereis_hash($realnick);
  my $target = $private ? $nick : $channel;
  unless ($where) {
    post_message($kernel, $sender, $target,
                 "No where information for $realnick.");
    return;
  }
  show_where_information($kernel, $sender, $target, $where);
}

sub show_dump_file {
  my ($kernel, $sender, $target, $whereis_file) = @_;

  my ($gamedir, $player) =
    $whereis_file =~ m{/(crawl-\w+)[^/]*/saves/(\w+)[.]where};

  my %GAME_WEB_MAPPINGS =
    ( 'crawl-old' => '0.5',
      'crawl-rel' => '0.6',
      'crawl-anc' => 'ancient',
      'crawl-svn' => 'trunk' );

  my $dump_file = "/var/lib/dgamelaunch/$gamedir/morgue/$player/$player.txt";

  unless (-f $dump_file) {
    post_message($kernel, $sender, $target,
                 "Can't find character dump for $player.");
    return;
  }

  my $web_morgue_dir = $GAME_WEB_MAPPINGS{$gamedir};
  unless ($web_morgue_dir) {
    post_message($kernel, $sender, $target,
                 "Can't find URL base for character dump.");
    return;
  }

  post_message($kernel, $sender, $target,
               "$MORGUE_BASE_URL/$web_morgue_dir/$player/$player.txt");
}

sub cmd_dump {
  my ($private, $kernel, $sender, $nick, $channel, $verbatim) = @_;

  my $realnick = find_named_nick($nick, $verbatim);
  my $whereis_file = player_whereis_file($realnick);
  my $target = $private ? $nick : $channel;
  unless ($whereis_file) {
    post_message($kernel, $sender, $target,
                 "No where information for $realnick.");
    return;
  }
  show_dump_file($kernel, $sender, $target, $whereis_file);
}

sub format_crawl_date {
  my $date = shift;
  return '' unless $date;
  my ($year, $mon, $day) = $date =~ /(.{4})(.{2})(.{2})/;
  return '' unless $year && $mon && $day;
  $mon++;
  return sprintf("%04d-%02d-%02d", $year, $mon, $day);
}

sub show_where_information {
  my ($kernel, $sender, $channel, $wref) = @_;
  return unless $wref;

  my %wref = %$wref;

  my $place = xlog_place($wref);
  my $preposition = index($place, ':') != -1? " on" : " in";
  $place = "the $place" if $place =~ 'Abyss' || $place eq 'Temple';
  $place = " $place";

  my $punctuation = '.';
  my $date = ' on ' . format_crawl_date($wref{time});

  my $turn = " after $wref{turn} turns";
  chop $turn if $wref{turn} == 1;

  my $what = $wref{status};
  my $msg;
  if ($what eq 'active') {
    $what = 'is currently';
    $date = '';
  }
  elsif ($what eq 'won') {
    $punctuation = '!';
    $preposition = $place = '';
  }
  elsif ($what eq 'bailed out') {
    $what = 'got out of the dungeon alive';
    $preposition = $place = '';
  }
  $what = " $what";

  my $god = $wref{god}? ", a worshipper of $wref{god}," : "";
  unless ($msg) {
    $msg = "$wref{name} the $wref{title} (L$wref{xl} $wref{char})" .
           "$god$what$preposition$place$date$turn$punctuation";
  }
  post_message($kernel, $sender, $channel, $msg);
}

#######################################################################
# Imports

sub pretty_print
{
  my $game_ref = shift;

  my $loc_string = "";
  my $place = xlog_place($game_ref);
  if ($game_ref->{ltyp} ne 'D' || $place !~ ':')
  {
    $loc_string = " in $place";
  }
  else
  {
    if ($game_ref->{br} eq 'blade' or $game_ref->{br} eq 'temple' or $game_ref->{br} eq 'hell')
    {
      $loc_string = " in $place";
    }
    else
    {
      $loc_string = " on $place";
    }
  }
  $loc_string = "" # For escapes of the dungeon, so it doesn't print the loc
    if $game_ref->{ktyp} eq 'winning' or $game_ref->{ktyp} eq 'leaving';

  $game_ref->{end} =~ /^(\d{4})(\d{2})(\d{2})/;
  my $death_date = " on " . $1 . "-" . sprintf("%02d", $2 + 1) . "-" . $3;

  my $deathmsg = $game_ref->{vmsg} || $game_ref->{tmsg};
  $deathmsg =~ s/!$//;
  sprintf '%s the %s (L%d %s)%s, %s%s%s, with %d point%s after %d turn%s and %s.',
      $game_ref->{name},
      $game_ref->{title},
      $game_ref->{xl},
      $game_ref->{char},
      exists $game_ref->{god} ? ", worshipper of $game_ref->{god}" : '',
      $deathmsg,
      $loc_string,
      $death_date,
      $game_ref->{sc},
      $game_ref->{sc} == 1 ? '' : 's',
      $game_ref->{turn},
      $game_ref->{turn} == 1 ? '' : 's',
      serialize_time($game_ref->{dur})
}

sub demunge_xlogline
{
  my $line = shift;
  return {} if $line eq '';
  my %game;

  chomp $line;
  die "Unable to handle internal newlines." if $line =~ y/\n//;
  $line =~ s/::/\n\n/g;

  while ($line =~ /\G(\w+)=([^:]*)(?::(?=[^:])|$)/cg)
  {
    my ($key, $value) = ($1, $2);
    $value =~ s/\n\n/:/g;
    $game{$key} = $value;
  }

  if (!defined(pos($line)) || pos($line) != length($line))
  {
    my $pos = defined(pos($line)) ? "Problem started at position " . pos($line) . "." : "Regex doesn't match.";
    die "Unable to demunge_xlogline($line).\n$pos";
  }

  return \%game;
}

sub serialize_time
{
  my $seconds = int shift;
  my $long = shift;

  if (not $long)
  {
    my $hours = int($seconds/3600);
    $seconds %= 3600;
    my $minutes = int($seconds/60);
    $seconds %= 60;

    return sprintf "%d:%02d:%02d", $hours, $minutes, $seconds;
  }

  my $minutes = int($seconds / 60);
  $seconds %= 60;
  my $hours = int($minutes / 60);
  $minutes %= 60;
  my $days = int($hours / 24);
  $hours %= 24;
  my $weeks = int($days / 7);
  $days %= 7;
  my $years = int($weeks / 52);
  $weeks %= 52;

  my @fields;
  push @fields, "about ${years}y" if $years;
  push @fields, "${weeks}w"       if $weeks;
  push @fields, "${days}d"        if $days;
  push @fields, "${hours}h"       if $hours;
  push @fields, "${minutes}m"     if $minutes;
  push @fields, "${seconds}s"     if $seconds;

  return join ' ', @fields if @fields;
  return '0s';
}
