# watchbrainz

`watchbrainz.rb` is a Ruby script that can be run periodically from a cron job
to check the [MusicBrainz] database for music releases from a configurable list
of artists. Known releases are tracked using a [SQLite] database. The script
writes new releases to an RSS feed, although it's perhaps simpler to just
configure cron to email the script's output to you.

[MusicBrainz]: https://musicbrainz.org/
[SQLite]: https://www.sqlite.org/index.html

## Usage

The script was originally written in 2013 and probably hasn't aged well, but it
appears to still work with Ruby 2.5.5p157. It bundles (ancient) versions of some
of its dependencies, but you'll probably need to install at least the following
packages:

```sh
sudo apt-get install ruby ruby-nokogiri ruby-sqlite3
```

You will initially need to create the database file (`watchbrainz.db` in the
script's directory is used by default) and set the RSS file that should be
written and the name of the URL at which it will be served:

```sh
./watchbrainz.rb --init \
  --set-file=/var/www/music.xml \
  --set-url=https://example.org/music.xml
```

After initializing the database, run `crontab -e` and add a line to run the
script at the desired frequency, e.g.:

```
10 4 * * * ~/watchbrainz/watchbrainz.rb
```

You can add, remove, and list the artists that will be monitored:

```sh
% ./watchbrainz.rb --add 'Weird Al'                                                                                        [~/code/watchbrainz]
I, [2020-04-25 11:42:04#3477]  INFO -- : Inserted artist "Weird Al" (Person from US 1959-present)
I, [2020-04-25 11:42:07#3477]  INFO -- : Added "“Weird Al” Yankovic" for Weird Al (Album on 1983-04-26)
I, [2020-04-25 11:42:07#3477]  INFO -- : Added "“Weird Al” Yankovic in 3‐D" for Weird Al (Album on 1984-02-28)
...
I, [2020-04-25 11:42:07#3477]  INFO -- : Added "Medium Rarities" for Weird Al (Compilation on 2015-11-24)
```

```sh
% ./watchbrainz.rb --list
Weird Al
```

```sh
% ./watchbrainz.rb --remove 'Weird Al'
I, [2020-04-25 11:43:08#3485]  INFO -- : Set artist "Weird Al" to inactive
```

If an argument is not supplied to the `--add` or `--remove` flags, they will
read a list of artists from stdin, one per line.
