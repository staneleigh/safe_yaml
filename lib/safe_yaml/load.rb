require "set"
require "yaml"

# This needs to be defined up front in case any internal classes need to base
# their behavior off of this.
module SafeYAML
  YAML_ENGINE = defined?(YAML::ENGINE) ? YAML::ENGINE.yamler : "syck"
  LIBYAML_VERSION = YAML_ENGINE == "psych" && Psych.const_defined?("LIBYAML_VERSION", false) ? Psych::LIBYAML_VERSION : nil

  # Do proper version comparison (e.g. so 0.1.10 is >= 0.1.6)
  SAFE_LIBYAML_VERSION = Gem::Version.new("0.1.6")

  def self.check_libyaml_version
    old_libyaml_version = YAML_ENGINE == "psych" && Gem::Version.new(LIBYAML_VERSION || "0") < SAFE_LIBYAML_VERSION

    if old_libyaml_version && !defined?(JRUBY_VERSION) && !libyaml_patched?
      Kernel.warn <<-EOWARNING.gsub(/^ +/, '  ')

        \e[33mSafeYAML Warning\e[39m
        \e[33m----------------\e[39m

        \e[31mYou may have an outdated version of libyaml (#{LIBYAML_VERSION}) installed on your system.\e[39m

        Prior to 0.1.6, libyaml is vulnerable to a heap overflow exploit from malicious YAML payloads.

        For more info, see:
        https://www.ruby-lang.org/en/news/2014/03/29/heap-overflow-in-yaml-uri-escape-parsing-cve-2014-2525/

        The easiest thing to do right now is probably to update Psych to the latest version and enable
        the 'bundled-libyaml' option, which will install a vendored libyaml with the vulnerability patched:

        \e[32mgem install psych -- --enable-bundled-libyaml\e[39m

      EOWARNING
    end
  end

  KNOWN_PATCHED_LIBYAML_VERSIONS = Set.new([
    # http://people.canonical.com/~ubuntu-security/cve/2014/CVE-2014-2525.html
    "0.1.4-2ubuntu0.12.04.3",
    "0.1.4-2ubuntu0.12.10.3",
    "0.1.4-2ubuntu0.13.10.3",
    "0.1.4-3ubuntu3",

    # https://security-tracker.debian.org/tracker/CVE-2014-2525
    "0.1.3-1+deb6u4",
    "0.1.4-2+deb7u4",
    "0.1.4-3.2"
  ]).freeze

  def self.libyaml_patched?
    return false if (`which dpkg` rescue '').empty?
    libyaml_version = `dpkg -s libyaml-0-2`.match(/^Version: (.*)$/)
    return false if libyaml_version.nil?
    KNOWN_PATCHED_LIBYAML_VERSIONS.include?(libyaml_version[1])
  end
end

SafeYAML.check_libyaml_version

require "safe_yaml/deep"
require "safe_yaml/parse/hexadecimal"
require "safe_yaml/parse/sexagesimal"
require "safe_yaml/parse/date"
require "safe_yaml/transform/transformation_map"
require "safe_yaml/transform/to_boolean"
require "safe_yaml/transform/to_date"
require "safe_yaml/transform/to_float"
require "safe_yaml/transform/to_integer"
require "safe_yaml/transform/to_nil"
require "safe_yaml/transform/to_symbol"
require "safe_yaml/transform"
require "safe_yaml/resolver"
require "safe_yaml/syck_hack" if SafeYAML::YAML_ENGINE == "syck" && defined?(JRUBY_VERSION)

module SafeYAML
  MULTI_ARGUMENT_YAML_LOAD = YAML.method(:load).arity != 1

  DEFAULT_OPTIONS = Deep.freeze({
    :default_mode         => nil,
    :suppress_warnings    => false,
    :deserialize_symbols  => false,
    :whitelisted_tags     => [],
    :custom_initializers  => {},
    :raise_on_unknown_tag => false
  })

  OPTIONS = Deep.copy(DEFAULT_OPTIONS)

  PREDEFINED_TAGS = {}

  if YAML_ENGINE == "syck"
    YAML.tagged_classes.each do |tag, klass|
      PREDEFINED_TAGS[klass] = tag
    end

  else
    # Special tags appear to be hard-coded in Psych:
    # https://github.com/tenderlove/psych/blob/v1.3.4/lib/psych/visitors/to_ruby.rb
    # Fortunately, there aren't many that SafeYAML doesn't already support.
    PREDEFINED_TAGS.merge!({
      Exception => "!ruby/exception",
      Range     => "!ruby/range",
      Regexp    => "!ruby/regexp",
    })
  end

  Deep.freeze(PREDEFINED_TAGS)

  module_function

  def restore_defaults!
    OPTIONS.clear.merge!(Deep.copy(DEFAULT_OPTIONS))
  end

  def tag_safety_check!(tag, options)
    return if tag.nil? || tag == "!"
    if options[:raise_on_unknown_tag] && !options[:whitelisted_tags].include?(tag) && !tag_is_explicitly_trusted?(tag)
      raise "Unknown YAML tag '#{tag}'"
    end
  end

  def whitelist!(*classes)
    classes.each do |klass|
      whitelist_class!(klass)
    end
  end

  def whitelist_class!(klass)
    raise "#{klass} not a Class" unless klass.is_a?(::Class)

    klass_name = klass.name
    raise "#{klass} cannot be anonymous" if klass_name.nil? || klass_name.empty?

    # Whitelist any built-in YAML tags supplied by Syck or Psych.
    predefined_tag = PREDEFINED_TAGS[klass]
    if predefined_tag
      OPTIONS[:whitelisted_tags] << predefined_tag
      return
    end

    # Exception is exceptional (har har).
    tag_class  = klass < Exception ? "exception" : "object"

    tag_prefix = case YAML_ENGINE
                 when "psych" then "!ruby/#{tag_class}"
                 when "syck"  then "tag:ruby.yaml.org,2002:#{tag_class}"
                 else raise "unknown YAML_ENGINE #{YAML_ENGINE}"
                 end
    OPTIONS[:whitelisted_tags] << "#{tag_prefix}:#{klass_name}"
  end

  if YAML_ENGINE == "psych"
    def tag_is_explicitly_trusted?(tag)
      false
    end

  else
    TRUSTED_TAGS = Set.new([
      "tag:yaml.org,2002:binary",
      "tag:yaml.org,2002:bool#no",
      "tag:yaml.org,2002:bool#yes",
      "tag:yaml.org,2002:float",
      "tag:yaml.org,2002:float#fix",
      "tag:yaml.org,2002:int",
      "tag:yaml.org,2002:map",
      "tag:yaml.org,2002:null",
      "tag:yaml.org,2002:seq",
      "tag:yaml.org,2002:str",
      "tag:yaml.org,2002:timestamp",
      "tag:yaml.org,2002:timestamp#ymd"
    ]).freeze

    def tag_is_explicitly_trusted?(tag)
      TRUSTED_TAGS.include?(tag)
    end
  end

  if SafeYAML::YAML_ENGINE == "psych"
    require "safe_yaml/psych_handler"
    require "safe_yaml/psych_resolver"
    require "safe_yaml/safe_to_ruby_visitor"

    def self.load(yaml, filename=nil, options={})
      # If the user hasn't whitelisted any tags, we can go with this implementation which is
      # significantly faster.
      if (options && options[:whitelisted_tags] || SafeYAML::OPTIONS[:whitelisted_tags]).empty?
        safe_handler = SafeYAML::PsychHandler.new(options) do |result|
          return result
        end
        arguments_for_parse = [yaml]
        arguments_for_parse << filename if SafeYAML::MULTI_ARGUMENT_YAML_LOAD
        Psych::Parser.new(safe_handler).parse(*arguments_for_parse)
        return safe_handler.result

      else
        safe_resolver = SafeYAML::PsychResolver.new(options)
        tree = SafeYAML::MULTI_ARGUMENT_YAML_LOAD ?
          Psych.parse(yaml, filename) :
          Psych.parse(yaml)
        return safe_resolver.resolve_node(tree)
      end
    end

    def self.load_file(filename, options={})
      if SafeYAML::MULTI_ARGUMENT_YAML_LOAD
        File.open(filename, 'r:bom|utf-8') { |f| self.load(f, filename, options) }

      else
        # Ruby pukes on 1.9.2 if we try to open an empty file w/ 'r:bom|utf-8';
        # so we'll not specify those flags here. This mirrors the behavior for
        # unsafe_load_file so it's probably preferable anyway.
        self.load File.open(filename), nil, options
      end
    end

  else
    require "safe_yaml/syck_resolver"
    require "safe_yaml/syck_node_monkeypatch"

    def self.load(yaml, options={})
      resolver = SafeYAML::SyckResolver.new(SafeYAML::OPTIONS.merge(options || {}))
      tree = YAML.parse(yaml)
      return resolver.resolve_node(tree)
    end

    def self.load_file(filename, options={})
      File.open(filename) { |f| self.load(f, options) }
    end
  end
end
