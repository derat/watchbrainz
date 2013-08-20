#!/usr/bin/ruby

# Copyright 2013 Daniel Erat <dan@erat.org>
# All rights reserved.

# Search for modules in the lib/ subdirectory.
$:.unshift(File.dirname(__FILE__) + '/lib')

require 'musicbrainz'
