module MusicBrainz
  class Artist < BaseModel
    field :id, String
    field :type, String
    field :name, String
    field :country, String
    field :date_begin, Date
    field :date_end, Date
    field :urls, Hash

    def release_groups
      return nil if @id.nil?

      if not @release_groups
        @release_groups = []
        offset = 0
        loop do
          groups = client.load(:release_group, { artist: id, limit: 100, offset: offset }, {
            binding: :artist_release_groups,
            create_models: :release_group,
            sort: :first_release_date,
          })
          break if groups.empty?
          @release_groups += groups
          offset += groups.size
          sleep(1) # https://musicbrainz.org/doc/MusicBrainz_API/Rate_Limiting
        end
      end

      @release_groups
    end

    class << self
      def find(id)
        client.load(:artist, { id: id }, {
          binding: :artist,
          create_model: :artist
        })
      end

      def search(name)
				super({artist: name})
      end

      def discography(mbid)
        artist = find(mbid)
        artist.release_groups.each { |rg| rg.releases.each { |r| r.tracks } }
        artist
      end

      def find_by_name(name)
        matches = search(name)
        matches.empty? ? nil : find(matches.first[:id])
      end
    end
  end
end
