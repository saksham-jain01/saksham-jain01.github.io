require 'fileutils'
require 'json'
require 'nokogiri'
require 'open-uri'
require 'tempfile'
require 'time'
require 'uri'

module Jekyll
  class GoogleScholarCitationsTag < Liquid::Tag
    CACHE_MAX_AGE = 24 * 60 * 60
    RESULTS_IVAR = :@google_scholar_citation_results
    RECORDS_IVAR = :@google_scholar_citation_records

    def initialize(tag_name, params, tokens)
      super
      @scholar_id, @article_id = params.split.map(&:strip)
    end

    def render(context)
      # Match Liquid's assign/capture scope so metadata survives the capture
      # block that stores the count for the publication badge.
      metadata = context.scopes.last
      metadata['scholar_citations_cached'] = false
      metadata['scholar_citations_fetched_at'] = ''
      scholar_id = context[@scholar_id].to_s.strip
      article_id = context[@article_id].to_s.strip
      return '' if scholar_id.empty? || article_id.empty?

      site = context.registers[:site]
      key = "#{scholar_id}:#{article_id}"
      results = site.instance_variable_get(RESULTS_IVAR) || {}
      site.instance_variable_set(RESULTS_IVAR, results)
      # Cache failures only for this build, so later builds can retry.
      results[key] = resolve(site, key, scholar_id, article_id) unless results.key?(key)
      record, cached = results[key]
      return '' unless record

      metadata['scholar_citations_cached'] = cached
      metadata['scholar_citations_fetched_at'] = record['fetched_at']
      record['count'].to_s
    end

    def self.article_url(scholar_id, article_id)
      query = URI.encode_www_form(
        'view_op' => 'view_citation', 'hl' => 'en', 'user' => scholar_id,
        'citation_for_view' => "#{scholar_id}:#{article_id}"
      )
      "https://scholar.google.com/citations?#{query}"
    end

    def self.parse_count(html)
      doc = Nokogiri::HTML(html)
      # Prefer the actual citation link, then try both metadata descriptions.
      texts = doc.css('a[href*="cites="]').map(&:text)
      texts += doc.css('meta[name="description"], meta[property="og:description"]').map { |node| node['content'].to_s }
      texts.each do |text|
        match = text.match(/\bCited by\s+(\d[\d,]*+)\b(?![.,]\d)/i)
        next unless match && match[1].match?(/\A(?:\d+|\d{1,3}(?:,\d{3})+)\z/)

        return match[1].delete(',').to_i
      end
      # A consent/challenge/error page or changed markup is not zero citations.
      nil
    end

    def self.valid_record(record, scholar_id, article_id)
      return nil unless record.is_a?(Hash) && record['count'].is_a?(Integer) && record['count'] >= 0
      return nil unless record['fetched_at'].is_a?(String) && record['url'].is_a?(String)

      Time.iso8601(record['fetched_at'])
      uri = URI.parse(record['url'])
      query = URI.decode_www_form(uri.query.to_s).to_h
      return nil unless uri.scheme == 'https' && uri.host == 'scholar.google.com' && uri.path == '/citations'
      return nil unless query['user'] == scholar_id && query['citation_for_view'] == "#{scholar_id}:#{article_id}"
      return nil unless query['view_op'] == 'view_citation'

      { 'count' => record['count'], 'fetched_at' => record['fetched_at'], 'url' => record['url'] }
    rescue ArgumentError, URI::InvalidURIError
      nil
    end

    private

    def resolve(site, key, scholar_id, article_id)
      records = records_for(site)
      cached = records[key]
      if cached && Time.now.utc - Time.iso8601(cached['fetched_at']) < CACHE_MAX_AGE
        return [cached, true]
      end

      url = self.class.article_url(scholar_id, article_id)
      begin
        count = self.class.parse_count(fetch_article(url))
        raise ArgumentError, 'response did not contain an explicit citation count' if count.nil?

        record = { 'count' => count, 'fetched_at' => Time.now.utc.iso8601, 'url' => url }
        records[key] = record
        persist_records(site, records)
        [record, false]
      rescue StandardError => error
        log_warning("#{key}: #{error.class}: #{error.message}; #{cached ? 'keeping the last verified count' : 'no verified count available'}")
        [cached, true]
      end
    end

    def fetch_article(url)
      URI.open(url, 'User-Agent' => "Ruby/#{RUBY_VERSION}", open_timeout: 5, read_timeout: 5, &:read)
    end

    def cache_path(site)
      File.join(site.source, '.jekyll-cache', 'google-scholar-citations', 'counts.json')
    end

    def records_for(site)
      existing = site.instance_variable_get(RECORDS_IVAR)
      return existing if existing

      sources = []
      begin
        sources << JSON.parse(File.read(cache_path(site))) if File.file?(cache_path(site))
      rescue StandardError => error
        log_warning("Cannot read citation cache: #{error.class}: #{error.message}")
      end
      sources << site.data['google_scholar_citations']
      records = {}
      sources.each do |source|
        next unless source.is_a?(Hash)

        source.each do |key, value|
          key = key.to_s
          scholar_id, article_id = key.split(':', 2)
          next if scholar_id.to_s.empty? || article_id.to_s.empty?

          record = self.class.valid_record(value, scholar_id, article_id)
          next unless record
          next if records[key] && Time.iso8601(records[key]['fetched_at']) >= Time.iso8601(record['fetched_at'])

          records[key] = record
        end
      end
      site.instance_variable_set(RECORDS_IVAR, records)
      persist_records(site, records) unless records.empty?
      records
    end

    def persist_records(site, records)
      path = cache_path(site)
      FileUtils.mkdir_p(File.dirname(path))
      Tempfile.create(['counts-', '.json'], File.dirname(path)) do |file|
        file.write(JSON.pretty_generate(records))
        file.flush
        File.rename(file.path, path)
      end
    rescue StandardError => error
      # A filesystem problem must not discard a successfully fetched count.
      log_warning("Cannot persist citation cache: #{error.class}: #{error.message}")
    end

    def log_warning(message)
      if Jekyll.respond_to?(:logger)
        Jekyll.logger.warn('Google Scholar:', message)
      else
        warn("Google Scholar: #{message}")
      end
    end
  end
end

Liquid::Template.register_tag('google_scholar_citations', Jekyll::GoogleScholarCitationsTag)
if defined?(Jekyll::Hooks)
  Jekyll::Hooks.register :site, :after_reset do |site|
    site.instance_variable_set(Jekyll::GoogleScholarCitationsTag::RESULTS_IVAR, nil)
    site.instance_variable_set(Jekyll::GoogleScholarCitationsTag::RECORDS_IVAR, nil)
  end
end
