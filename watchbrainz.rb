#!/usr/bin/ruby

# Copyright 2013 Daniel Erat <dan@erat.org>
# All rights reserved.

# Search for modules in the lib/ subdirectory.
$:.unshift(File.dirname(__FILE__) + '/lib')

require 'musicbrainz'
require 'optparse'
require 'sqlite3'

# Database schema.
=begin
CREATE TABLE Artists (
  ArtistId VARCHAR(36) NOT NULL,
  Name TEXT NOT NULL,
  Active BOOLEAN NOT NULL DEFAULT 1,
  PRIMARY KEY (ArtistId));
CREATE INDEX Active ON Artists (Active);

CREATE TABLE ReleaseGroups (
  ReleaseGroupId VARCHAR(36) NOT NULL,
  ArtistId VARCHAR(36) NOT NULL,
  Title TEXT NOT NULL,
  Type TEXT NOT NULL,
  ReleaseDate VARCHAR(10) NOT NULL,
  AddTime INTEGER NOT NULL,
  PRIMARY KEY (ReleaseGroupId));
CREATE INDEX AddTime ON ReleaseGroups (AddTime);
=end

def add_artist(db, artist_name)
  artist = MusicBrainz::Artist.find_by_name(artist_name)
  return false if !artist
  db.execute('INSERT INTO Artists(ArtistId, Name, Active) VALUES(?, ?, 1)', artist.id, artist_name)
  true
end

def get_new_releases(db)
  db.execute('SELECT ArtistId, Name FROM Artists WHERE Active = 1') do |row|
    artist_id, artist_name = row
    artist = MusicBrainz::Artist.find(artist_id)
    known_release_group_ids = db.execute('SELECT ReleaseGroupId FROM ReleaseGroups WHERE ArtistId = ?', artist_id).map {|r| r[0] }
    artist.release_groups.each do |release_group|
      next if !known_release_group_ids.grep(release_group.id).empty?

      title = release_group.title
      title += " (#{release_group.desc})" if !release_group.desc.empty?
      db.execute('INSERT INTO ReleaseGroups ' +
                 '(ReleaseGroupId, ArtistId, Title, Type, ReleaseDate, AddTime) ' +
                 'VALUES(?, ?, ?, ?, ?, ?)',
                 release_group.id, artist_id, title, release_group.type, release_group.first_release_date.strftime('%Y-%m-%d'), Time.now.to_i)
    end
  end
end

def main
  db_filename = 'watchbrainz.db'
  add_artists_from_stdin = false
  artist_to_add = nil

  opts = OptionParser.new
  opts.banner = "Usage: #$0 [options]"
  opts.on('--add [ARTIST]', 'Artist to add (reads from stdin without argument)') do |artist|
    if artist
      artist_to_add = artist
    else
      add_artists_from_stdin = true
    end
  end
  opts.on('--db FILE', 'sqlite3 database filename') { |db_filename| }
  opts.parse!

  MusicBrainz.configure do |c|
    c.app_name = 'watchbrainz'
    c.app_version = '0.1'
    c.contact = 'dan@erat.org'
  end

  db = SQLite3::Database.new(db_filename)

  artists_to_add = []
  if add_artists_from_stdin
    artists_to_add = STDIN.read.split("\n").map {|a| a.strip }
  elsif artist_to_add
    artists_to_add << artist_to_add
  end

  if !artists_to_add.empty?
    artists_to_add.each {|artist| add_artist(db, artist) or abort("Unable to add artist \"#{artist}\"") }
  else
    get_new_releases(db)
  end

  db.close
end

main
