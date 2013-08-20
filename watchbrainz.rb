#!/usr/bin/ruby

# Copyright 2013 Daniel Erat <dan@erat.org>
# All rights reserved.

# Search for modules in the lib/ subdirectory.
$:.unshift(File.dirname(__FILE__) + '/lib')

require 'musicbrainz'
require 'sqlite3'

# Database schema.
=begin
CREATE TABLE Artists (
  ArtistId VARCHAR(36) NOT NULL,
  Name TEXT NOT NULL,
  Active BOOLEAN NOT NULL DEFAULT 1,
  PRIMARY KEY (ArtistId));
CREATE TABLE ReleaseGroups (
  ReleaseGroupId VARCHAR(36) NOT NULL,
  ArtistId VARCHAR(36) NOT NULL,
  Title TEXT NOT NULL,
  ReleaseTime INTEGER NOT NULL,
  AddTime INTEGER NOT NULL,
  PRIMARY KEY (ReleaseGroupId));
CREATE INDEX AddTime ON ReleaseGroups (AddTime);
=end

DATABASE_FILENAME = 'watchbrainz.db'

MusicBrainz.configure do |c|
  c.app_name = 'watchbrainz'
  c.app_version = '0.1'
  c.contact = 'dan@erat.org'
end

db = SQLite3::Database.new(DATABASE_FILENAME)

db.execute('SELECT ArtistId, Name FROM Artists WHERE Active = 1') do |row|
  artist_id, artist_name = row
  artist = MusicBrainz::Artist.find(artist_id)
  known_release_group_ids = db.execute('SELECT ReleaseGroupId FROM ReleaseGroups WHERE ArtistId = ?', artist_id).map {|r| r[0] }
  artist.release_groups.each do |release_group|
    next if !known_release_group_ids.grep(release_group.id).empty?

    title = release_group.title
    title += " (#{release_group.desc})" if !release_group.desc.empty?
    db.execute('INSERT INTO ReleaseGroups ' +
               '(ReleaseGroupId, ArtistId, Title, ReleaseTime, AddTime) ' +
               'VALUES(?, ?, ?, ?, ?)',
               release_group.id, artist_id, title, release_group.first_release_date.to_time.to_i, Time.now.to_i)
  end
end

db.close
