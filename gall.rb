#!/usr/bin/env ruby

require 'uri'
require 'pathname'
require 'getoptlong'

# make sure the current directory is in our search path.
here = File.dirname(__FILE__)
really_here = File.expand_path(here)
$:.unshift(really_here) unless
  $:.include?(here) || $:.include?(really_here)

require 'gallrb/application'

def cleanpath(path)
  parts = path.sub('\\','/').split('/')
  cleaned = []
  parts.each do |part|
    case part
    when '.'  # nop
    when '..' 
      cleaned.pop
    else
      cleaned.push part
    end
  end
  File.join(*cleaned)
end

def usage()
end

def do_yield()
  yield
end

def do_profile()
  require 'profiler'
  Profiler__::start_profile
  yield
  Profiler__::stop_profile
  Profiler__::print_profile(STDERR)
end

def do_rubyprof()
  require 'rubygems'
  require 'ruby-prof'
  RubyProf.start

  yield
  
  result = RubyProf.stop

  # Print a flat profile to text
  printer = RubyProf::GraphHtmlPrinter.new(result)
  #printer = RubyProf::GraphPrinter.new(result)
  printer.print(STDERR, 0)
end

opts = GetoptLong.new(
  [ '--help', '-h', GetoptLong::NO_ARGUMENT ],
  [ '--debug', '-d', GetoptLong::NO_ARGUMENT ],
  [ '--profile', '-p', GetoptLong::NO_ARGUMENT ],
  [ '--rubyprof', '-r', GetoptLong::NO_ARGUMENT ],
  [ '--url', '-u', GetoptLong::REQUIRED_ARGUMENT ]
  )

# The web-equivalent of the CURRENT directory.
# This is a fully-qualified URL or path.
base_url = "/photos"
# How do we kickoff album generation?
wrapper  = :do_yield

opts.each do |opt, arg|
  case opt
  when '--help'
    usage
  when '--debug'
    Log.level = Log::DEBUG
  when '--profile'
    Log.info("Using the Ruby profiler.")
    wrapper = :do_profile
  when '--rubyprof'
    Log.info("Using ruby-prof.")
    wrapper = :do_rubyprof
  when '--url'
    base_url = arg
  end
end

dirs = ARGV.empty? ? ['.'] : ARGV
dirs.each do |scan_dir|
  # url  = URI.join(root_url,URI.escape(scan_dir)).to_s
  url = cleanpath(File.join(base_url,scan_dir))

  Log.info "Base URL: #{url.to_s}"
  send(wrapper) { Application.new(scan_dir,url).build }
  Log.info("Done")
end

# todo:
# * purge dead med/tn files
# * install style.css if one isn't present.
# * fix ERB namespaces
# * move all view helpers into ERB namespace.
# - Only compile each ERB template once.
#   * Only build each ERB wrapper method once; dynamically build object.
# * re-generate images if source is newer.
# * choose between scale/resize
#   * benchmark
# * Try and reduce memory usage. A nop run uses about 19MB
#   ** Latest is down to about 11M, 42s
# Write my own pathname?
# Tried using yaml for config file; required >5M!
