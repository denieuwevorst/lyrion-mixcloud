use strict;
use warnings;
use FindBin;
use Test::More;

# Keep the real plugin/feed logic; replace only its LMS and network dependencies.
BEGIN {
	package Slim::Plugin::OPMLBased;
	sub initPlugin {}
	sub _pluginDataFor { 'mixcloud-direct.png' }
	$INC{'Slim/Plugin/OPMLBased.pm'} = __FILE__;

	package Slim::Utils::Log;
	sub addLogCategory { bless {}, __PACKAGE__ }
	$INC{'Slim/Utils/Log.pm'} = __FILE__;

	package Slim::Utils::Prefs;
	our %values;
	sub import { no strict 'refs'; *{caller() . '::preferences'} = sub { bless {}, __PACKAGE__ } }
	sub init {
		my ($self, $defaults) = @_;
		for (keys %$defaults) { $values{$_} = $defaults->{$_} unless exists $values{$_} }
	}
	sub get { $values{$_[1]} }
	sub set { $values{$_[1]} = $_[2] }
	$INC{'Slim/Utils/Prefs.pm'} = __FILE__;

	package Slim::Utils::Strings;
	sub import { no strict 'refs'; *{caller() . '::cstring'} = sub { $_[1] } }
	$INC{'Slim/Utils/Strings.pm'} = __FILE__;

	package Slim::Player::ProtocolHandlers;
	our (%protocols, @urls);
	sub registerHandler { $protocols{$_[1]} = $_[2] }
	sub registerURLHandler { push @urls, [$_[1], $_[2]] }
	sub handlerForURL {
		my ($class, $url) = @_;
		for (@urls) { return $_->[1] if $url =~ $_->[0] }
		return $protocols{($url =~ /^([^:]+):/)[0]};
	}

	package Plugins::MixcloudDirect::API;
	our (%uploads, %lives, @requests);
	sub getLives { $_[2]->(\%lives) }
	sub get { push @requests, [$_[1], $_[3]]; $_[2]->({ data => $uploads{$_[1]} || [] }) }
	sub normalize { $_[1] }
	$INC{'Plugins/MixcloudDirect/API.pm'} = __FILE__;
	$INC{'Plugins/MixcloudDirect/ProtocolHandler.pm'} = __FILE__;

	package main;
	sub WEBUI { 0 }
	sub INFOLOG { 0 }
}

require "$FindBin::Bin/../src/MixcloudDirect/Util.pm";
BEGIN { $INC{'Plugins/MixcloudDirect/Util.pm'} = "$FindBin::Bin/../src/MixcloudDirect/Util.pm" }
require "$FindBin::Bin/../src/MixcloudDirect/Plugin.pm";

my $plugin = 'Plugins::MixcloudDirect::Plugin';
$plugin->initPlugin;
$Slim::Utils::Prefs::values{follows} = { alice => { name => 'Alice' } };

sub feed_row {
	my $feed;
	Plugins::MixcloudDirect::Plugin::followedMenu(undef, sub { $feed = shift }, {}, {});
	return (grep { !ref($_->{url}) && ($_->{url} || '') eq 'mcdirect://followed' } @{$feed->{items}})[0];
}

my $row = feed_row();
ok($row, 'followed feed can be saved as a native favourite');
is($row->{type}, 'playlist', 'feed collection receives native LMS preset and context actions');
is($row->{favorites_type}, 'link', 'favourite is saved as a browse link, not an audio show');
ok(!$row->{play}, 'feed row does not override native link playback handling');
ok(!$row->{on_select}, 'opening the feed does not become touch-to-play');
ok(!ref($row->{url}), 'feed URL is serializable for plain-list clients too');

# Persist just the fields LMS saves, without a callback, menu position or user list.
my $saved = { url => $row->{url}, type => $row->{favorites_type}, name => $row->{name} };
my $handler = Slim::Player::ProtocolHandlers->handlerForURL($saved->{url});
is($handler, $plugin, 'saved URL selects the feed resolver');
is(Slim::Player::ProtocolHandlers->handlerForURL('mcdirect://alice/show'),
	'Plugins::MixcloudDirect::ProtocolHandler', 'show URLs retain their playback handler');
is(Slim::Player::ProtocolHandlers->handlerForURL('mcdirect://live/alice'),
	'Plugins::MixcloudDirect::ProtocolHandler', 'live URLs retain their playback handler');

my $show = { title => 'Old upload', owner => 'Alice', user => 'alice', slug => 'old', created => '2026-11-01' };
$Plugins::MixcloudDirect::API::uploads{'/alice/cloudcasts/?limit=10'} = [$show];
sub reopen {
	my $feed;
	$handler->explodePlaylist(undef, $saved->{url}, sub { $feed = shift });
	return $feed;
}
my $opened = reopen();
is($opened->{type}, 'opml', 'URL resolver returns a complete OPML feed to LMS');
is($opened->{title}, $saved->{name}, 'reopened feed retains its localized title');
is($opened->{items}[0]{url}, 'mcdirect://alice/old', 'saved favourite opens the current feed');

$Plugins::MixcloudDirect::API::lives{alice} = { live => 1, user => 'alice', owner => 'Alice' };
is(feed_row()->{url}, $saved->{url}, 'live rows do not change the saved feed address');

$Slim::Utils::Prefs::values{follows} = { bob => { name => 'Bob' } };
$Plugins::MixcloudDirect::API::uploads{'/bob/cloudcasts/?limit=10'} = [
	{ %$show, title => 'Older', owner => 'Bob', user => 'bob', slug => 'older' },
	{ %$show, title => 'Newest', owner => 'Bob', user => 'bob', slug => 'newest', created => '2026-11-21' },
	{ %$show, user => 'bob', slug => 'exclusive', exclusive => 1, created => '2026-11-22' },
];
@Plugins::MixcloudDirect::API::requests = ();
is_deeply([map { $_->{url} } @{reopen()->{items}}],
	['mcdirect://bob/newest', 'mcdirect://bob/older'],
	'reopening uses changed follows, newest first, with Select shows still hidden');
is_deeply(\@Plugins::MixcloudDirect::API::requests, [['/bob/cloudcasts/?limit=10', 900]],
	'only current follows are fetched, with the existing 15-minute cache');

# Re-registering after restart must resolve the same persisted URL.
@Slim::Player::ProtocolHandlers::urls = ();
$plugin->initPlugin;
$handler = Slim::Player::ProtocolHandlers->handlerForURL($saved->{url});
is(reopen()->{items}[0]{url}, 'mcdirect://bob/newest', 'saved favourite survives handler reinitialization');

$Slim::Utils::Prefs::values{follows} = {};
@Plugins::MixcloudDirect::API::requests = ();
is(reopen()->{items}[0]{name}, 'PLUGIN_MIXCLOUDDIRECT_EMPTY', 'unfollowing everyone produces the existing empty feed');
is(scalar @Plugins::MixcloudDirect::API::requests, 0, 'empty follows do not fetch stale users');

done_testing;
