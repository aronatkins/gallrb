#!/usr/bin/env ruby

require 'erb'
require 'uri'
require 'fileutils'
require 'pathname'
require 'getoptlong'

# Silly little logging class. Just print to console if enabled.
class Log
  
  # Define logging levels as a hash and as constants.
  LEVELS = { 
    :FATAL => 1,
    :ERROR => 2,
    :WARN  => 3,
    :INFO  => 4,
    :DEBUG => 5
  }
  LEVELS.each { |lvl,val| const_set(lvl,val) }

  # future: allow log instantiation.
  # future: allow different log targets.
  @fh = STDOUT

  # Default logging level
  @level = INFO
  def self.level=(lvl)
    @level = lvl
  end
  def self.level()
    @level
  end
  
  # Return true if we are logging the given level.
  def self.logging(lvl)
    (level >= lvl)
  end

  def self.method_missing(sym,*args)
    lvl = sym.to_s.upcase.to_sym
    if LEVELS.has_key? lvl
      log(lvl,*args) if logging(self.const_get(lvl))
    else
      super(sym,*args)
    end
  end
  
  private 
  def self.log(lvl,str)
    @fh.write "[#{Time.new}] #{lvl} #{str}\n"
  end
end

# Class encapsulating image resizing methods.
class ImageProcessor
  class ImageProcessorError < Exception; end

  # Resize using ImageMagick -scale option.
  def self.scale_sh(in_path, out_path, width, height=nil)
    if height.nil?
      width,height = width.split('x')
      width = width.to_i
      height = height.to_i
    end
    run_command("convert", in_path,
                "-scale", "#{width}x#{height}>",
                out_path)
  end

  # Resize using ImageMagick -resize option.
  def self.resize_sh(in_path, out_path, width, height=nil)
    if height.nil?
      width,height = width.split('x')
      width = width.to_i
      height = height.to_i
    end
    run_command("convert", in_path,
                "-resize", "#{width}x#{height}>",
                out_path)
  end

  # Crop/Resize using ImageMagick. Useful for odd image sizes.
  def self.crop_resize_sh(in_path, out_path, width, height=nil)
    if height.nil?
      width,height = width.split('x')
      width = width.to_i
      height = height.to_i
    end
    run_command("convert", in_path, 
                "-resize",  "x#{height*2}", 
                "-resize",  "#{width*2}x<",
                "-resize",  "50%",
                "-gravity", "center",
                "-crop",    "#{width}x#{height}+0+0",
                "+repage",
                out_path)
  end

  # Run a command. Raise an exception for any non-zero exit.
  def self.run_command(command, *args)
    args = args.collect do |arg|
      arg = arg.to_s
      # Quote everything except switches.
      arg = "\"#{arg}\"" unless arg[0,1]=='-'
      arg
    end
    full_command = "#{command} #{args.join(' ')}"
    Log.debug "*** #{full_command}"
    result = system(full_command)
    if $? != 0
      raise ImageProcessorError, "ImageMagick command (#{command} #{args.join(' ')}) failed: Error Given #{$?}"
    else
      return result
    end  
  end
end

# Class encapsulating how to create an image/movie derivation.
# Typically used to create thumbnails and web-friendly sizes.
class Derivation
  attr_accessor :base_path
  attr_accessor :name
  attr_accessor :geometry
  attr_accessor :resizer

  # _name: A unique token for this resizer.
  # _geometry: Target size.
  def initialize(_base_path,
                 _name,
                 _geometry,
                 _resizer,
                 _has_image,
                 _has_html)
    @base_path = _base_path
    @name      = _name
    @geometry  = _geometry
    @resizer   = _resizer
    @has_image = _has_image
    @has_html  = _has_html
  end

  def resize()
    Log.info "Resizing: #{base_path} -> #{path}"
    ImageProcessor.send(@resizer, base_path, path, geometry)
  end

  def make_derived(_path,replacement_ext=nil)
    # Use the File.* methods to avoid creating lots of Pathname objects.
    _path_s = _path.to_s
    (d,b) = File.split(_path_s)
    e = File.extname(_path_s)
    replacement_ext ||= e
    Pathname.new [d,name,b.to_s.sub(/#{e}$/,"_"+name+replacement_ext)].join('/')
  end

  def to_s
    path.to_s
  end

  def path()
    @path ||= make_derived(base_path)
  end

  def image?()
    @has_image
  end

  def html()
    @html ||= make_derived(base_path,".html")
  end

  def html?()
    @has_html
  end

end

# Any path within a gallery. Images, movies, and directories.
class GalleryPath
  attr_accessor :parent
  attr_accessor :path
  attr_accessor :title

  def initialize(_parent,_path)
    @parent = _parent
    @path  = Pathname.new _path
    # Special-case. If we're '.', find the real path. 
    # Otherwise, a straight basename is sufficient.
    # Don't use the Pathname unless necessary.
    @title = File.basename(_path.to_s=='.' ? path.realpath.to_s : _path)
  end
end

# A gallery contains:
# * other galleries
# * files: images, movies, etc.
class Gallery < GalleryPath
  attr_accessor :galleries
  attr_accessor :images
  attr_accessor :movies

  def initialize(_parent,_path)
    super(_parent,_path)

    # Precompute to avoid excessive Pathname object constructions.
    directories, files = @path.children.partition { |child| child.directory? }
    
    @galleries = directories.find_all do |child|
      not ["med","tn"].include?(child.basename.to_s)
    end.map do |child|
      Log.debug "Directory! #{child}"
      Gallery.new(self,child)
    end

    @images = files.find_all do |child|
      Image.known_type?(child)
    end.map do |child,i|
      Log.debug "Image! #{child}"
      Image.new(self,child)
    end

    @images.each_with_index do |image,i|
      # Gah. arr[-1] gives the last, not nil. arr[BIG] gives nil.
      image.previous = @images[i-1] unless i==0
      image.next     = @images[i+1]
    end

    @movies = files.find_all do |child|
      Movie.known_type?(child)
    end.map do |child|
      Log.debug "Movie! #{child}"
      Movie.new(self,child)
    end

    @movies.each_with_index do |movie,i|
      # Gah. arr[-1] gives the last, not nil. arr[BIG] gives nil.
      movie.previous = @movies[i-1] unless i==0
      movie.next     = @movies[i+1]
    end

    if Log.logging(Log::DEBUG)
      files.each do |child|
        if not child.directory? and not Movie.known_type?(child) and not Image.known_type?(child)
          Log.debug "Don't know how to handle #{child}"
        end
      end
    end

    @galleries = @galleries.sort_by { |g| g.path.to_s.downcase }
    @images    = @images.sort_by { |i| i.path.to_s.downcase }
    @movies    = @movies.sort_by { |m| m.path.to_s.downcase }
  end

  def children?()
    not (galleries.empty? and images.empty? and movies.empty?)
  end

  # define all_galleries, all_images, all_movies
  # sub_galleries_count, all_images_count, all_movies_count
  [:galleries, :images, :movies].each do |subtype|

    # Initialize a bunch of constants outside of our method definitions.
    all_name = "all_#{subtype}"
    all_var = "@" + all_name
    all_count_name = "sub_#{subtype}_count"
    all_count_var = "@" + all_name

    # Recursively discover a flattened list of objects.
    define_method(all_name) do
      instance_variable_get(all_var) ||
        instance_variable_set(all_var,
                              send(subtype) + galleries.map { |o| o.send(all_name) }.flatten)
    end

    # Recursively count all objects of a given type.
    define_method(all_count_name) do
      instance_variable_get(all_count_var) ||
        instance_variable_set(all_count_var,
                              send(subtype).size + galleries.map { |g| g.send(all_count_name) }.inject(0) { |a,b| a+b })
    end
  end

  # Galleries use the first available image as thumbnail. That image
  # may be in a sub-gallery.
  def thumbnail()
    @thumbnail ||= ( (images.first and images.first.thumbnail) or
                     (galleries.map { |g| g.thumbnail }.detect { |t| t } ) )
  end

  def walk(&blk)
    blk.call self if ! blk.nil?
    galleries.each { |c| c.walk &blk }
    images.each    { |c| c.walk &blk }
    movies.each    { |c| c.walk &blk }
  end

  def index()
    @index ||= File.join path, "index.html"
  end
end

# An actual file within a gallery.
class GalleryFile < GalleryPath
  attr :previous, true
  attr :next, true

  def initialize(_parent,_path)
    super(_parent,_path)
  end

  @known_types = []
  @derivations = {}

  # Create class-level instance methods
  class << self
    def known_types=(value)
      @known_types = value
    end

    def known_types()
      @known_types || []
    end

    def derivations=(value)
      @derivations = value
    end

    def derivations()
      @derivations ||= {}
    end
  end

  def self.known_type?(path)
    known_types.include?(path.extname.downcase)
  end

  # BUG: auto-generate derivations

  def make_derivation(name)
    settings = self.class.derivations[name]
    Derivation.new(path,
                   settings[:name],
                   settings[:geometry],
                   settings[:resizer],
                   settings[:has_image],
                   settings[:has_html])
  end

  def thumbnail()
    @thumbnail ||= make_derivation(:thumbnail)
  end

  def medium()
    @medium ||= make_derivation(:medium)
  end

  def children?()
    false
  end
  
  def walk(&blk)
    blk.call self if ! blk.nil?
  end
end

class Image < GalleryFile
  @known_types = [ ".jpg", ".gif" ]
  @derivations = { 
    :thumbnail => { 
      :name => "tn",
      # :geometry => "100x75",
      :geometry => "133x133",
      # :resizer => :resize_sh,
      :resizer => :scale_sh,
      :has_image => true,
      :has_html => false },
    :medium    => { 
      :name => "med",
      :geometry => "800x800",
      :resizer => :resize_sh,
      :has_image => true,
      :has_html => true }
   }
end

class Movie < GalleryFile
  @known_types = [ ".avi", ".mov" ]
  @derivations = { 
    :thumbnail => { 
      :name => "tn",
      # :geometry => "100x75",
      :geometry => "133x133",
      # :resizer => :resize_sh,
      :resizer => :scale_sh,
      :has_image => false,
      :has_html => false },
    :medium    => { 
      :name => "med",
      :geometry => "800x800",
      :resizer => :resize_sh,
      :has_image => false,
      :has_html => false }
  }
end

# Extensions to Pathname.
class Pathname
  # Our application doesn't need the string duplication that happens
  # in by default in Pathname. This is faster.
  def to_s
    @path
  end
  # We don't need 'basename' to return a Pathname. Just a string is fine.
  def basename(*args)
    @basename ||= File.basename(@path,*args)
  end
  # We don't need 'dirname' to return a Pathname. Just a string will do.
  def dirname()
    @dirname ||= File.dirname(@path)
  end
  # Cache our hash vlaue. We aren't changing the path.
  def hash()
    @hash ||= @path.hash
  end
end

class GalleryPath
  # Return ancestors and self.
  def generations()
    ancestors + [self]
  end

  # Return all pathnames which are ancestors of this one.
  # Don't do this in Pathname.. avoid object construction.
  def ancestors(root_ancestor=nil)
    if @ancestors
      @ancestors
    else
    if root_ancestor and path.to_s == root_ancestor
      @ancestors = [] # reached user-specified root.
    else
      if parent
        @ancestors = parent.ancestors(root_ancestor) + [parent]
      else
        @ancestors = [] # no ancestors
      end
    end
    end
  end
end

# View helpers.
module Helpers
  def start_of_row?(counter,rowsize)
    return (counter % rowsize==0)
  end
  def maybe_start_row(counter,rowsize)
    "<tr>" if start_of_row?(counter,rowsize)
  end

  def end_of_row?(counter,rowsize,listsize)
    return (counter==listsize-1) || (counter%rowsize==rowsize-1)
  end
  def maybe_end_row(counter,rowsize,listsize)
    "</tr>" if end_of_row?(counter,rowsize,listsize)
  end

  def start_of_table?(counter)
    return (counter==0)
  end
  def maybe_start_table(counter)
    "<table>" if start_of_table?(counter)
  end

  def end_of_table?(counter,listsize)
    return (counter==listsize-1)
  end
  def maybe_end_table(counter,listsize)
    "</table>" if end_of_table?(counter,listsize)
  end
end

class GallRB

  attr_accessor :base_path
  attr_accessor :base_url
  attr_accessor :rowsize

  attr_accessor :gallery

  def initialize(_base_path, _base_url)
    @base_path = _base_path
    @base_url  = _base_url
    @rowsize = 5

    @templates = {}
    @urls      = {}

    @gallery = Gallery.new(nil,Pathname.new(base_path))
  end

  def make_binding()
    binding
  end

  def clean_base_path()
    @clean_base_path ||= if base_path[-1] == '/'
                           base_path[0..-1]
                         else
                           base_path
                         end
  end
  def clean_base_url()
    @clean_base_url ||= if base_url[-1] == '/'
                          base_url[0..-1]
                        else
                          base_url
                        end
  end

  def url_for(path)
    # cache urls for 10% performance savings but gobs (+50%) of memory.
    # @urls[path] ||= 
    ## path.to_s.sub(clean_base_path,clean_base_url).sub('/index.html','/')
    
    # We're using a relative base_path, so we don't need to substitute.
    path_s = path.to_s

    url = 
      if path_s == "."
        # special case -- root.
        clean_base_url + "/" 
      else 
        url = File.join(clean_base_url,path_s)
        # Let httpd auto-fetch the index document.
        url.sub!('/index.html','/')
        # Ugh. I hate that String#sub! returns nil when no replacement is performed.
        url
    end

    URI.escape(url)
  end

  def link_to(name,path)
    "<a href=\"#{url_for(path)}\">#{name}</a>"
  end

  def image_tag(path)
    "<img src=\"#{url_for(path)}\"/>"
  end

  def image_link_to(img,target)
    "<a href=\"#{url_for(target)}\" class='image'><img src=\"#{url_for(img)}\" /></a>"
  end

  def build()
    indices
    index_thumbnails
    thumbnails
    mediums
  end
  
  def make_media_derivation(name,o)
    if o.is_a? Image or o.is_a? Movie
      # BUG: Re-generate only when necessary (if settings change?)
      derivation = o.send(name)
      if derivation.image?
        unless derivation.path.exist?
          FileUtils.mkdir_p(derivation.path.dirname)
          derivation.resize
        end
      end
    end
  end

  def make_html_derivation(name,o)
    if o.is_a? Image or o.is_a? Movie
      # BUG: Re-generate only when necessary
      derivation = o.send(name)
      if derivation.html?
        Log.debug "Making HTML(#{name}) for: #{o.class.to_s}: #{o.path.to_s}"
        FileUtils.mkdir_p(derivation.html.dirname)
        File.open(derivation.html,"w") do |fp|
          typename = o.class.to_s.downcase
          fp.write(render(typename, :locals => { typename.to_sym => o }))
        end
      else
        Log.debug "Skipping HTML(#{name}) for: #{o.class.to_s}: #{o.path.to_s}"
      end
    end
  end
  
  def make_media_derivations(name)
    Log.info("#{name}: resizing")
    gallery.walk { |o| make_media_derivation(name,o) }
  end

  def make_html_derivations(name)
    Log.info("#{name}: html")
    gallery.walk { |o| make_html_derivation(name,o) }
  end

  def make_derivations(name)
    make_html_derivations(name)
    make_media_derivations(name)
  end

  def thumbnails()
    make_derivations(:thumbnail)
  end

  def mediums()
    make_derivations(:medium)
  end

  # This method is to improve usability for an incomplete gallery.
  # Generate thumbnails first so the top-level pages don't have broken images.
  def index_thumbnails()
    Log.info("Index Thumbnails")
    gallery.walk do |o|
      if o.is_a? Gallery
        make_media_derivation(:thumbnail,o.thumbnail)
      end
    end
  end

  def indices()
    Log.info("Indices")
    gallery.walk do |o|
      if o.is_a? Gallery
        Log.debug "Gallery: #{o.path}"
        # BUG: Re-generate only when necessary
        File.open(o.index,"w") do |fp|
          fp.write(render('gallery', :locals => { :gallery => o }))
        end
      end
    end
  end

  def render(template,options={})
    if template.is_a? String
      render_file(template, options[:locals] || {})
    elsif template.instance_of? Hash
      options = template.clone
      options[:locals] ||= {}
      if options[:file]
        render_file(options[:file], options[:locals])
      elsif options[:partial] and options[:collection]
          render_partial_collection(options[:partial], options[:collection], options[:locals])
      elsif options[:partial]
        render_partial(options[:partial], options[:object], options[:locals])
      else
        "Don't know how to render this."
      end
    end
  end

  def render_partial(partial, element, local_assigns = nil)
    local_assigns = local_assigns ? local_assigns.clone : {}
    local_assigns[partial.intern] = element
    render "_#{partial}", :locals => local_assigns
  end

  def render_partial_collection(partial,collection,local_assigns = nil)
    counter_name = "#{partial.split('/').last}_counter".intern
    local_assigns = local_assigns ? local_assigns.clone : {}
    local_assigns[:listsize] = collection.size
    local_assigns[:rowsize]  = rowsize

    rendered_partials = []
    collection.each_with_index do |element,counter|
      local_assigns[counter_name] = counter
      rendered_partials.push(render_partial(partial, element, local_assigns))
    end
    rendered_partials.join ""
  end

  def view_directory
    @view_directory ||= File.join(Pathname.new(__FILE__).dirname.to_s, "view")
  end

  def render_filename(template)
    File.join(view_directory,template + ".rhtml")
  end

  # container for pre-compiled templates
  module CompiledTemplates
  end
  include CompiledTemplates

  # BUG: expose the helpers only within the ERB namespace.
  include Helpers

  def do_compile(template_filename)
    @templates[template_filename] ||= ERB.new(File.read(template_filename),nil,'-')
  end

  def compile_template(filename,local_assigns = {})
    message = do_compile(filename)
    
    body_parts = local_assigns.keys.map do |key|
      "#{key} = locals[:#{key}]"
    end

    # BUG: Build object which has the given method name.
    method_name = "compiled_template"

    body_parts.unshift "def #{method_name}(locals)"
    body_parts.push    message.src
    body_parts.push    "end"
    compiled_template = body_parts.join("\n")

    # BUG: This re-compiles each time.
    CompiledTemplates.module_eval(compiled_template, filename, -(local_assigns.size))
    method_name
  end

  def render_file(template,local_assigns = {})
    filename = render_filename(template)
    method_name = compile_template(filename,local_assigns)
    send method_name, local_assigns
  end

  def breadcrumb(g,include_self=true)
    parts = g.ancestors(base_path).map do |ancestor|
      link_to ancestor.title, ancestor.path
    end
    parts.push(g.title) if include_self
    parts.join(" : ")
  end

  def stylesheet(path)
    "<link rel='stylesheet' type='text/css' href=\"#{url_for(File.join(base_path,path))}\">"
  end

  def date_re
    @date_re ||= /^(\d{4}-\d{1,2}(-\d{1,2})?)[ -](.+)$/
  end

  def title(gallery)
    match = date_re.match(gallery.title)
    if match
      date_part     = match[1]
      non_date_part = match[3]
      "<div class='title date'>#{link_to(date_part,gallery.index)}</div><div class='title'>#{link_to(non_date_part,gallery.index)}</div>"
    else
      "<div class='title'>#{link_to(gallery.title,gallery.index)}</div>"
    end
  end

  def details(gallery)
    parts = []
    parts.push("#{gallery.sub_galleries_count} albums") unless gallery.sub_galleries_count==0
    parts.push("#{gallery.sub_images_count} images") unless gallery.sub_images_count==0
    parts.push("#{gallery.sub_movies_count} movies") unless gallery.sub_movies_count==0
    "<div class='details'>#{parts.join(', ')}</div>"
  end

  def link_to_previous(image)
    unless image.previous.nil?
      link_to("(prev) #{image.previous.title}",image.previous.medium.html) 
    end
  end
  def link_to_next(image)
    unless image.next.nil?
      link_to("#{image.next.title} (next)",image.next.medium.html) 
    end
  end
end

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
  send(wrapper) { GallRB.new(scan_dir,url).build }
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
