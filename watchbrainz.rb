#!/usr/bin/ruby

# Copyright 2013 Daniel Erat <dan@erat.org>
# All rights reserved.

# Search for modules in the lib/ subdirectory.
$:.unshift(File.dirname(__FILE__) + '/lib')

require 'logger'
require 'musicbrainz'
require 'optparse'
require 'rss'
require 'sqlite3'

FEED_SIZE = 20

$logger = Logger.new($stderr)

def date_is_unset?(date)
  date.year == 2030 && date.month == 12 && date.day == 31
end

def time_to_rfc3339(time)
  time.utc.strftime('%FT%TZ')
end

def get_year(date)
  date_is_unset?(date) ? 'present' : date.year.to_s
end

def get_artist_id_from_database(db, artist_name)
  db.execute('SELECT ArtistId FROM Artists WHERE Name = ?', artist_name).each {|row| return row[0] }
  nil
end

def init_db(db)
  db.execute <<-EOF
    CREATE TABLE Artists (
      ArtistId VARCHAR(36) NOT NULL,
      Name TEXT NOT NULL,
      Active BOOLEAN NOT NULL DEFAULT 1,
      PRIMARY KEY (ArtistId))
    EOF
  db.execute <<-EOF
    CREATE INDEX Active ON Artists (Active)
    EOF
  db.execute <<-EOF
    CREATE TABLE ReleaseGroups (
      ReleaseGroupId VARCHAR(36) NOT NULL,
      ArtistId VARCHAR(36) NOT NULL,
      Title TEXT NOT NULL,
      Type TEXT NOT NULL,
      ReleaseDate VARCHAR(10) NOT NULL,
      AddTime INTEGER NOT NULL,
      PRIMARY KEY (ReleaseGroupId))
    EOF
  db.execute <<-EOF
    CREATE INDEX AddTime ON ReleaseGroups (AddTime)
    EOF
end

def add_artist(db, artist_name)
  artist_id = get_artist_id_from_database(db, artist_name)
  if artist_id
    db.execute('UPDATE Artists SET Active = 1 WHERE ArtistId = ?', artist_id)
    $logger.info("Set artist \"#{artist_name}\" to active")
    return true
  end

  artist = MusicBrainz::Artist.find_by_name(artist_name)
  if !artist
    $logger.warn("Unable to find artist \"#{artist_name}\"")
    return false
  end

  db.execute('INSERT INTO Artists(ArtistId, Name, Active) VALUES(?, ?, 1)', artist.id, artist_name)
  $logger.info("Inserted artist \"#{artist_name}\" (#{artist.type} from #{artist.country} " +
               "active #{get_year(artist.date_begin)}-#{get_year(artist.date_end)})")
  true
end

def remove_artist(db, artist_name)
  artist_id = get_artist_id_from_database(db, artist_name)
  if !artist_id
    $logger.warn("Artist \"#{artist_name}\" not present in database")
  else
    db.execute('UPDATE Artists SET Active = 0 WHERE Name = ?', artist_name)
    $logger.info("Set artist \"#{artist_name}\" to inactive")
  end
end

def list_active_artists(db)
  db.execute('SELECT Name FROM Artists WHERE Active = 1 ORDER BY Name ASC') {|r| puts r[0] }
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
      $logger.info("Added release group \"#{title}\" for artist #{artist_name}")
    end
  end
end

def write_feed(db, filename)
  rss = RSS::Maker.make('atom') do |maker|
    maker.channel.author = 'Daniel Erat'
    maker.channel.updated = time_to_rfc3339(Time.now)
    maker.channel.title = 'New Music Releases'
    maker.channel.link = 'http://www.erat.org/'
    maker.channel.description = 'Release groups recently added to MusicBrainz'
    maker.channel.id = 'http://www.erat.org/'

    db.execute('SELECT a.ArtistId, a.Name, r.ReleaseGroupId, r.Title, r.Type, r.ReleaseDate, r.AddTime ' +
               'FROM Artists a INNER JOIN ReleaseGroups r ON(a.ArtistId = r.ArtistId) ' +
               'WHERE a.Active = 1 ' +
               'ORDER BY r.AddTime DESC ' +
               'LIMIT ?', FEED_SIZE).each do |artist_id, name, release_group_id, title, type, release_date, add_time|
      artist_url = "https://musicbrainz.org/artist/#{artist_id}"
      release_group_url = "https://musicbrainz.org/release-group/#{release_group_id}"
      maker.items.new_item do |item|
        item.id = release_group_id
        item.title = "#{release_date}: #{name} - #{title}"
        item.link = release_group_url
        item.updated = time_to_rfc3339(Time.at(add_time))
        # TODO: No idea how to include content in RSS::Maker. Zero docs.
        # "<a href=\"#{artist_url}\">#{name}</a> - <a href=\"#{release_group_url}\">#{title}</a>"
      end
    end
  end
  File.open(filename, 'w') {|f| f.write(rss) }
end

def read_artists(arg)
  arg ? [arg] : STDIN.read.split("\n").map {|a| a.strip }
end

def main
  db_filename = 'watchbrainz.db'
  artists_to_add = []
  artists_to_remove = []
  should_init = false
  should_list = false

  opts = OptionParser.new
  opts.banner = "Usage: #$0 [options]"
  opts.on('--add [ARTIST]', 'Artist to add (reads one-per-line from stdin without argument)') {|v| artists_to_add = read_artists(v) }
  opts.on('--db FILE', 'sqlite3 database filename') { |db_filename| }
  opts.on('--init', 'Initialize database') { should_init = true }
  opts.on('--list', 'List active artists') { should_list = true }
  opts.on('--quiet', 'Suppress informational logging') { $logger.level = Logger::WARN }
  opts.on('--remove [ARTIST]', 'Artist to add (reads one-per-line from stdin without argument)') {|v| artists_to_remove = read_artists(v) }
  opts.parse!

  MusicBrainz.configure do |c|
    c.app_name = 'watchbrainz'
    c.app_version = '0.1'
    c.contact = 'dan@erat.org'
  end

  db = SQLite3::Database.new(db_filename)
  init_db(db) if should_init

  artists_to_add.each {|a| add_artist(db, a) }
  artists_to_remove.each {|a| remove_artist(db, a) }
  list_active_artists(db) if should_list

  #get_new_releases(db)
  write_feed(db, 'releases.xml')

  db.close
end

main
