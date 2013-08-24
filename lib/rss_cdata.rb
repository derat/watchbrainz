# http://motivation.drivendevelopment.jp/2009-12-02-1.html

require 'rss'

module RSS
  module BaseModel
    def install_cdata_element(tag_name, uri, occurs, name=nil, type=nil, disp_name=nil)
      name ||= tag_name
      disp_name ||= name
      self::ELEMENTS << name
      add_need_initialize_variable(name)
      install_model(tag_name, uri, occurs, name)

      def_corresponded_attr_writer name, type, disp_name
      convert_attr_reader name
      install_element(name) do |n, elem_name|
        <<-EOC
        if @#{n}
          rv = "\#{indent}<#{elem_name}>"
          value = "<![CDATA[" + eval("@#{n}") + "]]>"
          if need_convert
            rv << convert(value)
          else
            rv << value
          end
          rv << "</#{elem_name}>"
          rv
        else
          ''
        end
EOC
      end
    end
  end

  module ContentModel
    def self.append_features(klass)
      super

      klass.install_must_call_validator(CONTENT_PREFIX, CONTENT_URI)
      %w(encoded).each do |name|
        klass.install_cdata_element(name, CONTENT_URI, "?", "#{CONTENT_PREFIX}_#{name}")
      end
    end
  end

  class RDF
    class Item; include ContentModel; end
  end
end
