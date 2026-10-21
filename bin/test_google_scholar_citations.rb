#!/usr/bin/env ruby
# Run with: ruby bin/test_google_scholar_citations.rb
# Uses Liquid when installed; parser/persistence unit tests also run without it.
require 'minitest/autorun'
require 'tmpdir'

begin
  require 'liquid'
rescue LoadError
  module Liquid
    class Tag
      def initialize(*); end
    end

    class Template
      def self.register_tag(*); end
    end
  end
end

require_relative '../_plugins/google-scholar-citations'

class GoogleScholarCitationsTest < Minitest::Test
  Tag = Jekyll::GoogleScholarCitationsTag
  Site = Struct.new(:source, :data)

  class Context < Hash
    attr_reader :registers

    def initialize(site, profile = 'profile', article = 'article')
      @registers = { site: site }
      self['profile'] = profile
      self['article'] = article
    end

    def scopes
      [self]
    end
  end

  class StubTag < Tag
    public_class_method :new
    attr_accessor :response, :failure
    attr_reader :requests

    def initialize
      parse_context = defined?(Liquid::ParseContext) ? Liquid::ParseContext.new : nil
      super('google_scholar_citations', 'profile article', parse_context)
      @requests = []
    end

    private

    def fetch_article(url)
      @requests << url
      raise @failure if @failure

      @response.respond_to?(:call) ? @response.call(url) : @response
    end

    def log_warning(_message); end
  end

  def setup
    @directory = Dir.mktmpdir('scholar-test-')
    @site = Site.new(@directory, {})
    @tag = StubTag.new
    @context = Context.new(@site)
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def record(count, age = 60, profile = 'profile', article = 'article')
    { 'count' => count, 'fetched_at' => (Time.now.utc - age).iso8601, 'url' => Tag.article_url(profile, article) }
  end

  def cache_path
    File.join(@directory, '.jekyll-cache', 'google-scholar-citations', 'counts.json')
  end

  def write_cache(records)
    FileUtils.mkdir_p(File.dirname(cache_path))
    File.write(cache_path, JSON.generate(records))
  end

  def test_parses_actual_link_and_both_metadata_variants
    assert_equal 1234, Tag.parse_count('<meta name="description" content="Cited by 1,234">')
    assert_equal 393, Tag.parse_count('<meta name="description" content="Paper"><meta property="og:description" content="Cited by 393">')
    assert_equal 394, Tag.parse_count('<meta name="description" content="Cited by 393"><a href="/scholar?cites=123">Cited by 394</a>')
  end

  def test_unrecognized_response_is_unknown_but_explicit_zero_is_valid
    assert_nil Tag.parse_count('<html>Please verify you are human</html>')
    assert_nil Tag.parse_count('<meta name="description" content="Paper with no citation metadata">')
    assert_nil Tag.parse_count('<meta name="description" content="Cited by 1,23">')
    assert_nil Tag.parse_count('<meta name="description" content="Cited by 12.4">')
    assert_nil Tag.parse_count('<meta name="description" content="Cited by 1K">')
    assert_equal 0, Tag.parse_count('<a href="/scholar?cites=123">Cited by 0</a>')
  end

  def test_missing_ids_skip_requests_and_clear_context_flags
    [nil, '', '  '].each do |missing|
      [Context.new(@site, missing), Context.new(@site, 'profile', missing)].each do |context|
        context['scholar_citations_cached'] = true
        context['scholar_citations_fetched_at'] = 'old'
        assert_equal '', @tag.render(context)
        assert_equal false, context['scholar_citations_cached']
        assert_equal '', context['scholar_citations_fetched_at']
      end
    end
    assert_empty @tag.requests
  end

  def test_successful_zero_is_persisted_and_reused_in_later_build
    @tag.response = '<meta name="description" content="Cited by 0">'
    assert_equal '0', @tag.render(@context)
    assert_equal false, @context['scholar_citations_cached']
    assert_equal 0, JSON.parse(File.read(cache_path)).fetch('profile:article').fetch('count')
    next_build = Context.new(Site.new(@directory, {}))
    @tag.failure = IOError.new('network must not be called for a fresh record')
    assert_equal '0', @tag.render(next_build)
    assert_equal true, next_build['scholar_citations_cached']
    assert_equal 1, @tag.requests.size
  end

  def test_network_failure_keeps_old_verified_count_and_retries_next_build
    known = record(393, 172_800)
    write_cache('profile:article' => known)
    @tag.failure = IOError.new('HTTP 403')
    assert_equal '393', @tag.render(@context)
    assert_equal true, @context['scholar_citations_cached']
    assert_equal known['fetched_at'], @context['scholar_citations_fetched_at']
    assert_equal '393', @tag.render(@context)
    assert_equal 1, @tag.requests.size
    assert_equal known, JSON.parse(File.read(cache_path))['profile:article']
    assert_equal '393', @tag.render(Context.new(Site.new(@directory, {})))
    assert_equal 2, @tag.requests.size
  end

  def test_fresh_seed_avoids_network_and_initializes_persistent_cache
    @site.data['google_scholar_citations'] = { 'profile:article' => record(393) }
    assert_equal '393', @tag.render(@context)
    assert_equal true, @context['scholar_citations_cached']
    assert_empty @tag.requests
    assert_equal 393, JSON.parse(File.read(cache_path))['profile:article']['count']
  end

  def test_newer_disk_record_wins_over_seed_and_newer_seed_wins_over_disk
    write_cache('profile:article' => record(400, 60))
    @site.data['google_scholar_citations'] = { 'profile:article' => record(393, 3600) }
    assert_equal '400', @tag.render(@context)
    newer_site = Site.new(@directory, { 'google_scholar_citations' => { 'profile:article' => record(401, 1) } })
    assert_equal '401', @tag.render(Context.new(newer_site))
    assert_empty @tag.requests
  end

  def test_cache_keys_include_both_profile_and_article
    @tag.response = lambda do |url|
      count = URI.decode_www_form(URI.parse(url).query).to_h['user'] == 'profile' ? 12 : 34
      "<meta name='description' content='Cited by #{count}'>"
    end
    assert_equal '12', @tag.render(@context)
    assert_equal '34', @tag.render(Context.new(@site, 'other-profile'))
    assert_equal 2, @tag.requests.size
    assert_equal ['other-profile:article', 'profile:article'], JSON.parse(File.read(cache_path)).keys.sort
  end

  def test_parse_failure_does_not_replace_existing_count_with_zero
    known = record(393, 172_800)
    write_cache('profile:article' => known)
    @tag.response = '<html>Consent required</html>'
    assert_equal '393', @tag.render(@context)
    assert_equal known, JSON.parse(File.read(cache_path))['profile:article']
  end

  def test_failure_without_known_count_returns_empty_and_is_not_persisted
    @tag.failure = IOError.new('network unavailable')
    assert_equal '', @tag.render(@context)
    assert_equal false, @context['scholar_citations_cached']
    refute File.exist?(cache_path)
    assert_equal '', @tag.render(@context)
    assert_equal 1, @tag.requests.size
  end

  def test_malformed_cache_can_recover_from_verified_seed
    FileUtils.mkdir_p(File.dirname(cache_path))
    File.write(cache_path, 'not json')
    @site.data['google_scholar_citations'] = { 'profile:article' => record(393) }
    assert_equal '393', @tag.render(@context)
    assert_equal 393, JSON.parse(File.read(cache_path))['profile:article']['count']
  end

  def test_invalid_counts_dates_and_mismatched_source_urls_are_rejected
    [-1, '393', nil, 1.5].each do |count|
      assert_nil Tag.valid_record(record(count), 'profile', 'article')
    end
    assert_nil Tag.valid_record(record(393).merge('fetched_at' => 'unknown'), 'profile', 'article')
    assert_nil Tag.valid_record(record(393, 60, 'other-profile'), 'profile', 'article')
    assert_nil Tag.valid_record(record(393).merge('url' => 'https://example.com/'), 'profile', 'article')
  end

  def test_real_liquid_capture_preserves_metadata_and_clears_it_for_the_next_entry
    skip 'Install Liquid or run with bundle exec to test capture integration' unless defined?(Liquid::Context)

    verified_at = Time.utc(2026, 10, 21, 12)
    known = { 'count' => 393, 'fetched_at' => verified_at.iso8601, 'url' => Tag.article_url('profile', 'article') }
    @site.data['google_scholar_citations'] = { 'profile:article' => known }
    template = Liquid::Template.parse(<<~LIQUID)
      {%- for entry in entries -%}
        {%- if enabled -%}
          {%- capture count -%}{% google_scholar_citations profile entry.article %}{%- endcapture -%}
          {{ count }}|{{ scholar_citations_cached }}|{{ scholar_citations_fetched_at | date: '%Y-%m-%d' }};
        {%- endif -%}
      {%- endfor -%}
    LIQUID
    rendered = Time.stub(:now, verified_at + 60) do
      template.render!(
        { 'profile' => 'profile', 'entries' => [{ 'article' => 'article' }, { 'article' => '' }], 'enabled' => true },
        registers: { site: @site }
      )
    end
    assert_equal '393|true|2026-10-21;|false|;', rendered
    assert_empty template.errors
  end
end
