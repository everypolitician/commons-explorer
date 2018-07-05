require 'pathname'
require 'rest-client'
require 'sinatra'
require 'commons/builder'
require 'liquid-template-inheritance'

Liquid::Template.file_system = Liquid::LocalFileSystem.new(Pathname.new(__dir__).join('views'), '%s.liquid')

get '/' do
  response = RestClient.get('https://api.github.com/users/everypolitician/repos?per_page=1000',
                            'Accept' => 'application/vnd.github.mercy-preview+json')
  data = JSON.parse(response, symbolize_names: true)
  countries = data.flat_map do |repo|
    if repo[:topics].include? 'commons-data'
      config = JSON.parse(RestClient.get("https://raw.githubusercontent.com/#{repo[:full_name]}/master/config.json"), symbolize_names: true)
      puts JSON.dump config
      [{
          'url' => "/country/#{config[:country_wikidata_id]}?languages=#{config[:languages].join(',')}",
          'label' => repo[:full_name],
       }]
    else
      []
    end
  end
  liquid :index, locals: {'countries': countries}
end

get '/country/:country' do
  config = Config.new country_wikidata_id: params['country'], languages: params['languages'].split(',')
  legislatures = Legislature.list(config).map do |legislature|
    {
        'url' => "/legislature/#{params['country']}/#{legislature.house_item_id}/#{legislature.position_item_id}?languages=#{config.languages.join(',')}",
        'label' => legislature.comment,
    }
  end
  liquid :country, locals: {'legislatures': legislatures}
end

get '/legislature/:country/:legislature/:position' do
  config = Config.new country_wikidata_id: params['country'], languages: params['languages'].split(',')
  legislature_row = WikidataRow.new({legislature: {value: params['legislature']},
                                     legislaturePost: {value: params['position']}}, config.languages)
  terms = Legislature.terms_from_wikidata config, false, [legislature_row]
  legislature = Legislature.new house_item_id: params['legislature'], terms: terms, position_item_id: params['position']
  puts JSON.dump(legislature.as_json)
  liquid :legislature, locals: {
      'config' => config,
      'legislature' => legislature.as_json,
      'languages' => params['languages'],
  }
end

get '/term/:country/:legislature/:term/:position' do
  config = Config.new country_wikidata_id: params['country'], languages: params['languages'].split(',')

  legislature = Legislature.new house_item_id: params['legislature'], terms: [], position_item_id: params['position']
  term = LegislativeTerm.new legislature: legislature, term_item_id: params['term'], position_item_id: params['position']

  wikidata_client = WikidataClient.new
  wikidata_labels = WikidataLabels.new(config: config, wikidata_client: wikidata_client)
  wikidata_results_parser = WikidataResultsParser.new(languages: config.languages)
  query = Query.new(
      sparql_query: term.query(config),
      output_dir_pn: Pathname.new(''),
  )
  query.run(wikidata_client: wikidata_client)
  membership_rows = wikidata_results_parser.parse(query.last_saved_results)

  membership_data = MembershipData.new(membership_rows, wikidata_labels, 'legislative')

  persons = membership_data.persons.map { |p| [p[:id], p.map { |k,v| [k.to_s, v] }.to_h] }.to_h
  persons.values.each { |p| p['name'] = config.languages.map { |l| p['name'][:"lang:#{l}"] } }

  organizations = membership_data.organizations.map { |o| [o[:id], o.map { |k,v| [k.to_s, v] }.to_h] }.to_h
  organizations.values.each { |o| o['name'] = config.languages.map { |l| o['name'][:"lang:#{l}"] } }

  # areas = membership_data.areas.map { |a| [a[:id], a.map { |k,v| [k.to_s, v] }.to_h] }.to_h
  # areas.values.each { |a| a['name'] = config.languages.map { |l| a['name'][:"lang:#{l}"] } }

  memberships = membership_data.memberships.map { |r| r.map { |k,v| [k.to_s, v] }.to_h }
  memberships.each { |m| m['person'] = persons[m['person_id'] ] }
  memberships.each { |m| m['on_behalf_of'] = organizations[m['on_behalf_of_id'] ] }
  # memberships.each { |m| m['area'] = areas[m['area_id'] ] }

  liquid :term, locals: {
      'config' => config,
      'term' => term,
      'persons' => persons,
      'organizations' => organizations,
      # 'areas' => areas,
      'languages' => config.languages,
  }

end