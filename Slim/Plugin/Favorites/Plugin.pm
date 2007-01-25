package Slim::Plugin::Favorites::Plugin;

# $Id$

# A Favorites implementation which stores favorites as opml files and allows
# the favorites list to be edited from the web interface

# Includes code from the MyPicks plugin by Adrian Smith and Bryan Alton

# This code is derived from code with the following copyright message:
#
# SlimServer Copyright (C) 2005 Sean Adams, Slim Devices Inc.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

use strict;

use base qw(Slim::Plugin::Base);

use Slim::Buttons::Common;
use Slim::Web::XMLBrowser;
use Slim::Utils::Favorites;
use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Strings qw(string);

use Slim::Plugin::Favorites::Opml;
use Slim::Plugin::Favorites::OpmlFavorites;
use Slim::Plugin::Favorites::Directory;
use Slim::Plugin::Favorites::Settings;
use Slim::Plugin::Favorites::Playlist;

my $log = logger('favorites');

sub initPlugin {
	my $class = shift;

	$class->SUPER::initPlugin(@_);

	Slim::Plugin::Favorites::Settings->new;

	# register ourselves as the editor for favorites.opml in xmlbrowser
	Slim::Web::XMLBrowser::registerEditor( qr/^file:\/\/.*favorites\.opml$/, 'plugins/Favorites/edit.html', 'PLUGIN_FAVORITES_EDITOR' );

	# register ourselves as the editor for other opml files with different title
	Slim::Web::XMLBrowser::registerEditor( qr/^file:\/\/.*\.opml$/, 'plugins/Favorites/edit.html', 'PLUGIN_FAVORITES_PLAYLIST_EDITOR' );

	# register opml based favorites handler
	Slim::Utils::Favorites::registerFavoritesClassName('Slim::Plugin::Favorites::OpmlFavorites');

	# register handler for playing favorites by remote hot button
	Slim::Buttons::Common::setFunction('playFavorite', \&playFavorite);
}

sub setMode {
	my $class = shift;
    my $client = shift;
    my $method = shift;

    if ( $method eq 'pop' ) {
        Slim::Buttons::Common::popMode($client);
        return;
    }

	my $file = Slim::Plugin::Favorites::OpmlFavorites->new->filename;

	if (-r $file) {

		# use INPUT.Choice to display the list of feeds
		my %params = (
			header   => 'PLUGIN_FAVORITES_LOADING',
			modeName => 'Favorites.Browser',
			url      => Slim::Utils::Misc::fileURLFromPath($file),
			title    => $client->string('FAVORITES'),
		   );

		Slim::Buttons::Common::pushMode($client, 'xmlbrowser', \%params);

		# we'll handle the push in a callback
		$client->modeParam('handledTransition',1)

	} else {

		$client->lines(\&errorLines);
	}
}

sub errorLines {
	return { 'line' => [string('FAVORITES'), string('PLUGIN_FAVORITES_NOFILE')] };
}

sub playFavorite {
	my $client = shift;
	my $button = shift;
	my $digit  = shift;

	if ($digit == 0) {
		$digit = 10;
	}

	my ($url, $title) = Slim::Plugin::Favorites::OpmlFavorites->new->findByClientAndId($client, $digit);

	if (!$url) {

		$client->showBriefly({
			 'line' => [ sprintf($client->string('FAVORITES_NOT_DEFINED'), $digit) ],
		});

		return;

	} else {

		$log->info("Playing favorite number $digit $title $url");

		Slim::Music::Info::setTitle($url, $title);

		$client->execute(['playlist', 'play', $url]);
	}
}

sub webPages {
	my $class = shift;

	Slim::Web::HTTP::addPageFunction('plugins/Favorites/index.html', \&indexHandler);
	Slim::Web::HTTP::addPageFunction('plugins/Favorites/edit.html', \&editHandler);

	Slim::Web::Pages->addPageLinks('browse', { 'FAVORITES' => 'plugins/Favorites/index.html' });

	addEditLink();
}

sub addEditLink {
	my $enabled = Slim::Utils::Prefs::get('plugin_favorites_opmleditor');

	Slim::Web::Pages->addPageLinks('plugins', {	'PLUGIN_FAVORITES_PLAYLIST_EDITOR' => $enabled ? 'plugins/Favorites/edit.html?new=1' : undef });
}

sub indexHandler {
	my $file = Slim::Plugin::Favorites::OpmlFavorites->new->filename;

	if (-r $file) {

		Slim::Web::XMLBrowser->handleWebIndex( {
			feed   => Slim::Utils::Misc::fileURLFromPath($file),
			title  => 'FAVORITES',
			args   => \@_
		} );
	}
}

my $opml;
my $level = 0;
my $currentLevel;
my @prevLevels;
my $deleted;
my $changed;

sub editHandler {
	my ($client, $params) = @_;

	my $edit;     # index of entry to edit if set
	my $errorMsg; # error message to display at top of page

	# Debug:
	#for my $key (keys %$params) {
	#	print "Key: $key, Val: ".$params->{$key}."\n";
	#}

	if ($params->{'new'} && $params->{'new'} == 1) {
		$opml = Slim::Plugin::Favorites::Opml->new;
		$level = 0;
		$currentLevel = $opml->toplevel;
		@prevLevels = ();
		$deleted = undef;
		$changed = undef;
	}

	if ($params->{'title'}) {
		$opml->title( $params->{'title'} );
		$changed = 1;
	}

	if ($params->{'savefile'} || $params->{'savechanged'}) {
		$opml->filename($params->{'filename'}) if $params->{'savefile'};
		$opml->save;
		$changed = undef unless $opml->error;
	}

	if ($params->{'loadfile'}) {
		$opml->load($params->{'filename'});
		$level = 0;
		$currentLevel = $opml->toplevel;
		@prevLevels = ();
		$deleted = undef;
		$changed = undef;
	}

	if ($params->{'importfile'}) {
		my $filename = $params->{'filename'};
		my $playlist;

		if ($filename =~ /\.opml/) {
			$playlist = Slim::Plugin::Favorites::Opml->new($filename)->toplevel;
		} else {
			$playlist = Slim::Plugin::Favorites::Playlist->read($filename);
		}

		if ($playlist) {
			for my $entry (@$playlist) {
				push @$currentLevel, $entry;
			}
			$changed = 1;
		} else {
			$params->{'errormsg'} = string('PLUGIN_FAVORITES_IMPORTERROR') . " " . $filename;
		}
	}

	if ($params->{'url'}) {
		$opml = Slim::Plugin::Favorites::OpmlFavorites->new;

		if (Slim::Utils::Misc::pathFromFileURL($params->{'url'}) ne $opml->filename) {
			# if url is not for favorite file use opml direct
			$opml = Slim::Plugin::Favorites::Opml->new( $params->{'url'} );
		}

		$level = 0;
		$currentLevel = $opml->toplevel;
		@prevLevels = ();
		$deleted = undef;
		$changed = undef;

		if ($params->{'index'}) {
			for my $i (split(/\./, $params->{'index'})) {
				if (defined @$currentLevel[$i]) {
					$prevLevels[ $level++ ] = {
						'ref'   => $currentLevel,
						'title' => @$currentLevel[$i]->{'text'},
					};
					$currentLevel = @$currentLevel[$i]->{'outline'};
				}
			}
		}
	}

	if ($params->{'newentrymore'}) {

		$params->{'newentry'} = 1;

		my $sourceInd = 1;

		for my $infoSource (Slim::Utils::Prefs::getArray('plugin_favorites_directories')) {

			my $directory = Slim::Plugin::Favorites::Directory->new($infoSource);

			my $extEntry = {
				'ind'   => $sourceInd++,
				'title' => $directory->title
			};

			my $catInd = 1;

			for my $cat (@{$directory->categories}) {
				push @{$extEntry->{'menu'}}, {
					'ind'  => $catInd++,
					'name' => $cat,
					'opts' => $directory->itemNames($cat),
				};
			}

			push @{$params->{'external'}}, $extEntry;
		}
	}

	if (my $action = $params->{'action'}) {

		if ($action eq 'descend') {

			$prevLevels[ $level++ ] = {
				'ref'   => $currentLevel,
				'title' => @$currentLevel[$params->{'entry'}]->{'text'},
			};

			$currentLevel = @$currentLevel[$params->{'entry'}]->{'outline'};

		}

		if ($action eq 'ascend') {

			my $pop = defined ($params->{'levels'}) ? $params->{'levels'} : 1;

			while ($pop) {
				$currentLevel = $prevLevels[ --$level ]->{'ref'} if $level > 0;
				--$pop;
			}
		}

		if ($action eq 'edit') {
			$edit = $params->{'entry'};
		}

		if ($action eq 'edittitle') {
			$params->{'edittitle'} = 1;
		}

		if ($action eq 'delete') {
			$deleted = splice @$currentLevel, $params->{'entry'}, 1;
			$changed = 1;
		}

		if ($action eq 'forgetdelete') {
			$deleted = undef;
		}

		if ($action eq 'insert' && $deleted) {
			push @$currentLevel, $deleted;
			$deleted = undef;
			$changed = 1;
		}

		if ($action eq 'movedown') {
			my $entry = splice @$currentLevel, $params->{'entry'}, 1;
			splice @$currentLevel, $params->{'entry'} + 1, 0, $entry;
			$changed = 1;
		}

		if ($action eq 'moveup' && $params->{'entry'} > 0) {
			my $entry = splice @$currentLevel, $params->{'entry'}, 1;
			splice @$currentLevel, $params->{'entry'} - 1, 0, $entry;
			$changed = 1;
		}

		if ($action =~ /play|add/ && $client) {
			my $stream = @$currentLevel[$params->{'entry'}]->{'URL'};
			my $title  = @$currentLevel[$params->{'entry'}]->{'text'};
			Slim::Music::Info::setTitle($stream, $title);
			$client->execute(['playlist', $action, $stream]);
		}
	}

	if ($params->{'editset'} && defined $params->{'entry'}) {
		my $entry = @$currentLevel[$params->{'entry'}];
		$entry->{'text'} = $params->{'entrytitle'};
		$entry->{'URL'} = $params->{'entryurl'} if defined($params->{'entryurl'});
		$changed = 1;
	}

	if ($params->{'newmenu'}) {
		push @$currentLevel, {
			'text'   => $params->{'menutitle'},
			'outline'=> [],
		};
		$changed = 1;
	}

	if ($params->{'newstream'}) {
		push @$currentLevel,{
			'text' => $params->{'streamtitle'},
			'URL'  => $params->{'streamurl'},
			'type' => 'audio',
		};
		$changed = 1;
	}

	if ($params->{'newopmlmenu'}) {
		push @$currentLevel, {
			'text' => $params->{'opmlmenutitle'},
			'URL'  => $params->{'opmlmenuurl'},
		};
		$changed = 1;
	}

	# search for external information source selection in key: extsel.$sourceIndex.$categoryIndex
	if ($params->{'url_query'} =~ /extsel\./) {
		for my $key (keys %$params) {
			if ($key =~ /^extsel\.(\d+)\.(\d+)/) {
				my $source = Slim::Utils::Prefs::getInd('plugin_favorites_directories', $1 - 1);
				my $name = $params->{"extval.$1.$2"};
				my $entry = Slim::Plugin::Favorites::Directory->new($source)->item($2 - 1, $name);
				push @$currentLevel, $entry if $entry;
				$changed = 1;
				last;
			}
		}
	}

	if ($params->{'load'}  ) { $params->{'loaddialog'} = 1;   }
	if ($params->{'save'}  ) { $params->{'savedialog'} = 1;   }
	if ($params->{'import'}) { $params->{'importdialog'} = 1; }

	# set params for page build
	if (defined $opml) {
		$params->{'favorites'} = $opml->isa('Slim::Plugin::Favorites::OpmlFavorites');
		$params->{'title'}     = $opml->title;
		$params->{'filename'}  = $opml->filename;
	}

	$params->{'previous'}  = ($level > 0);
	$params->{'deleted'}   = defined $deleted ? $deleted->{'text'} : undef;
	$params->{'changed' }  = $changed;
	$params->{'advanced'}  = Slim::Utils::Prefs::get('plugin_favorites_advanced');

	if ($opml && $opml->error) {
		$params->{'errormsg'} = string('PLUGIN_FAVORITES_' . $opml->error) . " " . $opml->filename;
		$opml->clearerror;
	}

	my @entries;
	my $index = 0;

	foreach my $opmlEntry (@$currentLevel) {
		push @entries, {
			'title'   => $opmlEntry->{'text'} || '',
			'url'     => $opmlEntry->{'URL'} || '',
			'audio'   => (defined $opmlEntry->{'type'} && $opmlEntry->{'type'} eq 'audio'),
			'outline' => $opmlEntry->{'outline'},
			'edit'    => (defined $edit && $edit == $index),
			'index'   => $index++,
		};
	}

	$params->{'entries'} = \@entries;

	push @{$params->{'pwd_list'}}, {
		'title' => $opml && $opml->title || string('PLUGIN_FAVORITES_EDITOR'),
		'href'  => 'href="edit.html?action=ascend&levels=' . $level . '"',
	};

	for (my $i = 1; $i <= $level; $i++) {
		push @{$params->{'pwd_list'}}, {
			'title' => $prevLevels[ $i - 1 ]->{'title'},
			'href'  => 'href="edit.html?action=ascend&levels=' . ($level - $i) . '"',
		};
	}

	return Slim::Web::HTTP::filltemplatefile('plugins/Favorites/edit.html', $params);
}

1;
