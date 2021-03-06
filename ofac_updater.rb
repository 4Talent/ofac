# Felipe Astroza - 2015-03
require 'httparty'
require 'open-uri'
require 'nokogiri'
require 'json'
require 'date'
require 'elasticsearch'

File.open('ofac.pid', 'w') {|f| f.write Process.pid } 

PERSISTENT_UPDATE_DATES = '.ofac_update_dates'
XMLS = ['https://www.treasury.gov/ofac/downloads/consolidated/consolidated.xml', 'https://www.treasury.gov/ofac/downloads/sdn.xml']
UPDATE_INTERVAL = 24*60*60
if ENV['APP_ENV']
	APP_ENV = ENV['APP_ENV']
else
	APP_ENV = 'development'
end
INDEX = 'ofac_' + APP_ENV
VINDEX = 'vofac_' + APP_ENV
ES_HOST = '172.31.26.11'

run_once = ARGV.length > 0
DEBUG = ENV['DEBUG'] != nil

def load_to_elastic_search(doc, source)
  client = Elasticsearch::Client.new host: ES_HOST, log: DEBUG
  
  node = doc.root.child
  index_name = "#{INDEX}_#{source}"

  begin
    puts "+ Hiding vofac"
    client.indices.delete_alias index: index_name, name: VINDEX
  rescue
    # index or alias does not exist, maybe first run?
  end
  
  begin
    puts "+ Deleting old index.. (#{index_name})"
    client.indices.delete(index: index_name)
  rescue Elasticsearch::Transport::Transport::Errors::NotFound => not_found
    # index does not exist, maybe first run?
  end

  puts "+ Recreating index... (#{index_name})"
  client.indices.create(:index => index_name, :body => JSON.parse(File.open('mapping.json') {|f| d=f.read; f.close; d}))

  count = 0
  puts "+ Inserting entries"
  while node
    if node.class != Nokogiri::XML::Text and node.name == 'sdnEntry'
      node_hash = node.to_hash
      # We add the source to the indexed document
      node_hash['source'] = source
      client.index(index: INDEX, type: 'entry', body: node_hash)
      if DEBUG
        puts '----------------------------'
      end
      count += 1
    end
    node = node.next
  end
  puts "+ #{count} entries added"
  client.indices.put_alias index: index_name, name: VINDEX
  puts "+ vofac is available again"
end

class Nokogiri::XML::Element
  def to_json(*a)
    to_hash.to_json(*a)
  end
  
  def to_hash
    h = {}
    children.each do |child|
      if child.class == Nokogiri::XML::Text
        return child.text
      end
      h[child.name.to_s] = child.to_hash
    end
    h
  end
end

update_dates = {}
for xml_url in XMLS
  update_dates[xml_url] = Date.new(0)
end

begin
  File.open(PERSISTENT_UPDATE_DATES, 'r').tap { |f| update_dates=Marshal.load(f.read) }.close if File.exists?(PERSISTENT_UPDATE_DATES)
rescue
  puts 'Ignoring the persisted update dates'
end

puts "index: #{INDEX}, vindex: #{VINDEX}"
if not run_once
	puts "Daemon mode"
end

begin
  XMLS.each_with_index do |xml_url, source|
    response = HTTParty.head(xml_url)
    date = Date.parse(response.headers['last-modified'])
    if update_dates[xml_url] && date && date > update_dates[xml_url]
      puts "+ Updating from #{xml_url} (#{date})"
      doc = Nokogiri::XML(open(xml_url)) do |config|
        config.noblanks
      end
      update_dates[xml_url] = date
      load_to_elastic_search(doc, source)
    else
      puts "+ Nothing to do for #{xml_url} (updated #{date})"
    end
  end
  File.open(PERSISTENT_UPDATE_DATES, 'w').tap { |f| f.write(Marshal.dump(update_dates)) }.close
  if not run_once
    sleep UPDATE_INTERVAL
  end
end until run_once
