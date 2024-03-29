#!/usr/bin/ruby

# Copyright 2013 Daniel Erat <dan@erat.org>
# All rights reserved.

# Search for modules in the lib/ subdirectory.
$:.unshift(File.dirname(__FILE__) + '/lib')

require 'logger'
require 'musicbrainz'
require 'optparse'
require 'rss'
require 'rss_cdata'
require 'sqlite3'
require 'time'
require 'uri'

# Maximum number of items to include in the feed.
FEED_SIZE = 20

# Skip release groups released more than this many days in the past.
MAX_AGE_DAYS = 5 * 365

# Maximum number of retries per artist.
NUM_RETRIES = 3

# Time to sleep between requests.
# See https://musicbrainz.org/doc/MusicBrainz_API/Rate_Limiting.
REQUEST_DELAY_SEC = 1

$logger = Logger.new($stderr)
$logger.datetime_format = '%Y-%m-%d %H:%M:%S'

def date_is_unset?(date)
  date.year == 2030 && date.month == 12 && date.day == 31
end

def time_to_rfc3339(time)
  time.utc.strftime('%FT%TZ')
end

def get_year(date)
  date_is_unset?(date) ? 'present' : date.year.to_s
end

def get_artist_id_from_database(db, artist_name_or_id)
  db.execute('SELECT ArtistId FROM Artists WHERE Name = ? OR ArtistId = ?',
             artist_name_or_id, artist_name_or_id).each {|row| return row[0] }
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
  db.execute <<-EOF
    CREATE TABLE Config (
      FeedFile VARCHAR(256) NOT NULL,
      FeedUrl VARCHAR(2048) NOT NULL)
    EOF
  db.execute <<-EOF
    INSERT INTO Config VALUES('', '')
    EOF
end

def read_config(db)
  db.get_first_row('SELECT FeedFile, FeedUrl FROM Config')
end

def write_config(db, feed_file, feed_url)
  db.execute('UPDATE Config SET FeedFile = ?', feed_file) if !feed_file.empty?
  db.execute('UPDATE Config SET FeedUrl = ?', feed_url) if !feed_url.empty?
end

def add_artist(db, artist_name)
  artist_id = get_artist_id_from_database(db, artist_name)
  if artist_id
    db.execute('UPDATE Artists SET Active = 1 WHERE ArtistId = ?', artist_id)
    $logger.info("Set artist \"#{artist_name}\" to active")
    return true
  end

  artist = MusicBrainz::Artist.find_by_name(artist_name)
  sleep(REQUEST_DELAY_SEC)

  # Fall back to searching by ID.
  if !artist
    artist = MusicBrainz::Artist.find(artist_name)
    sleep(REQUEST_DELAY_SEC)
  end

  if !artist
    $logger.warn("Unable to find artist \"#{artist_name}\"")
    return false
  end

  db.execute('INSERT INTO Artists(ArtistId, Name, Active) VALUES(?, ?, 1)', artist.id, artist.name)
  $logger.info("Inserted artist \"#{artist.name}\" (#{artist.type} from #{artist.country} " +
               "#{get_year(artist.date_begin)}-#{get_year(artist.date_end)})")

  # Insert the artist's existing releases with a 0 timestamp so they won't drown out any new releases from other artists.
  get_new_releases_for_artist(db, artist.id, artist.name, true)
  true
end

def remove_artist(db, artist_name)
  artist_id = get_artist_id_from_database(db, artist_name)
  if !artist_id
    $logger.warn("Artist \"#{artist_name}\" not present in database")
  else
    db.execute('UPDATE Artists SET Active = 0 WHERE ArtistId = ?', artist_id)
    $logger.info("Set artist \"#{artist_name}\" to inactive")
  end
end

def list_active_artists(db)
  db.execute('SELECT Name FROM Artists WHERE Active = 1 ORDER BY Name ASC') {|r| puts r[0] }
end

def get_new_releases_for_artist(db, artist_id, artist_name, new_artist)
  artist = nil
  NUM_RETRIES.times do
    begin
      artist = MusicBrainz::Artist.find(artist_id)
      sleep(REQUEST_DELAY_SEC)
    rescue Exception
    end
    break if artist && artist.release_groups
  end
  if !artist || !artist.release_groups
    $logger.warn("Failed to fetch artist #{artist_name} (#{artist_id}) from MusicBrainz")
    return
  end

  known_release_group_ids = db.execute('SELECT ReleaseGroupId FROM ReleaseGroups').map {|r| r[0] }
  artist.release_groups.each do |release_group|
    next if !known_release_group_ids.grep(release_group.id).empty?
    title = release_group.title
    title += " (#{release_group.desc})" if !release_group.desc.empty?
    rel_date = release_group.first_release_date.strftime('%Y-%m-%d')
    add_time = new_artist ? 0 : Time.now.to_i
    db.execute('INSERT INTO ReleaseGroups ' +
               '(ReleaseGroupId, ArtistId, Title, Type, ReleaseDate, AddTime) ' +
               'VALUES(?, ?, ?, ?, ?, ?)',
               release_group.id, artist_id, title, release_group.type, rel_date, add_time)
    $logger.info("Added \"#{title}\" for #{artist_name} (#{release_group.type} on #{rel_date})")
    known_release_group_ids << release_group.id
  end
end

def get_all_new_releases(db)
  # Collect the artists first to try to avoid
  # "database is locked (SQLite3::BusyException)" when inserting later.
  rows = db.execute('SELECT ArtistId, Name FROM Artists WHERE Active = 1').map {|r| [r[0], r[1]] }
  rows.each {|row| get_new_releases_for_artist(db, row[0], row[1], false) }
end

def write_feed(db, feed_file, feed_url)
  # Using RSS 1.0 instead of Atom because Ruby's rss module has close to
  # zero documentation and is unreadable/uncommented, and the only example
  # I can find on the Web of attaching content to an item involves patching
  # the module and writing an RSS 1.0 feed.
  rss = RSS::Maker.make('1.0') do |maker|
    maker.channel.updated = time_to_rfc3339(Time.now)
    maker.channel.title = 'New Music Releases'
    maker.channel.link = feed_url
    maker.channel.description = 'Release groups recently added to MusicBrainz'
    maker.channel.id = feed_url
    maker.channel.about = 'Seriously, "about" is a required field in RSS 1.0?'

    db.execute('SELECT a.ArtistId, a.Name, r.ReleaseGroupId, r.Title, r.Type, r.ReleaseDate, r.AddTime ' +
               'FROM Artists a INNER JOIN ReleaseGroups r ON(a.ArtistId = r.ArtistId) ' +
               'WHERE a.Active = 1 ' +
               'AND r.ReleaseDate >= ? ' +
               'ORDER BY r.AddTime DESC ' +
               'LIMIT ?', (Date.today() - MAX_AGE_DAYS).to_s, FEED_SIZE
              ).each do |artist_id, name, release_group_id, title, type, release_date, add_time|
      release_date = Date.parse(release_date)
      release_date_str = date_is_unset?(release_date) ? 'Unknown' : release_date.strftime('%Y-%m-%d')
      release_date_str_no_dash = date_is_unset?(release_date) ? 'Unknown' : release_date.strftime('%Y%m%d')
      release_date_end_str_no_dash = date_is_unset?(release_date) ? 'Unknown' : (release_date + 1).strftime('%Y%m%d')
      artist_url = "https://musicbrainz.org/artist/#{artist_id}"
      release_group_url = "https://musicbrainz.org/release-group/#{release_group_id}"

      calendar_link = date_is_unset?(release_date) || release_date < Date.today ? '' :
        "<p><a href=\"http://www.google.com/calendar/event?action=TEMPLATE" +
        "&text=" + URI.encode_www_form_component("#{name} - #{title}") +
        "&dates=#{release_date_str_no_dash}/#{release_date_end_str_no_dash}" +
        "&details=" + URI.encode_www_form_component("#{release_group_url}") +
        "&location=&trp=false&sprop=&sprop=name:\" target=\"_blank\">" +
        "Add to Google Calendar</a></p>"

      maker.items.new_item do |item|
        item.id = release_group_id
        item.title = "#{release_date_str}: #{name} - #{title}"
        item.link = release_group_url
        item.updated = time_to_rfc3339(Time.at(add_time))
        item.content_encoded = <<-EOF
          <b>Artist:</b> <a href="#{artist_url}">#{name}</a><br>
          <b>Title:</b> <a href="#{release_group_url}">#{title}</a><br>
          <b>Type:</b> #{type}<br>
          <b>Release date:</b> #{release_date_str}<br>
          <b>Added:</b> #{Time.at(add_time).ctime}<br>
          #{calendar_link}
          EOF
      end
    end

    if maker.items.empty?
      maker.items.new_item do |item|
        item.id = feed_url
        item.title = "No releases yet"
        item.link = feed_url
        item.updated = time_to_rfc3339(Time.now)
      end
    end
  end
  File.open(feed_file, 'w') {|f| f.write(rss) }
end

def read_artists(arg)
  arg ? [arg] : STDIN.read.split("\n").map {|a| a.strip }
end

def main
  db_filename = File.join(__dir__, 'watchbrainz.db')
  feed_file = ''
  feed_url = ''
  artists_to_add = []
  artists_to_remove = []
  should_init = false
  should_list = false

  opts = OptionParser.new
  opts.banner = "Usage: #$0 [options]"
  opts.on('--add [ARTIST]', 'Artist to add (reads one-per-line from stdin without argument)') {|v| artists_to_add = read_artists(v) }
  opts.on('--db FILE', 'SQLite3 database file') {|v| db_filename = v }
  opts.on('--init', 'Initialize database and exit') { should_init = true }
  opts.on('--list', 'List active artists and exit') { should_list = true }
  opts.on('--quiet', 'Suppress informational logging') { $logger.level = Logger::WARN }
  opts.on('--remove [ARTIST]', 'Artist to remove (reads one-per-line from stdin without argument)') {|v| artists_to_remove = read_artists(v) }
  opts.on('--set-file FILE', 'Sets file to which RSS data will be written') {|v| feed_file = v }
  opts.on('--set-url URL', 'Sets URL at which the feed will be served') {|v| feed_url = v }
  opts.parse!

  # Make path absolute in case CWD is different when executed by cron.
  feed_file = File.expand_path(feed_file) if !feed_file.empty?

  if !should_init && !File.exist?(db_filename)
    $stderr.puts("#{db_filename} does not exist; re-run with --init to create")
    exit(1)
  end

  db = SQLite3::Database.new(db_filename)
  if should_init || !feed_file.empty? || !feed_url.empty?
    init_db(db) if should_init
    write_config(db, feed_file, feed_url)
    exit(0)
  end

  if should_list
    list_active_artists(db)
    exit(0)
  end

  feed_file, feed_url = read_config(db)
  if feed_file.empty?
    $stderr.puts('Feed file must be set using --set-file')
    exit(2)
  end
  if feed_url.empty?
    $stderr.puts('Feed URL must be set using --set-url')
    exit(2)
  end

  MusicBrainz.configure do |c|
    c.app_name = 'watchbrainz'
    c.app_version = '0.1'
    c.contact = 'https://github.com/derat/watchbrainz'
  end

  artists_to_add.each {|a| add_artist(db, a) }
  artists_to_remove.each {|a| remove_artist(db, a) }
  get_all_new_releases(db) if artists_to_add.empty? && artists_to_remove.empty?
  write_feed(db, feed_file, feed_url)
  db.close
end

main
